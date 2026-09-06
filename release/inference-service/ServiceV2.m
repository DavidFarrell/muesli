#import "InferenceProtocolV2.h"
#import "SourceLeaseAdmission.h"
#import "VerifiedPayload.h"
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>
#ifndef MUESLI_SIGNING_TEAM
#error MUESLI_SIGNING_TEAM is required
#endif
int MuesliRunPythonV2(NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, int, int, int);

static NSDictionary *NetworkAttempt(int family, int type, unsigned short port) {
    int fd = socket(family, type, 0);
    if (fd < 0) return @{ @"result": @(-1), @"errno": @(errno), @"stage": @"socket" };
    int result;
    if (family == AF_INET) {
        struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET,
            .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        result = type == SOCK_DGRAM ? (int)sendto(fd, "probe", 5, 0, (void *)&address, sizeof(address))
                                    : connect(fd, (void *)&address, sizeof(address));
    } else {
        struct sockaddr_in6 address = { .sin6_len = sizeof(address), .sin6_family = AF_INET6,
            .sin6_port = htons(port), .sin6_addr = IN6ADDR_LOOPBACK_INIT };
        result = type == SOCK_DGRAM ? (int)sendto(fd, "probe", 5, 0, (void *)&address, sizeof(address))
                                    : connect(fd, (void *)&address, sizeof(address));
    }
    int error = errno;
    close(fd);
    return @{ @"result": @(result), @"errno": @(result < 0 ? error : 0), @"stage": @"operation" };
}

