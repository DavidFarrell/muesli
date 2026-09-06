#import "../InferenceProtocolV2.h"
#import "../SourceLeaseAdmission.h"
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>

// Generated signed protocol fixture, not a production backend or inference
// qualification. Faults are compile-time choices, never service RPC fields.
#ifndef MUESLI_FIXTURE_MODE
#define MUESLI_FIXTURE_MODE 0
#endif
#ifndef MUESLI_BACKEND_FIXTURE
#define MUESLI_BACKEND_FIXTURE 0
#endif
#ifndef MUESLI_BACKEND_EVENT_COUNT
#define MUESLI_BACKEND_EVENT_COUNT 601
#endif

// Only the extra BackendProcess harness enables these compile-time seams.
// The trace is a fixed generated-test path, never an RPC-supplied file name.
static void Trace(const char *event) {
#ifdef MUESLI_FIXTURE_TRACE_PATH
    int fd=open(MUESLI_FIXTURE_TRACE_PATH,O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC,0600);
    if(fd>=0) {dprintf(fd,"%s %d\n",event,getpid());close(fd);}
#else
    (void)event;
#endif
}
static BOOL ReadExact(int fd,void *buffer,size_t size) {
    size_t offset=0;
    while(offset<size) {ssize_t count=read(fd,(uint8_t *)buffer+offset,size-offset);if(count<=0)return NO;offset+=(size_t)count;}
    return YES;
}
static BOOL ReadFixtureFrame(NSFileHandle *input) {
    uint8_t header[14];
    if(!ReadExact(input.fileDescriptor,header,sizeof(header)))return NO;
    uint32_t length=0;memcpy(&length,header+10,4);length=CFSwapInt32LittleToHost(length);
    const char expected[]="{\"type\":\"fixture_control\"}";
    if(header[0]!=3 || header[1]!=0 || length!=sizeof(expected)-1)return NO;
    char payload[sizeof(expected)-1];
    return ReadExact(input.fileDescriptor,payload,sizeof(payload)) && memcmp(payload,expected,sizeof(payload))==0;
}

