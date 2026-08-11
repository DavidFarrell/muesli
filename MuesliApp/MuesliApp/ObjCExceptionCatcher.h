#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MuesliObjCExceptionErrorDomain;
extern NSErrorUserInfoKey const MuesliObjCExceptionNameKey;
extern NSErrorUserInfoKey const MuesliObjCExceptionReasonKey;

@interface ObjCExceptionCatcher : NSObject
/// Runs the block; an NSException raised inside it is returned as an NSError
/// (domain MuesliObjCExceptionErrorDomain, userInfo carries the exception name
/// and reason) instead of propagating.
+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))tryBlock
                 error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
