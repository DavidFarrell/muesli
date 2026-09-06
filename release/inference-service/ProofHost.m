#import "InferenceProtocol.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <libproc.h>
#ifdef MUESLI_PICKER_HOST
#import <AppKit/AppKit.h>
#ifndef MUESLI_GENERATED_SOURCE
#error A diagnostic picker host must bind the exact generated source folder.
#endif
#ifndef MUESLI_GENERATED_CONTROL
#error A diagnostic picker host must bind the exact generated unselected control.
#endif
#endif

#ifndef MUESLI_SIGNING_TEAM
#error MUESLI_SIGNING_TEAM is required
#endif

static void PrintJSON(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    write(STDOUT_FILENO, data.bytes, data.length); write(STDOUT_FILENO, "\n", 1);
}

#ifdef MUESLI_PICKER_HOST
static NSDictionary *ReadGenerated(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), error = errno;
    char byte;
    ssize_t result = fd < 0 ? -1 : read(fd, &byte, 1);
    if (fd >= 0) { error = result < 0 ? errno : 0; close(fd); }
    return @{ @"result": @(result), @"errno": @(error) };
}
static NSURL *SelectGeneratedSource(NSString *requested) {
    if (![requested isEqual:@MUESLI_GENERATED_SOURCE]) return nil;
    NSString *sourceFile = [requested stringByAppendingPathComponent:@"audio/system.wav"];
    NSDictionary *before = ReadGenerated(sourceFile.fileSystemRepresentation);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO; panel.canChooseDirectories = YES; panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.directoryURL = [NSURL fileURLWithPath:requested isDirectory:YES];
    panel.title = @"Generated inference permission test";
    panel.message = @"Select only this generated test folder. No personal files are used.";
    panel.prompt = @"Select test folder";
    if ([panel runModal] != NSModalResponseOK) return nil;
    NSURL *url = panel.URL;
    if (![url.path isEqual:requested]) { [url stopAccessingSecurityScopedResource]; return nil; }
    PrintJSON(@{ @"picker_host": @{
        @"source_read_before_selection": before,
        @"source_read_after_selection": ReadGenerated(sourceFile.fileSystemRepresentation),
        @"unselected_control_read": ReadGenerated(MUESLI_GENERATED_CONTROL),
        @"selected_exact_generated_folder": @YES,
        @"wire_bookmark_options": @0 } });
    return url;
}
#endif

static NSDictionary *ReadPolicy(id<MuesliInferenceService> service) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *value;
    [service policyProbeToPort:@9 reply:^(NSDictionary *result) { value = result; dispatch_semaphore_signal(done); }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) return nil;
    return value;
}

static BOOL Cancel(id<MuesliInferenceService> service, NSUUID *job, BOOL expected) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL observed = !expected;
    [service cancelJob:job reply:^(BOOL accepted) { observed = accepted; dispatch_semaphore_signal(done); }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) return NO;
    return observed == expected;
}

static BOOL FillOutput(int descriptor) {
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)) return NO;
    char bytes[4096] = {0};
    ssize_t written;
    do { written = write(descriptor, bytes, sizeof(bytes)); } while (written > 0);
    BOOL full = written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);
    return fcntl(descriptor, F_SETFL, flags) == 0 && full;
}
static BOOL Identity(pid_t pid, NSString *path, struct proc_bsdinfo *identity) {
    char observed[PROC_PIDPATHINFO_MAXSIZE];
    return pid > 1 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, identity, sizeof(*identity)) == sizeof(*identity)
        && proc_pidpath(pid, observed, sizeof(observed)) > 0 && [@(observed) isEqual:path];
}
static BOOL OwnedProcessMatches(pid_t pid, NSString *path, struct proc_bsdinfo identity) {
    struct proc_bsdinfo current;
    return Identity(pid, path, &current) && current.pbi_start_tvsec == identity.pbi_start_tvsec
        && current.pbi_start_tvusec == identity.pbi_start_tvusec;
}
static pid_t HoldDecoder(pid_t service, NSString *path, struct proc_bsdinfo *identity) {
    for (int attempt = 0; attempt < 10000; attempt++) {
        pid_t children[32];
        // This convenience wrapper returns a PID count, unlike proc_listpids.
        int count = proc_listchildpids(service, children, sizeof(children));
        if (count > sizeof(children) / sizeof(children[0])) return 0;
        for (int i = 0; i < count; i++) {
            struct proc_bsdinfo candidate;
            if (!Identity(children[i], path, &candidate) || candidate.pbi_ppid != service || getpgid(children[i]) != service) continue;
            // Only the actual generated job's exact bundled decoder is held.
            // Recheck physical process identity immediately before signalling.
            if (!OwnedProcessMatches(children[i], path, candidate) || kill(children[i], SIGSTOP)) continue;
            *identity = candidate;
            return children[i];
        }
        usleep(1000);
    }
    return 0;
}

