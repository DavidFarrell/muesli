#import "InferenceProtocolV2.h"
#import <CommonCrypto/CommonDigest.h>

static uint64_t Word(NSData *record, NSUInteger index) {
    uint64_t word = 0; memcpy(&word, (const char *)record.bytes + index * 8, 8);
    return CFSwapInt64BigToHost(word);
}
static BOOL ValidFolder(NSString *folder) {
    if (![folder isKindOfClass:NSString.class] || folder.length > 23) return NO;
    if ([folder isEqualToString:@"audio"]) return YES;
    NSString *prefix = @"audio-session-";
    if (![folder hasPrefix:prefix]) return NO;
    NSString *digits = [folder substringFromIndex:prefix.length];
    if (digits.length < 1 || digits.length > 9 || [digits characterAtIndex:0] == '0') return NO;
    for (NSUInteger i=0; i<digits.length; i++) { unichar c=[digits characterAtIndex:i]; if (c<'0' || c>'9') return NO; }
    return YES;
}
@implementation MuesliSourceLease
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithDirectoryDevice:(uint64_t)directoryDevice directoryInode:(uint64_t)directoryInode
                          accessDevice:(uint64_t)accessDevice accessInode:(uint64_t)accessInode
                         backendDevice:(uint64_t)backendDevice backendInode:(uint64_t)backendInode {
    uint64_t words[] = {1,directoryDevice,directoryInode,accessDevice,accessInode,backendDevice,backendInode};
    for (int i=0; i<7; i++) words[i]=CFSwapInt64HostToBig(words[i]);
    return [self initWithRecord:[NSData dataWithBytes:words length:sizeof(words)]];
}
- (instancetype)initWithRecord:(NSData *)record {
    if (![record isKindOfClass:NSData.class] || record.length != 56 || Word(record,0) != 1) return nil;
    if ((self=[super init])) _record=[record copy];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithRecord:[coder decodeObjectOfClass:NSData.class forKey:@"record"]]; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_record forKey:@"record"]; }
- (uint64_t)directoryDevice { return Word(_record,1); }
- (uint64_t)directoryInode { return Word(_record,2); }
- (uint64_t)accessDevice { return Word(_record,3); }
- (uint64_t)accessInode { return Word(_record,4); }
- (uint64_t)backendDevice { return Word(_record,5); }
- (uint64_t)backendInode { return Word(_record,6); }
@end

@implementation MuesliLiveSource
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithAudioFolder:(NSString *)audioFolder sourceID:(NSUUID *)sourceID {
    if (!ValidFolder(audioFolder) || ![sourceID isKindOfClass:NSUUID.class]) return nil;
    if ((self=[super init])) { _audioFolder=[audioFolder copy]; _sourceID=[sourceID copy]; }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    return [self initWithAudioFolder:[coder decodeObjectOfClass:NSString.class forKey:@"folder"]
                           sourceID:[coder decodeObjectOfClass:NSUUID.class forKey:@"source"]];
}
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_audioFolder forKey:@"folder"]; [coder encodeObject:_sourceID forKey:@"source"]; }
@end

@implementation MuesliServiceReservation
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithInstanceID:(NSUUID *)instanceID jobID:(NSUUID *)jobID processID:(int32_t)processID
            runtimeManifestSHA256:(NSData *)runtimeHash modelManifestSHA256:(NSData *)modelHash {
    if (![instanceID isKindOfClass:NSUUID.class] || ![jobID isKindOfClass:NSUUID.class] || processID <= 1
        || ![runtimeHash isKindOfClass:NSData.class] || runtimeHash.length != 32
        || ![modelHash isKindOfClass:NSData.class] || modelHash.length != 32) return nil;
    if ((self=[super init])) { _protocolVersion=MuesliInferenceProtocolVersion; _instanceID=[instanceID copy]; _jobID=[jobID copy];
        _processID=processID; _runtimeManifestSHA256=[runtimeHash copy]; _modelManifestSHA256=[modelHash copy]; }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ([coder decodeInt64ForKey:@"version"] != MuesliInferenceProtocolVersion) return nil;
    int64_t pid=[coder decodeInt64ForKey:@"pid"];
    if (pid <= 1 || pid > INT32_MAX) return nil;
    return [self initWithInstanceID:[coder decodeObjectOfClass:NSUUID.class forKey:@"instance"]
                             jobID:[coder decodeObjectOfClass:NSUUID.class forKey:@"job"] processID:(int32_t)pid
             runtimeManifestSHA256:[coder decodeObjectOfClass:NSData.class forKey:@"runtime"]
               modelManifestSHA256:[coder decodeObjectOfClass:NSData.class forKey:@"model"]];
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt64:_protocolVersion forKey:@"version"]; [coder encodeObject:_instanceID forKey:@"instance"];
    [coder encodeObject:_jobID forKey:@"job"]; [coder encodeInt64:_processID forKey:@"pid"];
    [coder encodeObject:_runtimeManifestSHA256 forKey:@"runtime"]; [coder encodeObject:_modelManifestSHA256 forKey:@"model"];
}
@end

