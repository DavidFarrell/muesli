#import "MuesliNativeProcessObserver.h"
#import <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <math.h>
#include <pthread.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

NSErrorDomain const MuesliProcessObserverErrorDomain = @"com.paidiaconsulting.muesli.process-observer";

typedef struct {
    pid_t pid;
    uint64_t seconds;
    uint64_t microseconds;
} MuesliProcessIdentity;

static uint64_t MonotonicNanoseconds(void) {
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

static NSError *ObserverError(MuesliProcessObserverError code, NSString *description, int underlying) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (underlying != 0) {
        info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSPOSIXErrorDomain code:underlying userInfo:nil];
    }
    return [NSError errorWithDomain:MuesliProcessObserverErrorDomain code:code userInfo:info];
}

static BOOL ReadIdentity(pid_t pid, MuesliProcessIdentity *identity, NSError **error) {
    struct proc_bsdinfo info = {0};
    int count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (count != sizeof(info)) {
        if (error) *error = ObserverError(MuesliProcessObserverErrorIdentityUnavailable,
            @"The connected process instance could not be identified.", errno);
        return NO;
    }
    *identity = (MuesliProcessIdentity){pid, info.pbi_start_tvsec, info.pbi_start_tvusec};
    return YES;
}

static BOOL SameIdentity(MuesliProcessIdentity first, MuesliProcessIdentity second) {
    return first.pid == second.pid && first.seconds == second.seconds && first.microseconds == second.microseconds;
}

static BOOL AuthenticateProcess(pid_t pid, NSString *text, NSError **error) {
    SecRequirementRef requirement = NULL;
    OSStatus status = SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement);
    if (status != errSecSuccess) {
        if (error) *error = [NSError errorWithDomain:MuesliProcessObserverErrorDomain
            code:MuesliProcessObserverErrorCodeSigningRequirement userInfo:@{
                NSLocalizedDescriptionKey: @"The expected service signing requirement is invalid.",
                NSUnderlyingErrorKey: [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]}];
        return NO;
    }
    SecCodeRef code = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    if (code) CFRelease(code);
    CFRelease(requirement);
    if (status == errSecSuccess) return YES;
    if (error) *error = [NSError errorWithDomain:MuesliProcessObserverErrorDomain
        code:MuesliProcessObserverErrorCodeSignatureRejected userInfo:@{
            NSLocalizedDescriptionKey: @"The connected process does not satisfy the expected service signing requirement.",
            NSUnderlyingErrorKey: [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]}];
    return NO;
}

@interface MuesliProcessTermination ()
- (instancetype)initWithIdentity:(MuesliProcessIdentity)identity event:(struct kevent)event;
@end

@implementation MuesliProcessTermination
- (instancetype)initWithIdentity:(MuesliProcessIdentity)identity event:(struct kevent)event {
    self = [super init];
    if (self) {
        _processIdentifier = identity.pid;
        _startSeconds = identity.seconds;
        _startMicroseconds = identity.microseconds;
        _rawWaitStatus = (int32_t)event.data;
        _eventFlags = event.fflags;
        _exitCode = -1;
        _signal = 0;
        if (WIFEXITED(_rawWaitStatus)) {
            _kind = MuesliProcessTerminationKindExited;
            _exitCode = WEXITSTATUS(_rawWaitStatus);
        } else if (WIFSIGNALED(_rawWaitStatus)) {
            _kind = MuesliProcessTerminationKindSignalled;
            _signal = WTERMSIG(_rawWaitStatus);
        } else {
            _kind = MuesliProcessTerminationKindOther;
        }
    }
    return self;
}
@end

typedef NS_ENUM(NSUInteger, MuesliArmDecision) {
    MuesliArmDecisionPending,
    MuesliArmDecisionAccepted,
    MuesliArmDecisionRejected,
};

@interface MuesliNativeProcessObserver () {
    NSLock *_stateLock;
    dispatch_semaphore_t _armReady;
    MuesliArmDecision _decision;
    NSError *_armError;
    MuesliProcessIdentity _identity;
    uint64_t _deadline;
    NSXPCConnection *_connection;
    NSString *_requirement;
    MuesliProcessTerminationHandler _terminationHandler;
    MuesliProcessObservationFailureHandler _failureHandler;
    MuesliProcessTermination *_termination;
    NSError *_observationFailure;
}
- (instancetype)initWithConnection:(NSXPCConnection *)connection requirement:(NSString *)requirement
                          deadline:(uint64_t)deadline terminationHandler:(MuesliProcessTerminationHandler)terminationHandler
                    failureHandler:(nullable MuesliProcessObservationFailureHandler)failureHandler;
- (void)runWorker;
@end

