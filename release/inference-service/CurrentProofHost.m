#import "InferenceProtocolV2.h"
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <libproc.h>
#include <unistd.h>
#ifdef MUESLI_GENERATED_SOURCE
#import <AppKit/AppKit.h>
#endif
#ifndef MUESLI_SIGNING_TEAM
#error Actual Team ID is required
#endif
static void Print(id value){NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];write(STDOUT_FILENO,data.bytes,data.length);write(STDOUT_FILENO,"\n",1);}
static NSString *Hex(NSData *data){NSMutableString *value=[NSMutableString string];const unsigned char *p=data.bytes;for(NSUInteger i=0;i<data.length;i++)[value appendFormat:@"%02x",p[i]];return value;}
@interface ProofClientV2 : NSObject <MuesliInferenceClientV2>
@property NSUUID *job;
@property NSUUID *instance;
@property NSData *digest;
@property NSLock *lock;
@property BOOL accepted;
@end
@implementation ProofClientV2
- (void)acceptedJob:(NSUUID *)job instanceID:(NSUUID *)instance requestDigest:(NSData *)digest {
    [self.lock lock];self.accepted=[job isEqual:self.job] && [instance isEqual:self.instance] && [digest isEqual:self.digest];[self.lock unlock];
    Print(@{@"accepted":@(self.accepted),@"job_id":job.UUIDString,@"instance_id":instance.UUIDString,@"request_digest":Hex(digest)});
}
@end
int main(int argc,const char **argv){@autoreleasepool{
    if(argc<3 || argc>6)return 64;
    NSString *mode=@(argv[1]),*sourceName=@(argv[2]);
#ifdef MUESLI_GENERATED_SOURCE
    NSURL *selectedGrant=nil;
    if([mode isEqual:@"picker-preflight"] || [mode isEqual:@"picker-reprocess"]){
        if(![sourceName isEqual:@MUESLI_GENERATED_SOURCE])return 64;
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp activateIgnoringOtherApps:YES];
        NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=NO;panel.canChooseDirectories=YES;
        panel.allowsMultipleSelection=NO;panel.canCreateDirectories=NO;
        panel.directoryURL=[NSURL fileURLWithPath:@MUESLI_GENERATED_SOURCE isDirectory:YES];
        panel.title=@"Generated current-backend permission test";panel.prompt=@"Select test folder";
        panel.message=@"Select only the generated admitted test folder. No personal recordings are used.";
        if([panel runModal]!=NSModalResponseOK)return 64;
        selectedGrant=panel.URL;if(![selectedGrant.path isEqual:@MUESLI_GENERATED_SOURCE])return 64;
        Print(@{@"picker_selected_exact_generated_folder":@YES,@"host_sandboxed":@NO,@"bookmark_options":@0});
        mode=[mode isEqual:@"picker-preflight"]?@"preflight":@"reprocess";
    }
#endif
    if(![@[@"preflight",@"reprocess",@"live",@"policy",@"cancel-before-run"] containsObject:mode])return 64;
    NSXPCConnection *connection=[[NSXPCConnection alloc]initWithServiceName:@"paidiaconsulting.MuesliApp.InferenceService"];
    [connection setCodeSigningRequirement:@"anchor apple generic and certificate leaf[subject.OU] = \"" MUESLI_SIGNING_TEAM @"\" and identifier \"paidiaconsulting.MuesliApp.InferenceService\""];
    connection.remoteObjectInterface=MuesliServiceInterfaceV2();connection.exportedInterface=MuesliClientInterfaceV2();
    ProofClientV2 *client=[ProofClientV2 new];client.lock=[NSLock new];connection.exportedObject=client;
    [connection activate];
    id<MuesliInferenceServiceV2> service=[connection remoteObjectProxyWithErrorHandler:^(NSError *error){Print(@{@"transport_error":error.localizedDescription});}];
    if([mode isEqual:@"policy"]){
        int server=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        socklen_t size=sizeof(address);if(server<0 || bind(server,(void*)&address,size) || listen(server,1) || getsockname(server,(void*)&address,&size))return 2;
        int positive=socket(AF_INET,SOCK_STREAM,0);BOOL host=positive>=0 && connect(positive,(void*)&address,size)==0;
        __block NSDictionary *policy=nil;dispatch_semaphore_t done=dispatch_semaphore_create(0);
        [service policyProbeToPort:@(ntohs(address.sin_port)) reply:^(NSDictionary *value){policy=value;dispatch_semaphore_signal(done);}];
        if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)))return 2;
        Print(@{@"host_tcp_positive":@(host),@"policy":policy?:@{}});close(positive);close(server);
        BOOL good=host;for(NSString *key in @[@"tcp4",@"tcp6",@"udp4",@"udp6"])good=good && [policy[key][@"result"] intValue]==-1 && [policy[key][@"errno"] intValue]==EPERM;
        [connection invalidate];return good?0:2;
    }
    NSUUID *job=[NSUUID UUID];__block MuesliServiceReservation *reservation=nil;
    dispatch_semaphore_t reserved=dispatch_semaphore_create(0);
    [service reserveJob:job reply:^(MuesliServiceReservation *value,NSString *failure){reservation=value;if(failure)Print(@{@"reserve_error":failure});dispatch_semaphore_signal(reserved);}];
    if(dispatch_semaphore_wait(reserved,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC)) || !reservation)return 2;
    pid_t pid=connection.processIdentifier;struct proc_bsdinfo before,after;
    BOOL identity=pid==reservation.processID && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&before,sizeof(before))==sizeof(before);
    int monitor=kqueue();struct kevent registration,event;
    EV_SET(&registration,(uintptr_t)pid,EVFILT_PROC,EV_ADD|EV_ONESHOT|EV_RECEIPT,NOTE_EXIT|NOTE_EXITSTATUS,0,NULL);
    struct timespec immediate={0};int registered=kevent(monitor,&registration,1,&event,1,&immediate);
    identity=identity && registered==1 && (event.flags&EV_ERROR) && event.data==0
        && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,sizeof(after))==sizeof(after)
        && before.pbi_start_tvsec==after.pbi_start_tvsec && before.pbi_start_tvusec==after.pbi_start_tvusec;
    Print(@{@"reserved":@YES,@"pid":@(pid),@"instance_id":reservation.instanceID.UUIDString,
        @"runtime_manifest_sha256":Hex(reservation.runtimeManifestSHA256),@"model_manifest_sha256":Hex(reservation.modelManifestSHA256),@"kernel_watch_armed":@(identity)});
    if(!identity){[connection invalidate];return 2;}
    NSURL *url=[NSURL fileURLWithPath:sourceName isDirectory:YES];