static int CheckOwnership(NSXPCConnection *connection, id<MuesliInferenceService> service, NSData *source, NSData *model, BOOL decoderMode) {
    int descriptors[2];
    if (pipe(descriptors)) return 2;
    BOOL outputFull = decoderMode ? NO : FillOutput(descriptors[1]);
    NSFileHandle *blockedOutput = [[NSFileHandle alloc] initWithFileDescriptor:descriptors[1] closeOnDealloc:YES];
    NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:@"/dev/null"];
    NSUUID *job = [NSUUID UUID];
    NSLock *resultLock = [NSLock new];
    __block BOOL returned = NO;
    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    connection.interruptionHandler = ^{ dispatch_semaphore_signal(exited); };
    [service runOperation:decoderMode ? @"reprocess" : @"preflight" jobID:job sourceBookmark:source modelBookmark:model
        input:input output:blockedOutput diagnostics:NSFileHandle.fileHandleWithStandardError reply:^(NSDictionary *result) {
            [resultLock lock]; returned = YES; [resultLock unlock];
        }];
    NSDictionary *initial = ReadPolicy(service);
    BOOL admitted = [initial[@"active_job"] isEqual:job.UUIDString];
    pid_t child = [initial[@"pid"] intValue];
    NSString *servicePath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc/Contents/MacOS/InferenceService"];
    NSString *decoderPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc/Contents/Resources/python/tools/ffmpeg"];
    struct proc_bsdinfo originalService = {0}, originalDecoder = {0};
    BOOL verifiedService = Identity(child, servicePath, &originalService) && getpgid(child) == child;
    pid_t decoder = decoderMode && verifiedService ? HoldDecoder(child, decoderPath, &originalDecoder) : 0;
    if (decoderMode) outputFull = FillOutput(descriptors[1]);
    NSXPCConnection *other = [[NSXPCConnection alloc] initWithServiceName:MuesliServiceID];
    other.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MuesliInferenceService)];
    [other setCodeSigningRequirement:@"anchor apple generic and certificate leaf[subject.OU] = \"" MUESLI_SIGNING_TEAM @"\" and identifier \"paidiaconsulting.MuesliApp.InferenceService\""];
    [other activate];
    id<MuesliInferenceService> peer = [other remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
    BOOL wrongConnectionRejected = Cancel(peer, job, NO);
    BOOL wrongJobRejected = Cancel(service, [NSUUID UUID], NO);
    [other invalidate];
    // Normal ownership mode blocks the helper's Python write. Decoder mode
    // separately holds the verified real decoder while output is full. Native
    // XPC and its cancellation deadline must remain responsive in both cases.
    usleep(250000);
    NSDictionary *still = ReadPolicy(service);
    [resultLock lock]; BOOL pending = !returned; [resultLock unlock];
    BOOL originalStillOwns = [still[@"active_job"] isEqual:job.UUIDString] && [still[@"pid"] intValue] == child;
    BOOL accepted = Cancel(service, job, YES);
    BOOL interrupted = dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    BOOL gone = NO;
    for (int attempt = 0; child > 1 && attempt < 100; attempt++) {
        if (kill(child, 0) == -1 && errno == ESRCH) { gone = YES; break; }
        usleep(10000);
    }
    BOOL decoderGone = !decoderMode;
    for (int attempt = 0; decoder > 1 && attempt < 500; attempt++) {
        if (!OwnedProcessMatches(decoder, decoderPath, originalDecoder)) { decoderGone = YES; break; }
        usleep(10000);
    }
    // Guaranteed cleanup on a failed diagnostic, without signalling any PID
    // whose executable/start identity differs from this generated job.
    BOOL forcedCleanup = NO;
    if (verifiedService && OwnedProcessMatches(child, servicePath, originalService) && getpgid(child) == child) {
        forcedCleanup = YES; kill(-child, SIGKILL);
    }
    if (decoder > 1 && OwnedProcessMatches(decoder, decoderPath, originalDecoder)) {
        forcedCleanup = YES; kill(decoder, SIGKILL);
    }
    close(descriptors[0]);
    BOOL passed = verifiedService && outputFull && decoderGone && !forcedCleanup && admitted && pending && wrongConnectionRejected && wrongJobRejected && originalStillOwns && accepted && interrupted && gone;
    PrintJSON(@{ @"passed": @(passed), @"admitted": @(admitted), @"blocked_operation_pending": @(pending),
        @"decoder_mode": @(decoderMode), @"decoder_pid": @(decoder), @"decoder_held": @(decoder > 1),
        @"original_decoder_exited": @(decoderGone), @"output_full": @(outputFull), @"forced_cleanup": @(forcedCleanup),
        @"wrong_connection_rejected": @(wrongConnectionRejected), @"wrong_job_rejected": @(wrongJobRejected),
        @"unrelated_invalidation_preserved_owner": @(originalStillOwns), @"cancel_accepted": @(accepted),
        @"transport_interrupted": @(interrupted), @"original_process_exited": @(gone) });
    return passed ? 0 : 1;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *operation = argc > 1 ? @(argv[1]) : @"policy";
#ifdef MUESLI_PICKER_HOST
        if (![@[@"preflight", @"reprocess"] containsObject:operation]) return 64;
#endif
        NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:MuesliServiceID];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MuesliInferenceService)];
        [connection setCodeSigningRequirement:@"anchor apple generic and certificate leaf[subject.OU] = \"" MUESLI_SIGNING_TEAM @"\" and identifier \"paidiaconsulting.MuesliApp.InferenceService\""];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int status = 1;
        id<MuesliInferenceService> service = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            PrintJSON(@{ @"transport_error": error.localizedDescription });
            dispatch_semaphore_signal(done);
        }];
        [connection activate];
        if ([operation isEqual:@"policy"]) {
            int listener = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET,
                .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
            if (listener < 0 || bind(listener, (void *)&address, sizeof(address)) != 0 || listen(listener, 2) != 0) return 2;
            socklen_t size = sizeof(address); getsockname(listener, (void *)&address, &size);
            // A real listening endpoint distinguishes sandbox denial from a
            // refused connection to an absent server.
            int positive = socket(AF_INET, SOCK_STREAM, 0);
            BOOL connects = connect(positive, (void *)&address, sizeof(address)) == 0;
            close(positive);
            [service policyProbeToPort:@(ntohs(address.sin_port)) reply:^(NSDictionary *result) {
                BOOL denied = connects;
                for (NSString *key in @[@"tcp4", @"udp4", @"tcp6", @"udp6"]) {
                    NSDictionary *attempt = result[key];
                    denied &= [attempt[@"result"] intValue] < 0 && [attempt[@"errno"] intValue] == EPERM;
                }
                PrintJSON(@{ @"positive_control_connected": @(connects), @"service": result, @"passed": @(denied) });
                status = denied ? 0 : 1; dispatch_semaphore_signal(done);
            }];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) status = 124;
            close(listener);
        } else {
            if (argc != 4) { fprintf(stderr, "Usage: InferenceProof preflight|live|reprocess source-path model-path\n"); return 64; }
            NSError *error = nil;
#ifdef MUESLI_PICKER_HOST
            // NSOpenPanel supplies the original read-only authority. The fresh
            // implicit bookmark transfers it; a persistent app-scoped bookmark
            // would not be the cross-identity wire representation.
            NSURL *sourceURL = SelectGeneratedSource(@(argv[2]));
            if (!sourceURL) return 66;
#else
            NSURL *sourceURL = [NSURL fileURLWithPath:@(argv[2])];
#endif
            NSData *source = [sourceURL bookmarkDataWithOptions:0
                includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            NSData *model = [[NSURL fileURLWithPath:@(argv[3])] bookmarkDataWithOptions:0
                includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            if (!source || !model) { PrintJSON(@{ @"bookmark_error": error.localizedDescription ?: @"unknown" }); return 66; }
            if ([operation isEqual:@"ownership"] || [operation isEqual:@"decoder-ownership"]) {
                int result = CheckOwnership(connection, service, source, model, [operation isEqual:@"decoder-ownership"]);
                [connection invalidate];
                return result;
            }
            NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:@"/dev/null"];
            [service runOperation:operation jobID:[NSUUID UUID] sourceBookmark:source modelBookmark:model
                input:input output:NSFileHandle.fileHandleWithStandardOutput diagnostics:NSFileHandle.fileHandleWithStandardError
                reply:^(NSDictionary *result) {
                    PrintJSON(@{ @"service_result": result }); status = [result[@"exit_status"] intValue]; dispatch_semaphore_signal(done);
                }];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 660 * NSEC_PER_SEC))) status = 124;
#ifdef MUESLI_PICKER_HOST
            [sourceURL stopAccessingSecurityScopedResource];
#endif
        }
        [connection invalidate];
        return status;
    }
}
