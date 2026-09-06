#import <AppKit/AppKit.h>
#import "SourceAccessProtocol.h"
#import "../inference-service/InferenceProtocolV2.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#if defined(MUESLI_SOURCE_BROKER_FIXTURE)
// Only the explicitly compiled fixture binary accepts a proof host or fixture
// root. Packaging the application does not define this flag.
static NSString *const HostRequirement = @"anchor apple generic and certificate leaf[subject.OU] = \"JA9EPB8K4N\" and (identifier \"paidiaconsulting.MuesliApp\" or identifier \"paidiaconsulting.MuesliApp.SourceAccessLifetimeProof\")";
static NSString *ExpectedRootPath(void) {
    return @"/Users/david/muesli-current-inference-generated-4adc5e11ec8547418d50d6a268083401";
}
#else
static NSString *const HostRequirement = @"anchor apple generic and certificate leaf[subject.OU] = \"JA9EPB8K4N\" and identifier \"paidiaconsulting.MuesliApp\"";
static NSString *ExpectedRootPath(void) {
    // NSHomeDirectory() is the service container in an App Sandbox. The public
    // account database identifies the user's actual home without an input URL.
    struct passwd entry = {0}, *result = NULL;
    char buffer[16384];
    if (getpwuid_r(geteuid(), &entry, buffer, sizeof(buffer), &result) != 0 || !result || !entry.pw_dir) return nil;
    NSString *home = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:entry.pw_dir length:strlen(entry.pw_dir)];
    if (![home hasPrefix:@"/"]) return nil;
    return [home stringByAppendingPathComponent:@"Library/Application Support/Muesli/Meetings"];
}
#endif

static const NSUInteger MaximumBookmarkBytes = 1024 * 1024;
static const NSUInteger MaximumSessionJobs = 16384;

static BOOL Same(struct stat value, uint64_t device, uint64_t inode) {
    return (uint64_t)value.st_dev == device && (uint64_t)value.st_ino == inode;
}

static BOOL SafeDirectory(struct stat value) {
    return S_ISDIR(value.st_mode) && value.st_uid == geteuid();
}

static BOOL SafeLock(struct stat value) {
    return S_ISREG(value.st_mode) && value.st_uid == geteuid() && value.st_nlink == 1;
}

static BOOL ExactCanonicalPath(NSString *path) {
    if (!path || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= PATH_MAX
        || [path rangeOfString:@"\0"].location != NSNotFound) return NO;
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) != NULL
        && strcmp(resolved, path.fileSystemRepresentation) == 0;
}

