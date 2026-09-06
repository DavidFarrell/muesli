#import <Foundation/Foundation.h>

// Inputs are capabilities and a fixed operation name, never commands or import paths.
@protocol MuesliInferenceService
- (void)policyProbeToPort:(NSNumber *)port reply:(void (^)(NSDictionary *))reply;
- (void)runOperation:(NSString *)operation
              jobID:(NSUUID *)jobID
     sourceBookmark:(NSData *)sourceBookmark
      modelBookmark:(NSData *)modelBookmark
              input:(NSFileHandle *)input
             output:(NSFileHandle *)output
        diagnostics:(NSFileHandle *)diagnostics
              reply:(void (^)(NSDictionary *))reply;
- (void)cancelJob:(NSUUID *)jobID reply:(void (^)(BOOL))reply;
@end

static NSString * const MuesliServiceID = @"paidiaconsulting.MuesliApp.InferenceService";
static NSString * const MuesliProofID = @"paidiaconsulting.MuesliApp.InferenceProof";
