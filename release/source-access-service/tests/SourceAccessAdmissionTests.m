// Exercise actual production path/identity/lock code using private temporary
// fixtures. No app, XPC service, picker, model or source policy grant is launched.
#define main MuesliUnusedSourceAccessServiceMain
#import "../SourceAccessService.m"
#undef main

static NSMutableArray<NSDictionary *> *Results;
static void Check(NSString *name, BOOL passed) {
    [Results addObject:@{@"name":name,@"passed":@(passed)}];
}
static MuesliSourceLease *LeaseAt(NSString *path) {
    struct stat directory={0}, access={0}, backend={0};
    if (lstat(path.fileSystemRepresentation,&directory)
        || lstat([path stringByAppendingPathComponent:@".meeting-access.lock"].fileSystemRepresentation,&access)
        || lstat([path stringByAppendingPathComponent:@".backend-owner.lock"].fileSystemRepresentation,&backend)) return nil;
    return [[MuesliSourceLease alloc] initWithDirectoryDevice:(uint64_t)directory.st_dev directoryInode:directory.st_ino
        accessDevice:(uint64_t)access.st_dev accessInode:access.st_ino backendDevice:(uint64_t)backend.st_dev backendInode:backend.st_ino];
}
static void MakeMeeting(NSString *path) {
    NSCAssert(mkdir(path.fileSystemRepresentation,0700)==0,@"fixture mkdir");
    for(NSString *name in @[@".meeting-access.lock",@".backend-owner.lock"]) {
        int descriptor=open([path stringByAppendingPathComponent:name].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
        NSCAssert(descriptor>=0,@"fixture lock"); close(descriptor);
    }
}
static BOOL ExclusivePinAvailable(NSString *path) {
    int descriptor=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    BOOL allowed=descriptor>=0 && flock(descriptor,LOCK_EX|LOCK_NB)==0;
    if(descriptor>=0)close(descriptor);
    return allowed;
}
int main(void) {
    @autoreleasepool {
        Results=[NSMutableArray new];
        char template[]="/private/tmp/muesli-source-native-tests.XXXXXX";
        char *created=mkdtemp(template); NSCAssert(created,@"fixture root");
        NSString *base=[[NSFileManager defaultManager] stringWithFileSystemRepresentation:created length:strlen(created)];
        NSString *root=[base stringByAppendingPathComponent:@"root"];
        NSCAssert(mkdir(root.fileSystemRepresentation,0700)==0,@"selected root");
        NSString *meeting=[root stringByAppendingPathComponent:@"meeting"];
        NSString *outside=[base stringByAppendingPathComponent:@"outside"];
        MakeMeeting(meeting); MakeMeeting(outside);
        MuesliSourceLease *lease=LeaseAt(meeting), *outsideLease=LeaseAt(outside);
        int descriptor=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        struct stat initial={0}; NSCAssert(fstat(descriptor,&initial)==0,@"root snapshot");
        RootGrant *grant=[[RootGrant alloc] initWithURL:[NSURL fileURLWithPath:root isDirectory:YES] descriptor:descriptor state:initial];
        NSString *failure=nil;
        ChildGrant *child=CreateChildGrant(grant,@"meeting",lease,&failure);
        Check(@"Original direct child and original lock identities produce a bookmark",child.bookmark.length>0);
        Check(@"Admission closes both SH pins and child directory before handoff",child && child.directory==-1 && child.accessLock==-1 && child.backendLock==-1);
        Check(@"Retained bookmark has no hidden access pin",ExclusivePinAvailable([meeting stringByAppendingPathComponent:@".meeting-access.lock"]));
        Check(@"Retained bookmark has no hidden backend pin",ExclusivePinAvailable([meeting stringByAppendingPathComponent:@".backend-owner.lock"]));
        for(NSString *name in @[@"",@".",@"..",@"/outside",@"../outside",@"meeting/../outside",@"meeting/audio",@"bad\0tail"]) {
            Check([@"Reject unsafe child: " stringByAppendingString:[name stringByReplacingOccurrencesOfString:@"\0" withString:@"<NUL>"]],
                !ValidChild(name) && CreateChildGrant(grant,name,outsideLease,&failure)==nil);
        }
        NSString *alias=[root stringByAppendingPathComponent:@"alias"];
        NSCAssert(symlink("meeting",alias.fileSystemRepresentation)==0,@"child alias");
        Check(@"A symlink to the exact expected meeting inode is rejected",CreateChildGrant(grant,@"alias",lease,&failure)==nil);
        NSCAssert(unlink(alias.fileSystemRepresentation)==0,@"remove child alias");
        NSString *access=[meeting stringByAppendingPathComponent:@".meeting-access.lock"];
        NSString *real=[meeting stringByAppendingPathComponent:@".original-access.lock"];
        NSCAssert(rename(access.fileSystemRepresentation,real.fileSystemRepresentation)==0,@"rename lock");
        NSCAssert(symlink(".original-access.lock",access.fileSystemRepresentation)==0,@"lock symlink");
        Check(@"A symlink to the exact expected lock inode is rejected",CreateChildGrant(grant,@"meeting",lease,&failure)==nil);
        NSCAssert(unlink(access.fileSystemRepresentation)==0 && rename(real.fileSystemRepresentation,access.fileSystemRepresentation)==0,@"restore lock");
        NSCAssert(link(access.fileSystemRepresentation,real.fileSystemRepresentation)==0,@"hardlink lock");
        Check(@"A multiply linked ownership file is rejected",CreateChildGrant(grant,@"meeting",lease,&failure)==nil);
        NSCAssert(unlink(real.fileSystemRepresentation)==0,@"restore single link");
        MuesliSourceLease *wrong=[[MuesliSourceLease alloc] initWithDirectoryDevice:lease.directoryDevice directoryInode:lease.directoryInode
            accessDevice:lease.accessDevice accessInode:lease.accessInode+1 backendDevice:lease.backendDevice backendInode:lease.backendInode];
        Check(@"A changed original lock identity is rejected",CreateChildGrant(grant,@"meeting",wrong,&failure)==nil);
        int exclusive=open(access.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        NSCAssert(exclusive>=0 && flock(exclusive,LOCK_EX|LOCK_NB)==0,@"hold exclusive pin");
        Check(@"An active exclusive mutation blocks bookmark admission",CreateChildGrant(grant,@"meeting",lease,&failure)==nil);
        close(exclusive);
        Check(@"Failed validation leaves no hidden lock pin",ExclusivePinAvailable(access));
        NSString *oldRoot=[base stringByAppendingPathComponent:@"old-root"];
        NSCAssert(rename(root.fileSystemRepresentation,oldRoot.fileSystemRepresentation)==0 && mkdir(root.fileSystemRepresentation,0700)==0,@"replace root");
        Check(@"A replacement at the selected root pathname is rejected",![grant validate] && CreateChildGrant(grant,@"meeting",lease,&failure)==nil);
        BOOL passed=YES; for(NSDictionary *row in Results)passed=passed&&[row[@"passed"] boolValue];
        NSDictionary *report=@{@"passed":@(passed),@"checks":Results,@"fixture":base,
            @"scope":@"Actual native source admission, generated files only; no sandbox authority or UI qualification"};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');
        return passed?0:1;
    }
}