static BOOL ValidChild(NSString *child) {
    NSUInteger bytes = [child lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return bytes > 0 && bytes <= NAME_MAX && ![child isEqualToString:@"."] && ![child isEqualToString:@".."]
        && [child rangeOfString:@"/"].location == NSNotFound && [child rangeOfString:@"\0"].location == NSNotFound;
}

@interface RootGrant : NSObject
@property(nonatomic, readonly) NSURL *selectedURL;
@property(nonatomic, readonly) NSString *path;
@property(nonatomic, readonly) uint64_t device;
@property(nonatomic, readonly) uint64_t inode;
@property(nonatomic, readonly) int descriptor;
- (instancetype)initWithURL:(NSURL *)url descriptor:(int)descriptor state:(struct stat)state;
- (BOOL)validate;
@end

@implementation RootGrant
- (instancetype)initWithURL:(NSURL *)url descriptor:(int)descriptor state:(struct stat)state {
    if ((self = [super init])) {
        _selectedURL = url;
        _path = [url.path copy];
        _device = (uint64_t)state.st_dev;
        _inode = state.st_ino;
        _descriptor = descriptor;
    }
    return self;
}
- (BOOL)validate {
    struct stat opened = {0}, named = {0};
    return ExactCanonicalPath(_path) && fstat(_descriptor, &opened) == 0 && lstat(_path.fileSystemRepresentation, &named) == 0
        && SafeDirectory(opened) && SafeDirectory(named) && Same(opened, _device, _inode) && Same(named, _device, _inode);
}
- (void)dealloc { if (_descriptor >= 0) close(_descriptor); }
@end

@interface ChildGrant : NSObject
@property(nonatomic, strong) RootGrant *root;
@property(nonatomic, strong) NSURL *childURL;
@property(nonatomic, copy) NSData *bookmark;
@property(nonatomic, copy) NSData *leaseRecord;
@property(nonatomic) int directory;
@property(nonatomic) int accessLock;
@property(nonatomic) int backendLock;
- (void)closeAdmissionDescriptors;
@end

@implementation ChildGrant
- (instancetype)init {
    if ((self = [super init])) _directory = _accessLock = _backendLock = -1;
    return self;
}
- (void)closeAdmissionDescriptors {
    if (_backendLock >= 0) { close(_backendLock); _backendLock = -1; }
    if (_accessLock >= 0) { close(_accessLock); _accessLock = -1; }
    if (_directory >= 0) { close(_directory); _directory = -1; }
}
- (void)dealloc { [self closeAdmissionDescriptors]; }
@end

static BOOL ValidateChild(ChildGrant *grant, NSString *child, MuesliSourceLease *lease) {
    struct stat opened = {0}, named = {0};
    if (![grant.root validate] || fstat(grant.directory, &opened) != 0
        || fstatat(grant.root.descriptor, child.fileSystemRepresentation, &named, AT_SYMLINK_NOFOLLOW) != 0
        || !SafeDirectory(opened) || !SafeDirectory(named)
        || !Same(opened, lease.directoryDevice, lease.directoryInode) || !Same(named, lease.directoryDevice, lease.directoryInode)) return NO;
    const char *names[] = {".meeting-access.lock", ".backend-owner.lock"};
    int descriptors[] = {grant.accessLock, grant.backendLock};
    uint64_t devices[] = {lease.accessDevice, lease.backendDevice};
    uint64_t inodes[] = {lease.accessInode, lease.backendInode};
    for (NSUInteger index = 0; index < 2; index++) {
        if (fstat(descriptors[index], &opened) != 0 || fstatat(grant.directory, names[index], &named, AT_SYMLINK_NOFOLLOW) != 0
            || !SafeLock(opened) || !SafeLock(named) || !Same(opened, devices[index], inodes[index])
            || !Same(named, devices[index], inodes[index])) return NO;
    }
    return YES;
}

static ChildGrant *CreateChildGrant(RootGrant *root, NSString *child, MuesliSourceLease *lease, NSString **failure) {
    if (!ValidChild(child) || !lease) {
        if (failure) *failure = @"The source child or immutable lease is invalid.";
        return nil;
    }
    ChildGrant *grant = [ChildGrant new];
    grant.root = root;
    grant.leaseRecord = [lease.record copy];
    if (![root validate]) {
        if (failure) *failure = @"The originally authorized Meetings folder changed.";
        return nil;
    }
    grant.directory = openat(root.descriptor, child.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (grant.directory < 0) {
        if (failure) *failure = @"The selected meeting is not an accessible direct directory child.";
        return nil;
    }
    grant.accessLock = openat(grant.directory, ".meeting-access.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    grant.backendLock = openat(grant.directory, ".backend-owner.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (!ValidateChild(grant, child, lease) || flock(grant.accessLock, LOCK_SH | LOCK_NB) != 0
        || flock(grant.backendLock, LOCK_SH | LOCK_NB) != 0 || !ValidateChild(grant, child, lease)) {
        if (failure) *failure = @"The original meeting directory or read-only ownership locks changed or are unavailable.";
        return nil;
    }
    // Derive from the original direct panel URL. A new path URL or incoming URL
    // is never used to mint this implicit child capability.
    grant.childURL = [root.selectedURL URLByAppendingPathComponent:child isDirectory:YES];
    if (![grant.childURL.path isEqualToString:[root.path stringByAppendingPathComponent:child]]) {
        if (failure) *failure = @"The selected meeting escaped its original library root.";
        return nil;
    }
    NSError *error = nil;
    grant.bookmark = [grant.childURL bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    if (!grant.bookmark || grant.bookmark.length == 0 || grant.bookmark.length > MaximumBookmarkBytes
        || !ValidateChild(grant, child, lease)) {
        if (failure) *failure = error.localizedDescription ?: @"The selected meeting changed or its bookmark exceeded the supported bound.";
        return nil;
    }
    // These pins guard only bookmark construction/validation. The main retains
    // its original pins continuously; the helper independently pins before any
    // imports. No third hidden lock owner may outlive helper exit and delay the
    // main app's file-closure/archive barrier while a retire RPC is queued.
    [grant closeAdmissionDescriptors];
    return grant;
}

@interface SourceAccessService : NSObject <MuesliSourceAccessService> {
    NSLock *_lock;
    NSXPCConnection *_connection;
    dispatch_queue_t _fileQueue;
    BOOL _authorizationRequested;
    BOOL _retiring;
    RootGrant *_root;
    NSMutableSet<NSUUID *> *_seenJobs;
    NSMutableDictionary<NSUUID *, ChildGrant *> *_jobs;
    // This AppKit object is accessed only on the main run loop.
    NSOpenPanel *_panel;
}
- (instancetype)initWithConnection:(NSXPCConnection *)connection;
- (void)retire;
@end

@implementation SourceAccessService
- (instancetype)initWithConnection:(NSXPCConnection *)connection {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _connection = connection;
        _fileQueue = dispatch_queue_create("muesli.source-access-files", DISPATCH_QUEUE_SERIAL);
        _seenJobs = [NSMutableSet new];
        _jobs = [NSMutableDictionary new];
        // There is no job-duration timer: a live recording can last 24 hours.
        // The original main connection owns this native session transaction.
        xpc_transaction_begin();
    }
    return self;
}

- (BOOL)callerIsOriginal {
    return NSXPCConnection.currentConnection == _connection;
}

- (void)retire {
    [_lock lock]; BOOL first = !_retiring; _retiring = YES; [_lock unlock];
    if (!first) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_panel cancel:nil];
        [self->_panel orderOut:nil];
        self->_panel = nil;
    });
    // No main-thread or file-operation responsiveness is required to end an
    // invalidated session. The OS closes this process's descriptors and grant.
    // This is not evidence that any inference process has terminated.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ _exit(0); });
}

