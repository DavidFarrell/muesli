#import "../InferenceProtocolV2.h"
static id RoundTrip(id<NSSecureCoding> value, Class type) {
    NSError *error=nil;
    NSData *data=[NSKeyedArchiver archivedDataWithRootObject:value requiringSecureCoding:YES error:&error];
    NSCAssert(data && !error,@"secure encode");
    id decoded=[NSKeyedUnarchiver unarchivedObjectOfClass:type fromData:data error:&error];
    NSCAssert(decoded && !error,@"secure decode"); return decoded;
}
int main(void) {
    @autoreleasepool {
        MuesliSourceLease *lease=[[MuesliSourceLease alloc] initWithDirectoryDevice:UINT64_MAX directoryInode:2
            accessDevice:3 accessInode:4 backendDevice:5 backendInode:6];
        NSCAssert(lease.record.length==56 && lease.directoryDevice==UINT64_MAX,@"unsigned exact record");
        MuesliSourceLease *decoded=RoundTrip(lease,MuesliSourceLease.class);
        NSCAssert([decoded.record isEqual:lease.record] && decoded.backendInode==6,@"fixed identity survives coding");
        for (NSUInteger length=0;length<60;length++) {
            if(length==56)continue;
            NSCAssert(![[MuesliSourceLease alloc] initWithRecord:[NSMutableData dataWithLength:length]],@"size rejected");
        }
        NSMutableData *record=[lease.record mutableCopy];((unsigned char *)record.mutableBytes)[7]=2;
        NSCAssert(![[MuesliSourceLease alloc] initWithRecord:record],@"unknown version rejected");
        NSUUID *instance=NSUUID.UUID,*job=NSUUID.UUID,*source=NSUUID.UUID;
        for (NSString *bad in @[@"",@".",@"..",@"../audio",@"audio/child",@"audio-session-0",@"audio-session-01",@"audio-session-1000000000",@"audio-session-1/..",@"AUDIO"]) {
            NSCAssert(![[MuesliLiveSource alloc] initWithAudioFolder:bad sourceID:source],@"folder syntax rejected");
        }
        MuesliLiveSource *live=[[MuesliLiveSource alloc] initWithAudioFolder:@"audio-session-2" sourceID:source];
        NSCAssert([[(MuesliLiveSource *)RoundTrip(live,MuesliLiveSource.class) sourceID] isEqual:source],@"source roundtrip");
        NSData *bookmark=[@"fixture" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *digest=MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,job,bookmark,lease,live,MuesliInferenceStreamsBoth);
        NSCAssert(digest.length==32,@"fixed digest");
        NSCAssert([digest isEqual:MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,job,bookmark,decoded,live,MuesliInferenceStreamsBoth)],@"stable across coding");
        NSCAssert(![digest isEqual:MuesliInferenceRequestDigest(MuesliInferenceOperationLive,NSUUID.UUID,job,bookmark,lease,live,MuesliInferenceStreamsBoth)],@"instance bound");
        NSCAssert(![digest isEqual:MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,NSUUID.UUID,bookmark,lease,live,MuesliInferenceStreamsBoth)],@"job bound");
        NSCAssert(![digest isEqual:MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,job,[NSData dataWithBytes:"x" length:1],lease,live,MuesliInferenceStreamsBoth)],@"bookmark bound");
        NSCAssert(![digest isEqual:MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,job,bookmark,lease,live,MuesliInferenceStreamsMic)],@"streams bound");
        MuesliLiveSource *other=[[MuesliLiveSource alloc] initWithAudioFolder:@"audio" sourceID:source];
        NSCAssert(![digest isEqual:MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,job,bookmark,lease,other,MuesliInferenceStreamsBoth)],@"folder bound");
        other=[[MuesliLiveSource alloc] initWithAudioFolder:live.audioFolder sourceID:NSUUID.UUID];
        NSCAssert(![digest isEqual:MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,job,bookmark,lease,other,MuesliInferenceStreamsBoth)],@"source UUID bound");
        NSCAssert(!MuesliInferenceRequestDigest(MuesliInferenceOperationReprocess,instance,job,bookmark,lease,live,MuesliInferenceStreamsBoth),@"batch may not carry live source");
        NSCAssert(!MuesliInferenceRequestDigest(MuesliInferenceOperationLive,instance,job,bookmark,lease,nil,MuesliInferenceStreamsBoth),@"live requires source");
        NSCAssert(!MuesliInferenceRequestDigest((MuesliInferenceOperation)99,instance,job,bookmark,lease,nil,MuesliInferenceStreamsBoth),@"unknown operation");
        NSCAssert(!MuesliInferenceRequestDigest(MuesliInferenceOperationReprocess,instance,job,[NSData data],lease,nil,MuesliInferenceStreamsBoth),@"empty bookmark");
        NSCAssert(!MuesliInferenceRequestDigest(MuesliInferenceOperationReprocess,instance,job,[NSMutableData dataWithLength:65537],lease,nil,MuesliInferenceStreamsBoth),@"oversize bookmark");
        MuesliServiceReservation *reservation=[[MuesliServiceReservation alloc] initWithInstanceID:instance jobID:job processID:100 runtimeManifestSHA256:digest modelManifestSHA256:digest];
        NSCAssert([(MuesliServiceReservation *)RoundTrip(reservation,MuesliServiceReservation.class) processID]==100,@"reservation roundtrip");
        NSCAssert(![[MuesliServiceReservation alloc] initWithInstanceID:instance jobID:job processID:1 runtimeManifestSHA256:digest modelManifestSHA256:digest],@"invalid pid");
        MuesliOperationResult *result=[[MuesliOperationResult alloc] initWithInstanceID:instance jobID:job requestDigest:digest operationStatus:0 message:@""];
        NSCAssert([(MuesliOperationResult *)RoundTrip(result,MuesliOperationResult.class) operationStatus]==0,@"operation result distinct from exit");
        NSCAssert(![[MuesliOperationResult alloc] initWithInstanceID:instance jobID:job requestDigest:digest operationStatus:256 message:@""],@"bounded operation code");
        NSCAssert(MuesliServiceInterfaceV2() && MuesliClientInterfaceV2(),@"fixed XPC class interfaces");
        puts("Protocol V2 secure coding, bounds and digest tests passed");
    }
}