static void *ObservationWorker(void *context) {
    @autoreleasepool {
        MuesliNativeProcessObserver *observer = CFBridgingRelease(context);
        [observer runWorker];
    }
    return NULL;
}

@implementation MuesliNativeProcessObserver
+ (instancetype)armConnection:(NSXPCConnection *)connection codeSigningRequirement:(NSString *)requirement
                       timeout:(NSTimeInterval)timeout terminationHandler:(MuesliProcessTerminationHandler)terminationHandler
                failureHandler:(MuesliProcessObservationFailureHandler)failureHandler error:(NSError **)error {
    if (!connection || requirement.length == 0 || !terminationHandler || !isfinite(timeout) || timeout <= 0 || timeout > 60) {
        if (error) *error = ObserverError(MuesliProcessObserverErrorInvalidArgument,
            @"An XPC connection, signing requirement, handler and timeout between zero and sixty seconds are required.", 0);
        return nil;
    }
    uint64_t duration = (uint64_t)(timeout * NSEC_PER_SEC);
    uint64_t deadline = MonotonicNanoseconds() + duration;
    MuesliNativeProcessObserver *observer = [[self alloc] initWithConnection:connection requirement:requirement
        deadline:deadline terminationHandler:terminationHandler failureHandler:failureHandler];
    pthread_attr_t attributes;
    int status = pthread_attr_init(&attributes);
    if (status == 0) {
        status = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (status == 0) {
            pthread_t worker;
            void *context = (void *)CFBridgingRetain(observer);
            status = pthread_create(&worker, &attributes, ObservationWorker, context);
            if (status != 0) CFBridgingRelease(context);
        }
        pthread_attr_destroy(&attributes);
    }
    if (status != 0) {
        if (error) *error = ObserverError(MuesliProcessObserverErrorWorkerCreation,
            @"A dedicated process-observation worker could not be created.", status);
        return nil;
    }
    uint64_t now = MonotonicNanoseconds();
    int64_t remaining = now < deadline ? (int64_t)(deadline - now) : 0;
    dispatch_semaphore_wait(observer->_armReady, dispatch_time(DISPATCH_TIME_NOW, remaining));
    [observer->_stateLock lock];
    if (observer->_decision == MuesliArmDecisionPending) {
        observer->_decision = MuesliArmDecisionRejected;
        observer->_armError = ObserverError(MuesliProcessObserverErrorDeadlineExceeded,
            @"Native process observation did not arm before its registration deadline.", 0);
    }
    BOOL accepted = observer->_decision == MuesliArmDecisionAccepted;
    NSError *armError = observer->_armError;
    [observer->_stateLock unlock];
    if (!accepted && error) *error = armError;
    return accepted ? observer : nil;
}

- (instancetype)initWithConnection:(NSXPCConnection *)connection requirement:(NSString *)requirement
                          deadline:(uint64_t)deadline terminationHandler:(MuesliProcessTerminationHandler)terminationHandler
                    failureHandler:(MuesliProcessObservationFailureHandler)failureHandler {
    self = [super init];
    if (self) {
        _stateLock = [NSLock new];
        _armReady = dispatch_semaphore_create(0);
        _deadline = deadline;
        _connection = connection;
        _requirement = [requirement copy];
        _terminationHandler = [terminationHandler copy];
        _failureHandler = [failureHandler copy];
    }
    return self;
}

- (pid_t)processIdentifier { return _identity.pid; }
- (uint64_t)startSeconds { return _identity.seconds; }
- (uint64_t)startMicroseconds { return _identity.microseconds; }
- (MuesliProcessTermination *)termination {
    [_stateLock lock];
    MuesliProcessTermination *value = _termination;
    [_stateLock unlock];
    return value;
}
- (NSError *)observationFailure {
    [_stateLock lock];
    NSError *value = _observationFailure;
    [_stateLock unlock];
    return value;
}

/// Native calls may outlive the caller deadline. This check closes their eventual
/// handoff; the dedicated worker still owns all native resources until it returns.
- (BOOL)admissionRemainsOpen {
    [_stateLock lock];
    BOOL open = _decision == MuesliArmDecisionPending && MonotonicNanoseconds() < _deadline;
    [_stateLock unlock];
    return open;
}

- (BOOL)publishRegistration:(MuesliProcessIdentity)identity error:(NSError *)error {
    [_stateLock lock];
    BOOL accepted = NO;
    if (_decision == MuesliArmDecisionPending) {
        if (!error && MonotonicNanoseconds() < _deadline) {
            _identity = identity;
            _decision = MuesliArmDecisionAccepted;
            accepted = YES;
        } else {
            _armError = error ?: ObserverError(MuesliProcessObserverErrorDeadlineExceeded,
                @"Native process observation did not arm before its registration deadline.", 0);
            _decision = MuesliArmDecisionRejected;
        }
    }
    [_stateLock unlock];
    dispatch_semaphore_signal(_armReady);
    return accepted;
}