@interface InferenceServiceV2 : NSObject <NSXPCListenerDelegate, MuesliInferenceServiceV2>
@property(nonatomic) NSLock *lock;
@property(nonatomic) NSUUID *instance;
@property(nonatomic) NSUUID *job;
@property(nonatomic) NSXPCConnection *connection;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL retiring;
@property(nonatomic) NSUInteger sourceAttempts;
@property(nonatomic) NSUInteger pythonEntries;
@property(nonatomic) BOOL ownsGroup;
@property(nonatomic) dispatch_queue_t deadline;
@property(nonatomic) dispatch_queue_t worker;
@property(nonatomic) MuesliVerifiedPayload *payload;
// Never clear these on reply. Native/Python threads and descendants may remain.
// Process termination is the only release boundary after source admission.
@property(nonatomic) MuesliSourceAdmission *sourceAdmission;
@property(nonatomic) NSURL *sourceGrant;
@end
@implementation InferenceServiceV2
- (instancetype)init {
    if((self=[super init])) {
        _lock=[NSLock new];_instance=[NSUUID UUID];
        _deadline=dispatch_queue_create("muesli.service.deadline",DISPATCH_QUEUE_SERIAL);
        _worker=dispatch_queue_create("muesli.service.single-job",DISPATCH_QUEUE_SERIAL);
        if(getpgrp()!=getpid())setpgid(0,0);_ownsGroup=getpgrp()==getpid();
    }return self;
}
- (void)terminateOwnedProcess {
    // 125 is the fallback after an accepted group kill; 126 means group
    // retirement could not be requested. Neither is a fabricated exit zero.
    if(self.ownsGroup && getpgrp()==getpid() && kill(-getpid(),SIGKILL)==0)_exit(125);
    _exit(126);
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    (void)listener;
#if MUESLI_INFERENCE_PROOF_BUILD
    [connection setCodeSigningRequirement:@"anchor apple generic and certificate leaf[subject.OU] = \"" MUESLI_SIGNING_TEAM @"\" and identifier \"paidiaconsulting.MuesliApp.InferenceProof\""];
#else
    [connection setCodeSigningRequirement:@"anchor apple generic and certificate leaf[subject.OU] = \"" MUESLI_SIGNING_TEAM @"\" and identifier \"paidiaconsulting.MuesliApp\""];
#endif
    connection.exportedInterface=MuesliServiceInterfaceV2();connection.exportedObject=self;
    connection.remoteObjectInterface=MuesliClientInterfaceV2();
    __weak InferenceServiceV2 *weakSelf=self;__weak NSXPCConnection *weakConnection=connection;
    connection.invalidationHandler=^{
        InferenceServiceV2 *owner=weakSelf;[owner.lock lock];BOOL active=owner.job!=nil && owner.connection==weakConnection;[owner.lock unlock];
        if(active)[owner terminateOwnedProcess];
    };
    [connection activate];return YES;
}
- (void)reserveJob:(NSUUID *)jobID reply:(void (^)(MuesliServiceReservation *,NSString *))reply {
    if(![jobID isKindOfClass:NSUUID.class] || !self.ownsGroup){reply(nil,@"Unavailable service ownership");return;}
    [self.lock lock];BOOL busy=self.job!=nil;
    if(!busy){self.job=jobID;self.connection=NSXPCConnection.currentConnection;}[self.lock unlock];
    if(busy){reply(nil,@"One reservation is admitted per service lifetime");return;}
    // No source/model import, bookmark or user path enters this phase. A
    // cancellation runs independently even if native payload IO stalls.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),self.deadline,^{
        [self.lock lock];BOOL reserved=!self.started;[self.lock unlock];if(reserved)[self terminateOwnedProcess];
    });
    dispatch_async(self.worker,^{@autoreleasepool{
        NSError *error=nil;MuesliVerifiedPayload *payload=[MuesliVerifiedPayload verifyBundle:NSBundle.mainBundle error:&error];
        if(!payload){reply(nil,@"Sealed runtime/model verification failed");[self retireSoon];return;}
        [self.lock lock];self.payload=payload;[self.lock unlock];
        reply([[MuesliServiceReservation alloc]initWithInstanceID:self.instance jobID:jobID processID:getpid()
            runtimeManifestSHA256:payload.runtimeManifestSHA256 modelManifestSHA256:payload.modelManifestSHA256],nil);
    }});
}
- (void)retireSoon {[self.lock lock];self.retiring=YES;[self.lock unlock];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),self.deadline,^{[self terminateOwnedProcess];});}
- (void)cancelJob:(NSUUID *)jobID instanceID:(NSUUID *)instanceID reply:(void (^)(BOOL))reply {
    [self.lock lock];BOOL match=[self.job isEqual:jobID] && [self.instance isEqual:instanceID] && self.connection==NSXPCConnection.currentConnection;BOOL first=match && !self.retiring;if(match)self.retiring=YES;[self.lock unlock];
    reply(match);if(first)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/5),self.deadline,^{[self terminateOwnedProcess];});
}
- (void)policyProbeToPort:(NSNumber *)port reply:(void (^)(NSDictionary *))reply {
    unsigned int value=port.unsignedIntValue;if(value==0 || value>65535){reply(@{@"error":@"Invalid port"});return;}
    [self.lock lock];NSString *job=self.job.UUIDString?:@"";NSUInteger sourceAttempts=self.sourceAttempts,pythonEntries=self.pythonEntries;[self.lock unlock];
    reply(@{@"pid":@(getpid()),@"owns_process_group":@(self.ownsGroup),@"active_job":job,@"source_attempts":@(sourceAttempts),@"python_entries":@(pythonEntries),
        @"tcp4":NetworkAttempt(AF_INET,SOCK_STREAM,value),@"udp4":NetworkAttempt(AF_INET,SOCK_DGRAM,value),
        @"tcp6":NetworkAttempt(AF_INET6,SOCK_STREAM,value),@"udp6":NetworkAttempt(AF_INET6,SOCK_DGRAM,value)});
}
- (NSURL *)resolve:(NSData *)bookmark error:(NSError **)error {
    BOOL stale=NO;NSURL *url=[NSURL URLByResolvingBookmarkData:bookmark
        options:NSURLBookmarkResolutionWithoutUI|NSURLBookmarkResolutionWithoutMounting relativeToURL:nil bookmarkDataIsStale:&stale error:error];
    // An ephemeral IPC bookmark may resolve successfully while its stored
    // representation is stale. The resolved URL still must pass the original
    // native directory/lock identities, read-only SH pins and final validation.
    if(!url.isFileURL){[url stopAccessingSecurityScopedResource];return nil;}
    return url;
}
- (void)runOperation:(MuesliInferenceOperation)operation instanceID:(NSUUID *)instanceID jobID:(NSUUID *)jobID
    sourceBookmark:(NSData *)sourceBookmark sourceLease:(MuesliSourceLease *)sourceLease liveSource:(MuesliLiveSource *)liveSource
    streams:(MuesliInferenceStreams)streams requestDigest:(NSData *)requestDigest input:(NSFileHandle *)input
    output:(NSFileHandle *)output diagnostics:(NSFileHandle *)diagnostics reply:(void (^)(MuesliOperationResult *))reply {
    NSData *digest=MuesliInferenceRequestDigest(operation,instanceID,jobID,sourceBookmark,sourceLease,liveSource,streams);
    BOOL shape=digest && [digest isEqual:requestDigest] && input && output && diagnostics;
    NSXPCConnection *connection=NSXPCConnection.currentConnection;
    [self.lock lock];BOOL admitted=shape && !self.started && !self.retiring && self.payload && [self.job isEqual:jobID]
        && [self.instance isEqual:instanceID] && self.connection==connection;
    if(admitted)self.started=YES;[self.lock unlock];
    if(!admitted){
        NSData *safeDigest=requestDigest.length==32 ? requestDigest : [NSMutableData dataWithLength:32];
        reply([[MuesliOperationResult alloc]initWithInstanceID:self.instance jobID:jobID?:[NSUUID UUID]
            requestDigest:safeDigest operationStatus:64 message:@"Request does not match an available reservation"]);return;
    }
    int64_t seconds=operation==MuesliInferenceOperationLive?86400:operation==MuesliInferenceOperationReprocess?3600:60;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,seconds*NSEC_PER_SEC),self.deadline,^{[self terminateOwnedProcess];});
    dispatch_async(self.worker,^{@autoreleasepool{
        [self.lock lock];BOOL cancelled=self.retiring;if(!cancelled)self.sourceAttempts++;[self.lock unlock];
        NSError *error=nil;NSURL *url=cancelled ? nil : [self resolve:sourceBookmark error:&error];
        // Retain even a later failed admission's grant until actual process exit.
        self.sourceGrant=url;
        MuesliSourceAdmission *source=url ? [MuesliSourceAdmission admitURL:url lease:sourceLease liveSource:liveSource error:&error] : nil;
        self.sourceAdmission=source;int result=66;
        [self.lock lock];BOOL canEnter=source && !self.retiring;[self.lock unlock];
        if(canEnter && [source validate:&error]) {
            [self.lock lock];canEnter=!self.retiring;if(canEnter)self.pythonEntries++;[self.lock unlock];
        } else canEnter=NO;
        if(canEnter) {
            id<MuesliInferenceClientV2> client=[connection remoteObjectProxyWithErrorHandler:^(NSError *failure){[self terminateOwnedProcess];}];
            [client acceptedJob:jobID instanceID:instanceID requestDigest:digest];
            NSString *name=operation==MuesliInferenceOperationLive?@"live":operation==MuesliInferenceOperationReprocess?@"reprocess":@"preflight";
            NSString *stream=streams==MuesliInferenceStreamsSystem?@"system":streams==MuesliInferenceStreamsMic?@"mic":@"both";
            result=MuesliRunPythonV2(self.payload.runtimePath,name,source.sourceURL.path,self.payload.modelPath,
                stream,liveSource.audioFolder?:@"",source.liveSourceID?:@"",source.pythonLeaseToken,
                input.fileDescriptor,output.fileDescriptor,diagnostics.fileDescriptor);
        }
        reply([[MuesliOperationResult alloc]initWithInstanceID:instanceID jobID:jobID requestDigest:digest
            operationStatus:result message:result==0?@"":@"Native admission or inference failed"]);
        [self retireSoon];
    }});
}
@end
int main(void){@autoreleasepool{InferenceServiceV2 *service=[InferenceServiceV2 new];NSXPCListener *listener=NSXPCListener.serviceListener;listener.delegate=service;[listener activate];}return 0;}