#ifdef MUESLI_GENERATED_SOURCE
    if(selectedGrant)url=selectedGrant;
#endif
    NSError *error=nil;
    NSData *bookmark=[url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    struct stat directory,access,backend;
    if(!bookmark || lstat(sourceName.fileSystemRepresentation,&directory)
        || lstat([[sourceName stringByAppendingPathComponent:@".meeting-access.lock"] fileSystemRepresentation],&access)
        || lstat([[sourceName stringByAppendingPathComponent:@".backend-owner.lock"] fileSystemRepresentation],&backend)){[connection invalidate];return 66;}
    MuesliSourceLease *lease=[[MuesliSourceLease alloc]initWithDirectoryDevice:directory.st_dev directoryInode:directory.st_ino
        accessDevice:access.st_dev accessInode:access.st_ino backendDevice:backend.st_dev backendInode:backend.st_ino];
    MuesliLiveSource *live=nil;MuesliInferenceOperation operation=[mode isEqual:@"live"]?MuesliInferenceOperationLive:[mode isEqual:@"reprocess"]?MuesliInferenceOperationReprocess:MuesliInferenceOperationPreflight;
    if(operation==MuesliInferenceOperationLive){if(argc!=6)return 64;live=[[MuesliLiveSource alloc]initWithAudioFolder:@(argv[3]) sourceID:[[NSUUID alloc]initWithUUIDString:@(argv[4])]];if(!live)return 64;}
    NSData *digest=MuesliInferenceRequestDigest(operation,reservation.instanceID,job,bookmark,lease,live,MuesliInferenceStreamsBoth);
    client.job=job;client.instance=reservation.instanceID;client.digest=digest;
    NSFileHandle *input=[NSFileHandle fileHandleForReadingAtPath:argc==6?@(argv[5]):@"/dev/null"];
    if(!input){[connection invalidate];return 66;}
    BOOL cancelFirst=[mode isEqual:@"cancel-before-run"];
    if(cancelFirst){
        __block BOOL acknowledged=NO;dispatch_semaphore_t cancellation=dispatch_semaphore_create(0);
        [service cancelJob:job instanceID:reservation.instanceID reply:^(BOOL value){acknowledged=value;dispatch_semaphore_signal(cancellation);}];
        if(dispatch_semaphore_wait(cancellation,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) || !acknowledged)return 2;
    }
    __block MuesliOperationResult *result=nil;dispatch_semaphore_t terminal=dispatch_semaphore_create(0);
    [service runOperation:operation instanceID:reservation.instanceID jobID:job sourceBookmark:bookmark sourceLease:lease liveSource:live
        streams:MuesliInferenceStreamsBoth requestDigest:digest input:input output:NSFileHandle.fileHandleWithStandardOutput diagnostics:NSFileHandle.fileHandleWithStandardError
        reply:^(MuesliOperationResult *value){result=value;dispatch_semaphore_signal(terminal);}];
    BOOL completed=dispatch_semaphore_wait(terminal,dispatch_time(DISPATCH_TIME_NOW,3600*NSEC_PER_SEC))==0;
    if(!completed){[service cancelJob:job instanceID:reservation.instanceID reply:^(BOOL accepted){}];}
    __block NSDictionary *afterCancel=nil;
    if(cancelFirst){dispatch_semaphore_t policy=dispatch_semaphore_create(0);
        [service policyProbeToPort:@9 reply:^(NSDictionary *value){afterCancel=value;dispatch_semaphore_signal(policy);}];
        dispatch_semaphore_wait(policy,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
        Print(@{@"cancel_before_run_policy":afterCancel?:@{}});
    }
    struct timespec timeout={10,0};int observed=kevent(monitor,NULL,0,&event,1,&timeout);
    BOOL exited=observed==1 && event.filter==EVFILT_PROC && (event.fflags&NOTE_EXIT) && (event.fflags&NOTE_EXITSTATUS);
    [client.lock lock];BOOL accepted=client.accepted;[client.lock unlock];
    BOOL bound=result && [result.jobID isEqual:job] && [result.instanceID isEqual:reservation.instanceID] && [result.requestDigest isEqual:digest];
    Print(@{@"operation_status":result?@(result.operationStatus):@(-1),@"result_bound":@(bound),@"accepted_observed":@(accepted),
        @"kernel_exit_observed":@(exited),@"kernel_wait_status":@(exited?event.data:-1)});
    close(monitor);[connection invalidate];BOOL outcome=cancelFirst ? (!accepted && result.operationStatus==64 && afterCancel
        && [afterCancel[@"source_attempts"] unsignedIntegerValue]==0 && [afterCancel[@"python_entries"] unsignedIntegerValue]==0)
        : (accepted && result.operationStatus==0);
    return completed && bound && outcome && exited?0:2;
}}