@implementation MuesliOperationResult
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithInstanceID:(NSUUID *)instanceID jobID:(NSUUID *)jobID
                    requestDigest:(NSData *)requestDigest operationStatus:(int32_t)status message:(NSString *)message {
    if (![instanceID isKindOfClass:NSUUID.class] || ![jobID isKindOfClass:NSUUID.class]
        || ![requestDigest isKindOfClass:NSData.class] || requestDigest.length != 32
        || ![message isKindOfClass:NSString.class] || [message lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>1024
        || status < 0 || status > 255) return nil;
    if ((self=[super init])) { _instanceID=[instanceID copy]; _jobID=[jobID copy]; _requestDigest=[requestDigest copy];
        _operationStatus=status; _message=[message copy]; }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    int64_t status=[coder decodeInt64ForKey:@"status"];
    if (status<0 || status>255) return nil;
    return [self initWithInstanceID:[coder decodeObjectOfClass:NSUUID.class forKey:@"instance"]
                             jobID:[coder decodeObjectOfClass:NSUUID.class forKey:@"job"]
                     requestDigest:[coder decodeObjectOfClass:NSData.class forKey:@"digest"] operationStatus:(int32_t)status
                           message:[coder decodeObjectOfClass:NSString.class forKey:@"message"]];
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_instanceID forKey:@"instance"]; [coder encodeObject:_jobID forKey:@"job"];
    [coder encodeObject:_requestDigest forKey:@"digest"]; [coder encodeInt64:_operationStatus forKey:@"status"];
    [coder encodeObject:_message forKey:@"message"];
}
@end

static void AppendWord(NSMutableData *data,uint64_t value) { uint64_t big=CFSwapInt64HostToBig(value); [data appendBytes:&big length:8]; }
static void AppendID(NSMutableData *data,NSUUID *value) { uuid_t bytes; [value getUUIDBytes:bytes]; [data appendBytes:bytes length:16]; }
NSData *MuesliInferenceRequestDigest(MuesliInferenceOperation operation, NSUUID *instanceID, NSUUID *jobID,
    NSData *sourceBookmark, MuesliSourceLease *lease, MuesliLiveSource *liveSource, MuesliInferenceStreams streams) {
    if (operation<1 || operation>3 || streams<1 || streams>3 || ![instanceID isKindOfClass:NSUUID.class] || ![jobID isKindOfClass:NSUUID.class]
        || ![sourceBookmark isKindOfClass:NSData.class] || sourceBookmark.length<1 || sourceBookmark.length>65536
        || ![lease isKindOfClass:MuesliSourceLease.class] || lease.record.length!=56) return nil;
    if ((operation==MuesliInferenceOperationLive) != (liveSource!=nil)) return nil;
    if (liveSource && (![liveSource isKindOfClass:MuesliLiveSource.class] || !ValidFolder(liveSource.audioFolder)
        || ![liveSource.sourceID isKindOfClass:NSUUID.class])) return nil;
    NSMutableData *record=[NSMutableData data];
    [record appendData:[@"MuesliInferenceRequestV2" dataUsingEncoding:NSASCIIStringEncoding]];
    AppendWord(record,MuesliInferenceProtocolVersion); AppendID(record,instanceID); AppendID(record,jobID);
    AppendWord(record,operation); AppendWord(record,streams); [record appendData:lease.record];
    AppendWord(record,liveSource!=nil);
    if (liveSource) { NSData *name=[liveSource.audioFolder dataUsingEncoding:NSASCIIStringEncoding]; AppendWord(record,name.length); [record appendData:name]; AppendID(record,liveSource.sourceID); }
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(sourceBookmark.bytes,(CC_LONG)sourceBookmark.length,hash);
    [record appendBytes:hash length:sizeof(hash)]; CC_SHA256(record.bytes,(CC_LONG)record.length,hash);
    return [NSData dataWithBytes:hash length:sizeof(hash)];
}
NSXPCInterface *MuesliServiceInterfaceV2(void) {
    NSXPCInterface *value=[NSXPCInterface interfaceWithProtocol:@protocol(MuesliInferenceServiceV2)];
    SEL run=@selector(runOperation:instanceID:jobID:sourceBookmark:sourceLease:liveSource:streams:requestDigest:input:output:diagnostics:reply:);
    [value setClasses:[NSSet setWithObject:MuesliSourceLease.class] forSelector:run argumentIndex:4 ofReply:NO];
    [value setClasses:[NSSet setWithObject:MuesliLiveSource.class] forSelector:run argumentIndex:5 ofReply:NO];
    [value setClasses:[NSSet setWithObject:MuesliOperationResult.class] forSelector:run argumentIndex:0 ofReply:YES];
    [value setClasses:[NSSet setWithObject:MuesliServiceReservation.class] forSelector:@selector(reserveJob:reply:) argumentIndex:0 ofReply:YES];
    return value;
}
NSXPCInterface *MuesliClientInterfaceV2(void) { return [NSXPCInterface interfaceWithProtocol:@protocol(MuesliInferenceClientV2)]; }
