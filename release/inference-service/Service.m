#import "InferenceProtocol.h"
#import <Security/Security.h>
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef MUESLI_SIGNING_TEAM
#error MUESLI_SIGNING_TEAM must come from the actual signing certificate
#endif

int MuesliRunPython(NSString *, NSString *, NSString *, NSString *, int, int, int);

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

@interface InferenceService : NSObject <NSXPCListenerDelegate, MuesliInferenceService>
@property(nonatomic) NSLock *stateLock;
@property(nonatomic) NSUUID *activeJob;
@property(nonatomic) NSXPCConnection *activeConnection;
@property(nonatomic) BOOL everStarted;
@property(nonatomic) BOOL ownsProcessGroup;
@property(nonatomic) dispatch_queue_t deadlineQueue;
@end

@implementation InferenceService
- (instancetype)init {
    if ((self = [super init])) {
        _stateLock = [NSLock new];
        _deadlineQueue = dispatch_queue_create("muesli.inference.deadline", DISPATCH_QUEUE_SERIAL);
        if (getpgrp() != getpid()) setpgid(0, 0);
        _ownsProcessGroup = getpgrp() == getpid();
    }
    return self;
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    NSString *requirement = @"anchor apple generic and certificate leaf[subject.OU] = \"" MUESLI_SIGNING_TEAM @"\" and (identifier \"paidiaconsulting.MuesliApp.InferenceProof\" or identifier \"paidiaconsulting.MuesliApp\")";
    [connection setCodeSigningRequirement:requirement];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MuesliInferenceService)];
    connection.exportedObject = self;
    __weak InferenceService *weakSelf = self;
    __weak NSXPCConnection *weakConnection = connection;
    connection.invalidationHandler = ^{
        InferenceService *owner = weakSelf;
        [owner.stateLock lock];
        BOOL running = owner.activeJob != nil && owner.activeConnection == weakConnection;
        [owner.stateLock unlock];
        if (running) [owner terminateOwnedProcess];
    };
    [connection activate];
    return YES;
}
- (void)terminateOwnedProcess {
    // No caller can release an operation on a timeout. The service and its
    // children actually exit; the client must observe invalidation/EOF.
    if (self.ownsProcessGroup && getpgrp() == getpid()) kill(-getpid(), SIGKILL);
    _exit(125);
}
- (void)policyProbeToPort:(NSNumber *)port reply:(void (^)(NSDictionary *))reply {
    unsigned int value = port.unsignedIntValue;
    if (value == 0 || value > 65535) { reply(@{ @"error": @"invalid probe port" }); return; }
    [self.stateLock lock]; NSString *active = self.activeJob.UUIDString ?: @""; [self.stateLock unlock];
    reply(@{ @"pid": @(getpid()), @"owns_process_group": @(self.ownsProcessGroup), @"active_job": active,
        @"tcp4": NetworkAttempt(AF_INET, SOCK_STREAM, value),
        @"udp4": NetworkAttempt(AF_INET, SOCK_DGRAM, value),
        @"tcp6": NetworkAttempt(AF_INET6, SOCK_STREAM, value),
        @"udp6": NetworkAttempt(AF_INET6, SOCK_DGRAM, value),
        @"home": NSHomeDirectory(), @"temporary": NSTemporaryDirectory() });
}
- (void)cancelJob:(NSUUID *)jobID reply:(void (^)(BOOL))reply {
    [self.stateLock lock];
    BOOL matches = [self.activeJob isEqual:jobID] && self.activeConnection == NSXPCConnection.currentConnection;
    [self.stateLock unlock];
    reply(matches);
    if (matches) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), self.deadlineQueue, ^{
        [self terminateOwnedProcess];
    });
}
- (NSURL *)resolve:(NSData *)bookmark error:(NSError **)error {
    if (bookmark.length == 0 || bookmark.length > 65536) return nil;
    BOOL stale = NO;
    // The host sends a fresh implicit-scope bookmark for this connection.
    // Persistent app-scoped bookmarks cannot cross application identities.
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
        options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting
        relativeToURL:nil bookmarkDataIsStale:&stale error:error];
    if (!url.isFileURL || stale) {
        [url stopAccessingSecurityScopedResource];
        if (error && !*error) *error = [NSError errorWithDomain:@"MuesliInference" code:66
            userInfo:@{NSLocalizedDescriptionKey: @"Bookmark is stale or is not a file URL"}];
        return nil;
    }
    // Resolving an implicit bookmark already begins access; exactly one stop
    // follows actual operation completion, never a caller's deadline.
    return url;
}
- (void)runOperation:(NSString *)operation jobID:(NSUUID *)jobID sourceBookmark:(NSData *)sourceBookmark
      modelBookmark:(NSData *)modelBookmark input:(NSFileHandle *)input output:(NSFileHandle *)output
        diagnostics:(NSFileHandle *)diagnostics reply:(void (^)(NSDictionary *))reply {
    if (![@[@"preflight", @"live", @"reprocess"] containsObject:operation] || !jobID || !self.ownsProcessGroup
        || !input || !output || !diagnostics || sourceBookmark.length == 0 || sourceBookmark.length > 65536
        || modelBookmark.length == 0 || modelBookmark.length > 65536) {
        reply(@{ @"error": @"invalid operation or unavailable process ownership", @"exit_status": @64 }); return;
    }
    [self.stateLock lock];
    BOOL busy = self.everStarted;
    if (!busy) { self.everStarted = YES; self.activeJob = jobID; self.activeConnection = NSXPCConnection.currentConnection; }
    [self.stateLock unlock];
    if (busy) { reply(@{ @"error": @"one job is admitted per service lifetime", @"exit_status": @75 }); return; }
    double seconds = [operation isEqual:@"preflight"] ? 60 : [operation isEqual:@"reprocess"] ? 600 : 86400;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), self.deadlineQueue, ^{
        [self terminateOwnedProcess];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSURL *source = [self resolve:sourceBookmark error:&error];
            NSURL *model = [self resolve:modelBookmark error:&error];
            int result = 66;
            if (source && model) {
                NSString *runtime = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"python"];
                result = MuesliRunPython(runtime, operation, source.path, model.path,
                                        input.fileDescriptor, output.fileDescriptor, diagnostics.fileDescriptor);
            }
            [source stopAccessingSecurityScopedResource];
            [model stopAccessingSecurityScopedResource];
            [self.stateLock lock]; self.activeJob = nil; self.activeConnection = nil; [self.stateLock unlock];
            reply(@{ @"job_id": jobID.UUIDString, @"exit_status": @(result),
                     @"error": error.localizedDescription ?: @"" });
            // Python and native model globals are never reused or finalized
            // under another request. Exit the whole original owner instead.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), self.deadlineQueue, ^{
                [self terminateOwnedProcess];
            });
        }
    });
}
@end

int main(void) {
    @autoreleasepool {
        InferenceService *service = [InferenceService new];
        NSXPCListener *listener = NSXPCListener.serviceListener;
        listener.delegate = service;
        [listener activate];
    }
    return 0;
}
