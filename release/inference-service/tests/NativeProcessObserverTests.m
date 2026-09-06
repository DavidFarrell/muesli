#import "../MuesliNativeProcessObserver.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static NSString *const FixtureRequirement = @"identifier \"com.paidiaconsulting.muesli.native-observer-tests\"";
static atomic_bool exhaustDescriptorsAtKqueue;

// Test compilation substitutes only this call boundary. Normally it calls the
// real kqueue unchanged. The failure case exhausts this fixture's descriptors
// immediately before the actual syscall, after Security has finished its work.
int MuesliTestKqueue(void) {
    if (!atomic_exchange(&exhaustDescriptorsAtKqueue, false)) return kqueue();
    struct rlimit previous;
    if (getrlimit(RLIMIT_NOFILE, &previous) != 0) abort();
    struct rlimit bounded = previous;
    bounded.rlim_cur = MIN(previous.rlim_cur, 128);
    if (setrlimit(RLIMIT_NOFILE, &bounded) != 0) abort();
    int descriptors[128]; NSUInteger count = 0;
    while (count < 128) {
        int descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (descriptor < 0) break;
        descriptors[count++] = descriptor;
    }
    int result = kqueue();
    int actualError = errno;
    for (NSUInteger index = 0; index < count; index++) close(descriptors[index]);
    if (setrlimit(RLIMIT_NOFILE, &previous) != 0) abort();
    errno = actualError;
    return result;
}

// The only fake is NSXPCConnection's PID boundary. The executable, signature,
// process identity, registration receipt, exit event and wait status are real.
@interface FixtureConnection : NSXPCConnection
@property(nonatomic) pid_t fixturePID;
@property(nonatomic) NSTimeInterval firstReadDelay;
@property(nonatomic) BOOL changePIDOnRevalidation;
@property(nonatomic) BOOL exitBeforeRevalidation;
@property(nonatomic) int childControl;
@property(nonatomic) NSUInteger reads;
@end
@implementation FixtureConnection
- (pid_t)processIdentifier {
    self.reads += 1;
    if (self.reads == 1 && self.firstReadDelay > 0) [NSThread sleepForTimeInterval:self.firstReadDelay];
    if (self.reads > 1 && self.exitBeforeRevalidation) {
        unsigned char command = 125;
        (void)write(self.childControl, &command, 1);
        int status;
        (void)waitpid(self.fixturePID, &status, 0);
    }
    return self.reads > 1 && self.changePIDOnRevalidation ? self.fixturePID + 1 : self.fixturePID;
}
@end

@interface ObservationState : NSObject
@property(atomic, strong) MuesliProcessTermination *termination;
@property(atomic, strong) NSError *failure;
@property(atomic) NSUInteger terminalCount;
@property(atomic) NSUInteger failureCount;
@property(nonatomic, strong) dispatch_semaphore_t changed;
@end
@implementation ObservationState
- (instancetype)init { if ((self = [super init])) _changed = dispatch_semaphore_create(0); return self; }
@end

