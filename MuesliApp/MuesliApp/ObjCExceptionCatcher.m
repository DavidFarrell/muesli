#import "ObjCExceptionCatcher.h"

NSErrorDomain const MuesliObjCExceptionErrorDomain = @"MuesliObjCExceptionErrorDomain";
NSErrorUserInfoKey const MuesliObjCExceptionNameKey = @"MuesliObjCExceptionName";
NSErrorUserInfoKey const MuesliObjCExceptionReasonKey = @"MuesliObjCExceptionReason";

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))tryBlock
                 error:(NSError **)error {
    @try {
        tryBlock();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            // NSException.reason is nullable; map it so the Swift side never
            // sees a missing key.
            *error = [NSError errorWithDomain:MuesliObjCExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                MuesliObjCExceptionNameKey: exception.name,
                MuesliObjCExceptionReasonKey: exception.reason ?: @"unknown"
            }];
        }
        return NO;
    }
}

@end
