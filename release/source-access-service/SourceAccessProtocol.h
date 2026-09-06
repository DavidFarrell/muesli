#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// This service contains native file admission and AppKit selection only. It
// never accepts a URL, incoming bookmark, command, environment or model path.
static NSString *const MuesliSourceAccessServiceName = @"paidiaconsulting.MuesliApp.SourceAccessService";
static NSString *const MuesliSourceAccessServiceRequirement = @"anchor apple generic and certificate leaf[subject.OU] = \"JA9EPB8K4N\" and identifier \"paidiaconsulting.MuesliApp.SourceAccessService\"";

typedef void (^ NS_SWIFT_SENDABLE MuesliSourceAuthorizationReply)(BOOL authorized, NSString * _Nullable failure);
typedef void (^ NS_SWIFT_SENDABLE MuesliSourceBookmarkReply)(NSData * _Nullable bookmark, NSString * _Nullable failure);
typedef void (^ NS_SWIFT_SENDABLE MuesliSourceRetirementReply)(BOOL retired);
typedef void (^ NS_SWIFT_SENDABLE MuesliSourceSessionEndReply)(void);

@protocol MuesliSourceAccessService
// The supplied path and identity are expectations, not authority. The broker
// compares its own direct panel URL and original open directory to all three.
- (void)authorizeRootPath:(NSString *)path
         directoryDevice:(uint64_t)device
          directoryInode:(uint64_t)inode
                   reply:(MuesliSourceAuthorizationReply)reply
    NS_SWIFT_NAME(authorizeRoot(path:device:inode:reply:));

// Child is exactly one directory component beneath the original selected root.
// Lease is the versioned seven-word (56-byte) MuesliSourceLease record. The reply
// is an implicit bookmark for that child only, never the selected library root.
- (void)bookmarkChild:(NSString *)child
               jobID:(NSUUID *)jobID
         leaseRecord:(NSData *)leaseRecord
               reply:(MuesliSourceBookmarkReply)reply
    NS_SWIFT_NAME(bookmark(child:jobID:leaseRecord:reply:));

// The trusted main owner calls this only after matching native process exit.
// An early/duplicate retirement also closes that job ID against a later request.
- (void)retireJob:(NSUUID *)jobID reply:(MuesliSourceRetirementReply)reply
    NS_SWIFT_NAME(retire(jobID:reply:));

// Normal main shutdown waits for its original active job tokens before calling
// this. Connection invalidation also ends the service; it is never exit evidence
// for an inference process and cannot retire the main owner's source pins.
- (void)endSessionWithReply:(MuesliSourceSessionEndReply)reply
    NS_SWIFT_NAME(endSession(reply:));
@end

NS_ASSUME_NONNULL_END
