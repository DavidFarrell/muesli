#import "SourceOwnerEvidence.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

// Only the XPC metadata getter is substituted. PID birth reads, code identity,
// kqueue receipt, NOTE_EXIT/NOTE_EXITSTATUS and waitpid are real native calls.
@interface SourceEvidenceConnection : NSXPCConnection
@property(nonatomic) pid_t fixturePID;
@end
@implementation SourceEvidenceConnection
- (pid_t)processIdentifier { return self.fixturePID; }
@end

MuesliProcessTermination *MuesliSourceOwnerTestTermination(NSString *executable, NSError **error) {
    int gate[2]={-1,-1}; pid_t child=-1; int childStatus=0;
    if(pipe(gate)!=0)return nil;
    fcntl(gate[0],F_SETFD,FD_CLOEXEC);fcntl(gate[1],F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,gate[0],STDIN_FILENO);
    posix_spawnattr_t attributes; posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes,POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *const argv[]={(char*)executable.fileSystemRepresentation,NULL};
    char *const env[]={NULL};
    int spawned=posix_spawn(&child,executable.fileSystemRepresentation,&actions,&attributes,argv,env);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes);close(gate[0]);
    if(spawned){close(gate[1]);return nil;}
    SourceEvidenceConnection *connection=[SourceEvidenceConnection new];connection.fixturePID=child;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block MuesliProcessTermination *termination=nil;
    __block NSError *failure=nil;
    MuesliNativeProcessObserver *observer=[MuesliNativeProcessObserver armConnection:connection
        codeSigningRequirement:@"identifier \"com.paidiaconsulting.MuesliSourceOwnerExitFixture\"" timeout:2
        terminationHandler:^(MuesliProcessTermination *value){termination=value;dispatch_semaphore_signal(done);}
        failureHandler:^(NSError *value){failure=value;dispatch_semaphore_signal(done);} error:&failure];
    if(observer){char go='x';(void)write(gate[1],&go,1);}
    close(gate[1]);
    BOOL complete=observer && dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0;
    if(!complete && child>0)kill(child,SIGKILL);
    pid_t reaped; do{reaped=waitpid(child,&childStatus,0);}while(reaped<0&&errno==EINTR);
    if(!complete || !termination || reaped!=child || !WIFEXITED(childStatus) || WEXITSTATUS(childStatus)!=125){
        if(error)*error=failure?:[NSError errorWithDomain:@"SourceOwnerEvidence" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Actual generated child exit evidence was not obtained."}];
        return nil;
    }
    return termination;
}