- (void)publishObservationFailure:(NSError *)error {
    [_stateLock lock];
    _observationFailure = error;
    [_stateLock unlock];
    MuesliProcessObservationFailureHandler handler = _failureHandler;
    if (handler) handler(error);
}

- (void)runWorker {
    pthread_setname_np("Muesli native process exit");
    NSError *error = nil;
    MuesliProcessIdentity before = {0}, after = {0};
    int descriptor = -1;
    pid_t pid = _connection.processIdentifier;
    if (pid <= 0) {
        error = ObserverError(MuesliProcessObserverErrorConnectionUnavailable,
            @"The activated XPC connection has no process identifier.", 0);
    } else if (![self admissionRemainsOpen]) {
        // publishRegistration supplies the deadline error.
    } else if (ReadIdentity(pid, &before, &error) && AuthenticateProcess(pid, _requirement, &error)
               && [self admissionRemainsOpen]) {
        descriptor = kqueue();
        if (descriptor < 0) {
            error = ObserverError(MuesliProcessObserverErrorKernelRegistration,
                @"The kernel process-observation queue could not be created.", errno);
        } else if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
            error = ObserverError(MuesliProcessObserverErrorKernelRegistration,
                @"The process-observation descriptor could not be isolated from child execution.", errno);
        } else {
            struct kevent change = {0}, receipt = {0};
            EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT | EV_RECEIPT,
                NOTE_EXIT | NOTE_EXITSTATUS, 0, NULL);
            struct timespec noWait = {0};
            int count;
            do {
                count = kevent(descriptor, &change, 1, &receipt, 1, &noWait);
            } while (count < 0 && errno == EINTR && [self admissionRemainsOpen]);
            BOOL registered = count == 1 && receipt.ident == (uintptr_t)pid
                && receipt.filter == EVFILT_PROC && (receipt.flags & EV_ERROR) && receipt.data == 0;
            if (!registered) {
                int registrationError = count == 1 && (receipt.flags & EV_ERROR) ? (int)receipt.data
                    : (count < 0 ? errno : EIO);
                error = ObserverError(MuesliProcessObserverErrorKernelRegistration,
                    @"The kernel did not acknowledge process-exit observation.", registrationError);
            } else if (ReadIdentity(pid, &after, &error)) {
                if (!SameIdentity(before, after) || _connection.processIdentifier != pid) {
                    error = ObserverError(MuesliProcessObserverErrorIdentityChanged,
                        @"The connected process instance changed while observation was being armed.", 0);
                }
            }
        }
    }
    // A successful receipt alone is insufficient: both identities must exist,
    // match, and the original connected PID must still be bound at handoff.
    BOOL proved = descriptor >= 0 && before.pid > 0 && after.pid > 0 && SameIdentity(before, after) && !error;
    if (!proved && !error) {
        BOOL withinDeadline = [self admissionRemainsOpen];
        error = ObserverError(withinDeadline ? MuesliProcessObserverErrorKernelRegistration : MuesliProcessObserverErrorDeadlineExceeded,
            withinDeadline ? @"Native process observation did not complete its identity proof."
                : @"Native process observation did not arm before its registration deadline.", 0);
    }
    BOOL accepted = [self publishRegistration:before error:error];
    // If a timeout rejected this registration, no source can have been granted.
    // Close the unclaimed queue only after the actual registration call returned.
    _connection = nil;
    _requirement = nil;
    if (accepted) {
        for (;;) {
            struct kevent event = {0};
            int count = kevent(descriptor, NULL, 0, &event, 1, NULL);
            if (count < 0 && errno == EINTR) continue;
            if (count != 1 || (event.flags & EV_ERROR) || event.filter != EVFILT_PROC
                || event.ident != (uintptr_t)before.pid || !(event.fflags & NOTE_EXIT)
                || !(event.fflags & NOTE_EXITSTATUS)) {
                int observationError = count < 0 ? errno : ((event.flags & EV_ERROR) ? (int)event.data : EIO);
                [self publishObservationFailure:ObserverError(MuesliProcessObserverErrorKernelObservation,
                    @"The native observer failed without proving service-process termination.", observationError)];
                break;
            }
            MuesliProcessTermination *termination = [[MuesliProcessTermination alloc] initWithIdentity:before event:event];
            [_stateLock lock];
            _termination = termination;
            [_stateLock unlock];
            _terminationHandler(termination);
            break;
        }
    }
    if (descriptor >= 0) close(descriptor);
    // Handlers may own source leases. Destruction is outside the state lock and
    // after the worker has returned from the native operation and callback.
    _terminationHandler = nil;
    _failureHandler = nil;
}
@end
