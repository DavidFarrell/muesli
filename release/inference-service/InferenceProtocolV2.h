#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// A fixed source-free reservation precedes every source-bearing request.
static const uint64_t MuesliInferenceProtocolVersion = 2;
typedef NS_ENUM(uint64_t, MuesliInferenceOperation) {
    MuesliInferenceOperationPreflight = 1,
    MuesliInferenceOperationLive = 2,
    MuesliInferenceOperationReprocess = 3,
};
typedef NS_ENUM(uint64_t, MuesliInferenceStreams) {
    MuesliInferenceStreamsSystem = 1,
    MuesliInferenceStreamsMic = 2,
    MuesliInferenceStreamsBoth = 3,
};

// Wire record: exactly seven big-endian UInt64 words: version=1, then
// directory device/inode, access-lock device/inode, backend-lock device/inode.
// No source path, command, environment, import path or descriptor is encoded.
NS_SWIFT_SENDABLE
@interface MuesliSourceLease : NSObject <NSSecureCoding>
@property(nonatomic, readonly, copy) NSData *record;
@property(nonatomic, readonly) uint64_t directoryDevice;
@property(nonatomic, readonly) uint64_t directoryInode;
@property(nonatomic, readonly) uint64_t accessDevice;
@property(nonatomic, readonly) uint64_t accessInode;
@property(nonatomic, readonly) uint64_t backendDevice;
@property(nonatomic, readonly) uint64_t backendInode;
- (instancetype)initWithDirectoryDevice:(uint64_t)directoryDevice directoryInode:(uint64_t)directoryInode
                          accessDevice:(uint64_t)accessDevice accessInode:(uint64_t)accessInode
                         backendDevice:(uint64_t)backendDevice backendInode:(uint64_t)backendInode;
- (nullable instancetype)initWithRecord:(NSData *)record;
@end

// A live source is an explicit prepared child of the leased meeting root.
// Only audio or audio-session-[1-9][0-9]{0,8}, and a canonical UUID, are valid.
// Native admission matches this UUID to the bounded source manifest; the live
// backend must also match the later meetingStart source_session_id exactly.
NS_SWIFT_SENDABLE
@interface MuesliLiveSource : NSObject <NSSecureCoding>
@property(nonatomic, readonly, copy) NSString *audioFolder;
@property(nonatomic, readonly, copy) NSUUID *sourceID;
- (nullable instancetype)initWithAudioFolder:(NSString *)audioFolder sourceID:(NSUUID *)sourceID;
@end

// The hashes identify actual files in this signed proof bundle. They are not
// an expected lock, a model-loading claim, or caller-selected model metadata.
NS_SWIFT_SENDABLE
@interface MuesliServiceReservation : NSObject <NSSecureCoding>
@property(nonatomic, readonly) uint64_t protocolVersion;
@property(nonatomic, readonly, copy) NSUUID *instanceID;
@property(nonatomic, readonly, copy) NSUUID *jobID;
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, readonly, copy) NSData *runtimeManifestSHA256;
@property(nonatomic, readonly, copy) NSData *modelManifestSHA256;
- (nullable instancetype)initWithInstanceID:(NSUUID *)instanceID jobID:(NSUUID *)jobID processID:(int32_t)processID
                    runtimeManifestSHA256:(NSData *)runtimeHash modelManifestSHA256:(NSData *)modelHash;
@end

// operationStatus describes native/Python operation return ONLY. The service
// still performs owned process-group cleanup; actual kernel termination status,
// transport invalidation, output EOF and journal closure are distinct facts.
NS_SWIFT_SENDABLE
@interface MuesliOperationResult : NSObject <NSSecureCoding>
@property(nonatomic, readonly, copy) NSUUID *instanceID;
@property(nonatomic, readonly, copy) NSUUID *jobID;
@property(nonatomic, readonly, copy) NSData *requestDigest;
@property(nonatomic, readonly) int32_t operationStatus;
@property(nonatomic, readonly, copy) NSString *message;
- (nullable instancetype)initWithInstanceID:(NSUUID *)instanceID jobID:(NSUUID *)jobID
                            requestDigest:(NSData *)requestDigest operationStatus:(int32_t)status message:(NSString *)message;
@end

@protocol MuesliInferenceClientV2
// Sent after native source/lock/live-manifest admission, BEFORE Python loads.
// This acknowledges ownership/admission, not model/transcript readiness.
- (void)acceptedJob:(NSUUID *)jobID instanceID:(NSUUID *)instanceID requestDigest:(NSData *)requestDigest;
@end

@protocol MuesliInferenceServiceV2
// Source-free. One reservation for this connection/process lifetime. Client
// binds the actual connection PID/start tuple and arms NOTE_EXIT before run.
- (void)reserveJob:(NSUUID *)jobID reply:(void (^)(MuesliServiceReservation * _Nullable reservation,
                                                NSString * _Nullable failure))reply;
- (void)runOperation:(MuesliInferenceOperation)operation
         instanceID:(NSUUID *)instanceID
              jobID:(NSUUID *)jobID
     sourceBookmark:(NSData *)sourceBookmark
        sourceLease:(MuesliSourceLease *)sourceLease
         liveSource:(MuesliLiveSource * _Nullable)liveSource
            streams:(MuesliInferenceStreams)streams
      requestDigest:(NSData *)requestDigest
              input:(NSFileHandle *)input
             output:(NSFileHandle *)output
        diagnostics:(NSFileHandle *)diagnostics
              reply:(void (^)(MuesliOperationResult *result))reply;
- (void)cancelJob:(NSUUID *)jobID instanceID:(NSUUID *)instanceID reply:(void (^)(BOOL accepted))reply;
- (void)policyProbeToPort:(NSNumber *)port reply:(void (^)(NSDictionary *))reply;
@end

// Canonical digest binds the exact invocation (including the bookmark bytes)
// to its reservation. Returns nil for any invalid operation/stream/source shape.
FOUNDATION_EXPORT NSData * _Nullable MuesliInferenceRequestDigest(MuesliInferenceOperation operation,
    NSUUID *instanceID, NSUUID *jobID, NSData *sourceBookmark, MuesliSourceLease *lease,
    MuesliLiveSource * _Nullable liveSource, MuesliInferenceStreams streams);
FOUNDATION_EXPORT NSXPCInterface *MuesliServiceInterfaceV2(void);
FOUNDATION_EXPORT NSXPCInterface *MuesliClientInterfaceV2(void);

NS_ASSUME_NONNULL_END