- (void)authorizeRootPath:(NSString *)path directoryDevice:(uint64_t)device directoryInode:(uint64_t)inode
                   reply:(MuesliSourceAuthorizationReply)reply {
    BOOL caller = [self callerIsOriginal];
    NSString *expected = ExpectedRootPath();
    [_lock lock];
    BOOL accepted = caller && !_retiring && !_authorizationRequested && expected && [path isEqualToString:expected] && inode > 0;
    if (accepted) _authorizationRequested = YES;
    [_lock unlock];
    if (!accepted) {
        reply(NO, @"This session accepts one authorization of the application's original Meetings root.");
        return;
    }
    NSString *originalPath = [path copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_lock lock]; BOOL retired = self->_retiring; [self->_lock unlock];
        if (retired) { reply(NO, @"Source authorization was cancelled."); return; }
        NSOpenPanel *panel = NSOpenPanel.openPanel;
        self->_panel = panel;
        panel.title = @"Allow Muesli to read its meetings";
        panel.message = @"Select Muesli’s Meetings folder to enable local transcription for this app session.";
        panel.prompt = @"Allow reading";
        panel.canChooseDirectories = YES;
        panel.canChooseFiles = NO;
        panel.allowsMultipleSelection = NO;
        panel.canCreateDirectories = NO;
        panel.directoryURL = [NSURL fileURLWithPath:originalPath isDirectory:YES];
        [NSApplication.sharedApplication activate];
        NSModalResponse response = [panel runModal];
        self->_panel = nil;
        NSURL *selected = response == NSModalResponseOK ? panel.URL : nil;
        if (!selected.isFileURL || ![selected.path isEqualToString:originalPath]) {
            reply(NO, @"The original Meetings folder was not selected.");
            [self retire];
            return;
        }
        // File validation runs off the AppKit loop. The only authority here is
        // the actual URL returned by this service's own read-only open panel.
        dispatch_async(self->_fileQueue, ^{
            int descriptor = open(selected.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat opened = {0};
            RootGrant *grant = nil;
            if (descriptor >= 0 && fstat(descriptor, &opened) == 0 && SafeDirectory(opened) && Same(opened, device, inode)) {
                grant = [[RootGrant alloc] initWithURL:selected descriptor:descriptor state:opened];
                descriptor = -1;
                if (![grant validate]) grant = nil;
            }
            if (descriptor >= 0) close(descriptor);
            [self->_lock lock];
            BOOL committed = !self->_retiring && grant != nil && self->_root == nil;
            if (committed) self->_root = grant;
            [self->_lock unlock];
            reply(committed, committed ? nil : @"The selected Meetings folder does not match its original directory identity.");
            if (!committed) [self retire];
        });
    });
}

