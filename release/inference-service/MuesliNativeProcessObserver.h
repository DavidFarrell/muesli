#import <Foundation/Foundation.h>
#include <stdint.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const MuesliProcessObserverErrorDomain;
typedef NS_ERROR_ENUM(MuesliProcessObserverErrorDomain, MuesliProcessObserverError) {
    MuesliProcessObserverErrorInvalidArgument = 1,
    MuesliProcessObserverErrorDeadlineExceeded,
    MuesliProcessObserverErrorConnectionUnavailable,
    MuesliProcessObserverErrorIdentityUnavailable,
    MuesliProcessObserverErrorIdentityChanged,
    MuesliProcessObserverErrorCodeSigningRequirement,
    MuesliProcessObserverErrorCodeSignatureRejected,
    MuesliProcessObserverErrorKernelRegistration,
    MuesliProcessObserverErrorWorkerCreation,
    MuesliProcessObserverErrorKernelObservation,
};

typedef NS_ENUM(NSInteger, MuesliProcessTerminationKind) {
    MuesliProcessTerminationKindExited,
    MuesliProcessTerminationKindSignalled,
    MuesliProcessTerminationKindOther,
};

/// Evidence comes only from NOTE_EXIT with NOTE_EXITSTATUS for the registered
/// process instance. A normal exit125, signal9 and normal exit126 stay distinct.
NS_SWIFT_SENDABLE
@interface MuesliProcessTermination : NSObject
@property(nonatomic, readonly) pid_t processIdentifier;
@property(nonatomic, readonly) uint64_t startSeconds;
@property(nonatomic, readonly) uint64_t startMicroseconds;
@property(nonatomic, readonly) int32_t rawWaitStatus;
@property(nonatomic, readonly) uint32_t eventFlags;
@property(nonatomic, readonly) MuesliProcessTerminationKind kind;
@property(nonatomic, readonly) int32_t exitCode; // -1 unless kind is Exited.
@property(nonatomic, readonly) int32_t signal;   // 0 unless kind is Signalled.
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

typedef void (^ NS_SWIFT_SENDABLE MuesliProcessTerminationHandler)(MuesliProcessTermination *termination);
typedef void (^ NS_SWIFT_SENDABLE MuesliProcessObservationFailureHandler)(NSError *error);

/// An accepted observer retains itself and its dedicated worker until an actual
/// kernel exit event or an explicit observation failure. It does not own a child
/// group, send signals, or infer process death from XPC transport state.
NS_SWIFT_SENDABLE
@interface MuesliNativeProcessObserver : NSObject
@property(nonatomic, readonly) pid_t processIdentifier;
@property(nonatomic, readonly) uint64_t startSeconds;
@property(nonatomic, readonly) uint64_t startMicroseconds;
@property(nonatomic, readonly, nullable) MuesliProcessTermination *termination;
@property(nonatomic, readonly, nullable) NSError *observationFailure;

/// Call on an activated, source-free authenticated XPC connection. The expected
/// signing requirement is independently checked against the actual process.
/// Success binds the PID/start tuple before the caller sends source capabilities.
/// Registration has a bounded caller wait; a deadline is never exit evidence.
/// The timeout must be finite, greater than zero, and at most sixty seconds.
/// Callbacks run off MainActor and may occur before this method returns. Failure
/// callbacks and arm errors are NOT terminal evidence and must not release an
/// already-granted source lease. There is deliberately no cancellation API:
/// dropping this handle or invalidating the connection cannot cancel observation.
+ (nullable instancetype)armConnection:(NSXPCConnection *)connection
               codeSigningRequirement:(NSString *)requirement
                              timeout:(NSTimeInterval)timeout
                   terminationHandler:(MuesliProcessTerminationHandler)terminationHandler
                       failureHandler:(nullable MuesliProcessObservationFailureHandler)failureHandler
                                error:(NSError * _Nullable * _Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
