#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Native verification only: no Python/package/model imports before reserve.
@interface MuesliVerifiedPayload : NSObject
@property(nonatomic, readonly, copy) NSData *runtimeManifestSHA256;
@property(nonatomic, readonly, copy) NSData *modelManifestSHA256;
@property(nonatomic, readonly, copy) NSString *runtimePath;
@property(nonatomic, readonly, copy) NSString *modelPath;
+ (nullable instancetype)verifyBundle:(NSBundle *)bundle error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