- (void)bookmarkChild:(NSString *)child jobID:(NSUUID *)jobID leaseRecord:(NSData *)leaseRecord reply:(MuesliSourceBookmarkReply)reply {
    BOOL caller = [self callerIsOriginal];
    MuesliSourceLease *lease = leaseRecord.length == 56 ? [[MuesliSourceLease alloc] initWithRecord:leaseRecord] : nil;
    [_lock lock];
    RootGrant *root = _root;
    BOOL accepted = caller && !_retiring && root && ValidChild(child) && jobID && lease
        && ![_seenJobs containsObject:jobID] && _seenJobs.count < MaximumSessionJobs;
    if (accepted) [_seenJobs addObject:[jobID copy]];
    // A placeholder owns this in-flight request. Retirement removes it before a
    // late native result can commit, independently of the file-operation queue.
    ChildGrant *placeholder = accepted ? [ChildGrant new] : nil;
    if (accepted) _jobs[jobID] = placeholder;
    [_lock unlock];
    if (!accepted) { reply(nil, @"The source session, job, child name or immutable lease is invalid."); return; }
    NSString *name = [child copy];
    NSUUID *identifier = [jobID copy];
    dispatch_async(_fileQueue, ^{
        NSString *failure = nil;
        ChildGrant *grant = CreateChildGrant(root, name, lease, &failure);
        [self->_lock lock];
        BOOL committed = grant && !self->_retiring && self->_jobs[identifier] == placeholder;
        if (committed) self->_jobs[identifier] = grant;
        else if (self->_jobs[identifier] == placeholder) [self->_jobs removeObjectForKey:identifier];
        [self->_lock unlock];
        reply(committed ? grant.bookmark : nil, committed ? nil : (failure ?: @"The original source request retired before its bookmark was ready."));
    });
}

- (void)retireJob:(NSUUID *)jobID reply:(MuesliSourceRetirementReply)reply {
    if (![self callerIsOriginal] || !jobID) { reply(NO); return; }
    [_lock lock];
    // Close an ID even if its acquire RPC has not arrived yet. This prevents a
    // terminal-before-reply race from recreating a retired source grant.
    BOOL recorded = [_seenJobs containsObject:jobID] || _seenJobs.count < MaximumSessionJobs;
    if (recorded) [_seenJobs addObject:[jobID copy]];
    __attribute__((objc_precise_lifetime)) ChildGrant *removed = _jobs[jobID];
    [_jobs removeObjectForKey:jobID];
    [_lock unlock];
    // Native descriptor destruction never runs while the state lock is held.
    (void)removed;
    reply(recorded);
}

- (void)endSessionWithReply:(MuesliSourceSessionEndReply)reply {
    if (![self callerIsOriginal]) return;
    reply();
    [self retire];
}
@end

@interface SourceListener : NSObject <NSXPCListenerDelegate> {
    NSLock *_lock;
    BOOL _acceptedConnection;
    SourceAccessService *_service;
}
@end

@implementation SourceListener
- (instancetype)init { if ((self = [super init])) _lock = [NSLock new]; return self; }
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    (void)listener;
    [_lock lock];
    BOOL accepted = !_acceptedConnection;
    if (accepted) _acceptedConnection = YES;
    [_lock unlock];
    if (!accepted) return NO;
    [connection setCodeSigningRequirement:HostRequirement];
    SourceAccessService *service = [[SourceAccessService alloc] initWithConnection:connection];
    _service = service;
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MuesliSourceAccessService)];
    connection.exportedObject = service;
    connection.invalidationHandler = ^{ [service retire]; };
    connection.interruptionHandler = ^{ [service retire]; };
    [connection activate];
    return YES;
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application finishLaunching];
        SourceListener *delegate = [SourceListener new];
        NSXPCListener *listener = NSXPCListener.serviceListener;
        listener.delegate = delegate;
        [listener resume];
    }
    return 0;
}
