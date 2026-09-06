#import "InferenceProtocolV2.h"
NS_ASSUME_NONNULL_BEGIN
// Service-owned immutable admission. The service retains this object through
// actual process exit, including after a Python return or a terminal reply.
@interface MuesliSourceAdmission : NSObject
@property(nonatomic, readonly, copy) NSURL *sourceURL;
@property(nonatomic, readonly, copy) NSString *pythonLeaseToken;
@property(nonatomic, readonly, copy, nullable) NSString *liveAudioPath;
@property(nonatomic, readonly, copy, nullable) NSString *liveSourceID;
+ (nullable instancetype)admitURL:(NSURL *)url lease:(MuesliSourceLease *)lease
                     liveSource:(MuesliLiveSource * _Nullable)liveSource error:(NSError **)error;
- (BOOL)validate:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