static NSData *Hash(uint8_t value) { uint8_t bytes[32]; memset(bytes,value,sizeof(bytes));return [NSData dataWithBytes:bytes length:sizeof(bytes)]; }
static void Later(double seconds, dispatch_block_t action) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),action);
}
@interface Fixture : NSObject <NSXPCListenerDelegate,MuesliInferenceServiceV2>
@property NSXPCConnection *connection;
@property NSUUID *instance;
@property NSUUID *job;
@property MuesliSourceAdmission *source;
@end
@implementation Fixture
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    (void)listener;
    if(_connection)return NO;
    [connection setCodeSigningRequirement:@"anchor apple generic and certificate leaf[subject.OU] = \"JA9EPB8K4N\" and identifier \"paidiaconsulting.MuesliApp.InferenceProof\""];
    connection.exportedInterface=MuesliServiceInterfaceV2();connection.exportedObject=self;
    connection.remoteObjectInterface=MuesliClientInterfaceV2();
    _connection=connection;_instance=[NSUUID UUID];[connection activate];return YES;
}
- (void)reserveJob:(NSUUID *)job reply:(void (^)(MuesliServiceReservation *,NSString *))reply {
    if(_job){reply(nil,@"already reserved");return;}_job=job;
    Trace("reserved");
    if(MUESLI_FIXTURE_MODE==13)return;
    dispatch_block_t respond=^{reply([[MuesliServiceReservation alloc] initWithInstanceID:self.instance jobID:job processID:getpid()
        runtimeManifestSHA256:Hash(MUESLI_FIXTURE_MODE==1?3:1) modelManifestSHA256:Hash(2)],nil);
        if(MUESLI_FIXTURE_MODE==12)_exit(125);
    };
    if(MUESLI_FIXTURE_MODE>=14 && MUESLI_FIXTURE_MODE<=17)Later(9,respond);else respond();
}
- (void)runOperation:(MuesliInferenceOperation)operation instanceID:(NSUUID *)instance jobID:(NSUUID *)job
    sourceBookmark:(NSData *)bookmark sourceLease:(MuesliSourceLease *)lease liveSource:(MuesliLiveSource *)live
    streams:(MuesliInferenceStreams)streams requestDigest:(NSData *)digest input:(NSFileHandle *)input
    output:(NSFileHandle *)output diagnostics:(NSFileHandle *)diagnostics reply:(void (^)(MuesliOperationResult *))reply {
    (void)input;(void)diagnostics;
    NSData *expected=MuesliInferenceRequestDigest(operation,instance,job,bookmark,lease,live,streams);
    BOOL stale=NO;NSError *error=nil;
    NSURL *url=[NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
    if([job isEqual:_job] && [instance isEqual:_instance] && [digest isEqual:expected] && url && !stale)
        _source=[MuesliSourceAdmission admitURL:url lease:lease liveSource:live error:&error];
    if(!_source || MUESLI_FIXTURE_MODE==6) {
        Trace("rejected");
        reply([[MuesliOperationResult alloc] initWithInstanceID:instance jobID:job requestDigest:digest operationStatus:66 message:error.localizedDescription?:@"fixture rejected"]);
        Later(.2,^{_exit(125);});return;
    }
    Trace("source_pinned");
    id<MuesliInferenceClientV2> client=[_connection remoteObjectProxyWithErrorHandler:^(NSError *e){(void)e;}];
    dispatch_block_t accept=^{[client acceptedJob:job instanceID:(MUESLI_FIXTURE_MODE==2?[NSUUID UUID]:instance) requestDigest:digest];};
    dispatch_block_t finish=^{
        if(MUESLI_BACKEND_FIXTURE) {
            if(!ReadFixtureFrame(input)) {Trace("bad_frame");_exit(68);}
            Trace("frame_verified");
            // The UI consumer is deliberately stalled in the backend harness.
            for(unsigned i=0;i<MUESLI_BACKEND_EVENT_COUNT;i++) [output writeData:[[NSString stringWithFormat:@"{\"type\":\"fixture_result\",\"index\":%u}\n",i] dataUsingEncoding:NSUTF8StringEncoding]];
        } else [output writeData:[@"{\"type\":\"fixture_result\"}\n" dataUsingEncoding:NSUTF8StringEncoding]];
        reply([[MuesliOperationResult alloc] initWithInstanceID:instance jobID:job requestDigest:digest operationStatus:0 message:@"fixture complete"]);
        Trace("operation_replied");
    };
    if(MUESLI_FIXTURE_MODE==3) {finish();Later(.1,accept);}
    else if(MUESLI_FIXTURE_MODE==4) {finish();}
    else if(MUESLI_FIXTURE_MODE==8) { /* wait for original client's cancellation */ return; }
    else {accept();finish();}
    if(MUESLI_FIXTURE_MODE==7) {Later(.05,^{[self.connection invalidate];Trace("disconnected");});Later(1,^{Trace("exit_requested");_exit(125);});}
    else Later(.25,^{
        // This case specifically requires a signal outcome. An immediate
        // _exit after self-kill can win the race and correctly report exit125.
        Trace("exit_requested");
        if(MUESLI_FIXTURE_MODE==5) {kill(getpid(),SIGKILL);for(;;)pause();}
        _exit(125);
    });
}
- (void)cancelJob:(NSUUID *)job instanceID:(NSUUID *)instance reply:(void (^)(BOOL))reply {
    BOOL valid=[job isEqual:_job]&&[instance isEqual:_instance];reply(valid);
    if(valid) {Trace("cancel_received");Later(MUESLI_FIXTURE_MODE==8?.5:1.5,^{Trace("exit_requested");_exit(125);});}
}
- (void)policyProbeToPort:(NSNumber *)port reply:(void (^)(NSDictionary *))reply {(void)port;reply(@{});}
@end
int main(void) {@autoreleasepool {alarm(55);Fixture *fixture=[Fixture new];NSXPCListener *listener=[NSXPCListener serviceListener];listener.delegate=fixture;[listener resume];dispatch_main();}}