typedef struct { pid_t pid; int control; } Child;
static Child LaunchChild(const char *executable) {
    int control[2], readiness[2];
    if (pipe(control) != 0 || pipe(readiness) != 0) abort();
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, control[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, readiness[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, control[1]);
    posix_spawn_file_actions_addclose(&actions, readiness[0]);
    posix_spawn_file_actions_addclose(&actions, control[0]);
    posix_spawn_file_actions_addclose(&actions, readiness[1]);
    char *const arguments[] = {(char *)executable, "--child", NULL};
    pid_t pid = 0;
    int result = posix_spawn(&pid, executable, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(control[0]); close(readiness[1]);
    if (result != 0) abort();
    struct pollfd ready = {.fd = readiness[0], .events = POLLIN};
    char value = 0;
    if (poll(&ready, 1, 3000) != 1 || read(readiness[0], &value, 1) != 1 || value != 'R') abort();
    close(readiness[0]);
    return (Child){pid, control[1]};
}

static void CommandChild(Child child, unsigned char command) {
    if (write(child.control, &command, 1) != 1) abort();
    close(child.control);
}

static int ReapChild(Child child) {
    int status = 0;
    pid_t result;
    do { result = waitpid(child.pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result != child.pid) abort();
    return status;
}

static MuesliNativeProcessObserver *Arm(FixtureConnection *connection, ObservationState *state,
                                       NSString *requirement, NSTimeInterval timeout, NSError **error) {
    return [MuesliNativeProcessObserver armConnection:connection codeSigningRequirement:requirement timeout:timeout
        terminationHandler:^(MuesliProcessTermination *termination) {
            state.termination = termination;
            state.terminalCount += 1;
            dispatch_semaphore_signal(state.changed);
        } failureHandler:^(NSError *failure) {
            state.failure = failure;
            state.failureCount += 1;
            dispatch_semaphore_signal(state.changed);
        } error:error];
}

static BOOL AwaitTerminal(ObservationState *state) {
    return dispatch_semaphore_wait(state.changed, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0;
}

static uint64_t TestNanoseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + now.tv_nsec;
}

static NSMutableArray<NSDictionary *> *results;
static int failures;
static void Check(NSString *name, BOOL passed, NSDictionary *details) {
    NSMutableDictionary *row = [details mutableCopy] ?: [NSMutableDictionary new];
    row[@"name"] = name; row[@"passed"] = @(passed);
    [results addObject:row];
    if (!passed) failures += 1;
}

static void TestExit(const char *executable, unsigned char command, NSString *name) {
    Child child = LaunchChild(executable);
    FixtureConnection *connection = [FixtureConnection new]; connection.fixturePID = child.pid;
    ObservationState *state = [ObservationState new];
    NSError *error = nil;
    MuesliNativeProcessObserver *observer = Arm(connection, state, FixtureRequirement, 2, &error);
    BOOL boundBeforeCommand = observer && observer.processIdentifier == child.pid && observer.startSeconds > 0
        && observer.termination == nil && state.terminalCount == 0;
    CommandChild(child, command);
    int actualStatus = ReapChild(child);
    BOOL delivered = AwaitTerminal(state);
    MuesliProcessTermination *termination = state.termination;
    BOOL expectedKind = command == 255 ? termination.kind == MuesliProcessTerminationKindSignalled
        && termination.signal == SIGKILL && termination.exitCode == -1
        : termination.kind == MuesliProcessTerminationKindExited && termination.exitCode == command && termination.signal == 0;
    Check(name, boundBeforeCommand && delivered && expectedKind && state.terminalCount == 1
        && state.failureCount == 0 && termination.rawWaitStatus == actualStatus
        && termination.processIdentifier == observer.processIdentifier
        && termination.startSeconds == observer.startSeconds && termination.startMicroseconds == observer.startMicroseconds,
        @{@"pid": @(child.pid), @"raw_wait_status": @(termination.rawWaitStatus), @"waitpid_status": @(actualStatus),
          @"exit_code": @(termination.exitCode), @"signal": @(termination.signal), @"arm_error": error.description ?: @""});
}

static void TestDroppedHandle(const char *executable) {
    Child child = LaunchChild(executable);
    ObservationState *state = [ObservationState new];
    __weak MuesliNativeProcessObserver *weakObserver;
    @autoreleasepool {
        FixtureConnection *connection = [FixtureConnection new]; connection.fixturePID = child.pid;
        NSError *error = nil;
        MuesliNativeProcessObserver *observer = Arm(connection, state, FixtureRequirement, 2, &error);
        weakObserver = observer;
        [connection invalidate];
        observer = nil;
    }
    [NSThread sleepForTimeInterval:0.04];
    BOOL liveWithoutCaller = weakObserver != nil && state.terminalCount == 0 && state.failureCount == 0;
    CommandChild(child, 0); int status = ReapChild(child);
    BOOL delivered = AwaitTerminal(state);
    uint64_t deadline = TestNanoseconds() + NSEC_PER_SEC;
    while (weakObserver != nil && TestNanoseconds() < deadline) [NSThread sleepForTimeInterval:0.001];
    Check(@"caller release and connection invalidation do not mean death", liveWithoutCaller && delivered
        && state.terminalCount == 1 && state.failureCount == 0 && state.termination.rawWaitStatus == status && weakObserver == nil, nil);
}

static void TestRejected(const char *executable, NSString *requirement, BOOL changePID, NSInteger expected, NSString *name) {
    Child child = LaunchChild(executable);
    FixtureConnection *connection = [FixtureConnection new]; connection.fixturePID = child.pid;
    connection.changePIDOnRevalidation = changePID;
    ObservationState *state = [ObservationState new]; NSError *error = nil;
    MuesliNativeProcessObserver *observer = Arm(connection, state, requirement, 2, &error);
    CommandChild(child, 0); (void)ReapChild(child);
    Check(name, observer == nil && [error.domain isEqualToString:MuesliProcessObserverErrorDomain] && error.code == expected
        && state.terminalCount == 0 && state.failureCount == 0, @{@"error_code": @(error.code)});
}

static void TestDeadline(const char *executable) {
    Child child = LaunchChild(executable);
    ObservationState *state = [ObservationState new]; NSError *error = nil;
    __weak FixtureConnection *weakConnection;
    uint64_t elapsed;
    @autoreleasepool {
        FixtureConnection *connection = [FixtureConnection new]; connection.fixturePID = child.pid;
        connection.firstReadDelay = 0.25; weakConnection = connection;
        uint64_t started = TestNanoseconds();
        MuesliNativeProcessObserver *observer = Arm(connection, state, FixtureRequirement, 0.025, &error);
        elapsed = TestNanoseconds() - started;
        [connection invalidate];
        Check(@"blocked registration has bounded caller deadline", observer == nil && elapsed < 150 * NSEC_PER_MSEC
            && error.code == MuesliProcessObserverErrorDeadlineExceeded && state.terminalCount == 0,
            @{@"caller_elapsed_ms": @((double)elapsed / NSEC_PER_MSEC)});
    }
    BOOL retainedBlockedWork;
    @autoreleasepool { retainedBlockedWork = weakConnection != nil; }
    uint64_t deadline = TestNanoseconds() + NSEC_PER_SEC;
    BOOL released = NO;
    do {
        @autoreleasepool { released = weakConnection == nil; }
        if (!released) [NSThread sleepForTimeInterval:0.001];
    } while (!released && TestNanoseconds() < deadline);
    CommandChild(child, 0); (void)ReapChild(child);
    Check(@"timed-out worker retains native call then closes unclaimed observation", retainedBlockedWork
        && weakConnection == nil && state.terminalCount == 0 && state.failureCount == 0,
        @{@"retained_while_blocked": @(retainedBlockedWork), @"released_after_return": @(weakConnection == nil),
          @"terminals": @(state.terminalCount), @"failures": @(state.failureCount)});
}

static void TestInvalidPID(void) {
    FixtureConnection *connection = [FixtureConnection new]; connection.fixturePID = -1;
    ObservationState *state = [ObservationState new]; NSError *error = nil;
    MuesliNativeProcessObserver *observer = Arm(connection, state, FixtureRequirement, 1, &error);
    Check(@"invalid connection PID fails closed", observer == nil && error.code == MuesliProcessObserverErrorConnectionUnavailable
        && state.terminalCount == 0 && state.failureCount == 0, nil);
    connection.fixturePID = INT_MAX;
    observer = Arm(connection, state, FixtureRequirement, 1, &error);
    Check(@"nonexistent process identity fails closed", observer == nil && error.code == MuesliProcessObserverErrorIdentityUnavailable
        && state.terminalCount == 0 && state.failureCount == 0, nil);
}

static void TestQueuedExitDuringArming(const char *executable) {
    Child child = LaunchChild(executable);
    FixtureConnection *connection = [FixtureConnection new]; connection.fixturePID = child.pid;
    connection.exitBeforeRevalidation = YES; connection.childControl = child.control;
    ObservationState *state = [ObservationState new]; NSError *error = nil;
    MuesliNativeProcessObserver *observer = Arm(connection, state, FixtureRequirement, 2, &error);
    close(child.control); // The PID-getter boundary has already reaped this child.
    BOOL delivered = AwaitTerminal(state);
    Check(@"exit queued during final connection check is retained through arm handoff", observer != nil && delivered
        && state.terminalCount == 1 && state.failureCount == 0 && state.termination.exitCode == 125
        && state.termination.processIdentifier == child.pid, @{@"arm_error": error.description ?: @""});
}

static void TestKernelQueueCreationFailure(const char *executable) {
    Child child = LaunchChild(executable);
    FixtureConnection *connection = [FixtureConnection new]; connection.fixturePID = child.pid;
    ObservationState *state = [ObservationState new]; NSError *error = nil;
    atomic_store(&exhaustDescriptorsAtKqueue, true);
    MuesliNativeProcessObserver *observer = Arm(connection, state, FixtureRequirement, 2, &error);
    CommandChild(child, 0); (void)ReapChild(child);
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    Check(@"actual kernel queue creation failure fails closed", observer == nil
        && error.code == MuesliProcessObserverErrorKernelRegistration && underlying.code == EMFILE
        && state.terminalCount == 0 && state.failureCount == 0,
        @{@"error_code": @(error.code), @"underlying_code": @(underlying.code)});
}

int main(int argc, const char **argv) {
    if (argc == 2 && strcmp(argv[1], "--child") == 0) {
        if (write(STDOUT_FILENO, "R", 1) != 1) _exit(90);
        unsigned char command = 0;
        if (read(STDIN_FILENO, &command, 1) != 1) _exit(91);
        if (command == 255) raise(SIGKILL);
        _exit(command);
    }
    @autoreleasepool {
        results = [NSMutableArray new];
        TestExit(argv[0], 125, @"normal exit 125 is preserved");
        TestExit(argv[0], 255, @"SIGKILL 9 stays distinct from normal exit 125");
        TestExit(argv[0], 126, @"normal exit 126 stays distinct from retirement");
        for (int index = 0; index < 20; index++) TestExit(argv[0], 0, [NSString stringWithFormat:@"immediate exit after arming %d", index]);
        TestDroppedHandle(argv[0]);
        TestInvalidPID();
        TestRejected(argv[0], @"not a valid requirement !", NO, MuesliProcessObserverErrorCodeSigningRequirement, @"malformed signature requirement fails closed");
        TestRejected(argv[0], @"identifier \"another.executable\"", NO, MuesliProcessObserverErrorCodeSignatureRejected, @"wrong executable signature fails closed");
        TestRejected(argv[0], FixtureRequirement, YES, MuesliProcessObserverErrorIdentityChanged, @"connection PID changes during arming fail closed");
        TestDeadline(argv[0]);
        TestQueuedExitDuringArming(argv[0]);
        TestKernelQueueCreationFailure(argv[0]);
        NSDictionary *report = @{@"passed": @(failures == 0), @"assertions": @(results.count), @"failures": @(failures),
            @"boundary": @"NSXPCConnection PID getter and descriptor-exhaustion timing before real kqueue; all child processes, code signatures, proc identity, kqueue registration and exit status are native", @"results": results};
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
        return failures == 0 ? 0 : 1;
    }
}
