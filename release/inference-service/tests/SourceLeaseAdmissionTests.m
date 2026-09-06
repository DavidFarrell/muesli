#import "../SourceLeaseAdmission.h"
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSURL *Fixture(void) {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"muesli-native-source-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSCAssert(mkdir(path.fileSystemRepresentation,0700)==0,@"fresh fixture");
    NSURL *url=[NSURL fileURLWithPath:path isDirectory:YES];
    for(NSString *name in @[@".meeting-access.lock",@".backend-owner.lock"]) {
        int fd=open([[url URLByAppendingPathComponent:name] fileSystemRepresentation],O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC,0400);NSCAssert(fd>=0,@"fixture lock");close(fd);
    }
    return url;
}
static MuesliSourceLease *Lease(NSURL *url) {
    struct stat root,access,backend;
    NSCAssert(lstat(url.fileSystemRepresentation,&root)==0,@"root identity");
    NSCAssert(lstat([url URLByAppendingPathComponent:@".meeting-access.lock"].fileSystemRepresentation,&access)==0,@"access identity");
    NSCAssert(lstat([url URLByAppendingPathComponent:@".backend-owner.lock"].fileSystemRepresentation,&backend)==0,@"backend identity");
    return [[MuesliSourceLease alloc] initWithDirectoryDevice:root.st_dev directoryInode:root.st_ino accessDevice:access.st_dev accessInode:access.st_ino backendDevice:backend.st_dev backendInode:backend.st_ino];
}
static void CheckExclusive(NSURL *url,NSString *name,BOOL expected) {
    int fd=open([url URLByAppendingPathComponent:name].fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);NSCAssert(fd>=0,@"independent open");
    int result=flock(fd,LOCK_EX|LOCK_NB);NSCAssert((result==0)==expected,@"actual exclusive admission");close(fd);
}
static void Manifest(NSURL *root,NSString *session) {
    NSURL *audio=[root URLByAppendingPathComponent:@"audio"];mkdir(audio.fileSystemRepresentation,0700);
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"session_id":session} options:0 error:nil];
    NSCAssert([data writeToURL:[audio URLByAppendingPathComponent:@"source-recording.json"] options:NSDataWritingAtomic error:nil],@"fixture manifest");
}
int main(void) {
    @autoreleasepool {
        NSURL *root=Fixture();MuesliSourceLease *lease=Lease(root);NSError *error=nil;
        @autoreleasepool {
            MuesliSourceAdmission *pin=[MuesliSourceAdmission admitURL:root lease:lease liveSource:nil error:&error];
            NSCAssert(pin && !error && [pin validate:&error],@"readonly native admission");
            NSDictionary *token=[NSJSONSerialization JSONObjectWithData:[pin.pythonLeaseToken dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            NSCAssert([token[@"folder"] isEqual:root.path] && [token[@"directory"][@"inode"] unsignedLongLongValue]==lease.directoryInode,@"derived fixed Python token");
            CheckExclusive(root,@".meeting-access.lock",NO);CheckExclusive(root,@".backend-owner.lock",NO);
        }
        CheckExclusive(root,@".meeting-access.lock",YES);CheckExclusive(root,@".backend-owner.lock",YES);
        int archive=open([root URLByAppendingPathComponent:@".meeting-access.lock"].fileSystemRepresentation,O_RDONLY|O_CLOEXEC);
        NSCAssert(archive>=0 && flock(archive,LOCK_EX|LOCK_NB)==0,@"archive wins");
        NSCAssert(![MuesliSourceAdmission admitURL:root lease:lease liveSource:nil error:&error],@"archive refuses child");close(archive);
        NSURL *foreign=Fixture();NSCAssert(![MuesliSourceAdmission admitURL:foreign lease:lease liveSource:nil error:&error],@"foreign root before import");
        NSURL *lock=[root URLByAppendingPathComponent:@".backend-owner.lock"],*old=[root URLByAppendingPathComponent:@"old-lock"];
        NSCAssert(rename(lock.fileSystemRepresentation,old.fileSystemRepresentation)==0,@"move fixture lock");
        NSCAssert(![MuesliSourceAdmission admitURL:root lease:lease liveSource:nil error:&error] && access(lock.fileSystemRepresentation,F_OK)!=0,@"missing lock never created");
        NSCAssert(symlink(old.fileSystemRepresentation,lock.fileSystemRepresentation)==0,@"symlink fixture");
        NSCAssert(![MuesliSourceAdmission admitURL:root lease:lease liveSource:nil error:&error],@"symlink rejected");unlink(lock.fileSystemRepresentation);
        NSCAssert(link(old.fileSystemRepresentation,lock.fileSystemRepresentation)==0,@"hardlink fixture");
        NSCAssert(![MuesliSourceAdmission admitURL:root lease:lease liveSource:nil error:&error],@"hardlink rejected");unlink(lock.fileSystemRepresentation);
        rename(old.fileSystemRepresentation,lock.fileSystemRepresentation);
        NSUUID *source=NSUUID.UUID;Manifest(root,source.UUIDString);
        MuesliLiveSource *live=[[MuesliLiveSource alloc] initWithAudioFolder:@"audio" sourceID:source];
        @autoreleasepool {
            MuesliSourceAdmission *pin=[MuesliSourceAdmission admitURL:root lease:lease liveSource:live error:&error];
            NSCAssert(pin && [pin.liveSourceID isEqual:source.UUIDString] && [pin.liveAudioPath isEqual:[root.path stringByAppendingPathComponent:@"audio"]],@"explicit live folder and UUID");
            Manifest(root,NSUUID.UUID.UUIDString);NSCAssert(![pin validate:&error],@"later source UUID changed");
            CheckExclusive(root,@".meeting-access.lock",NO);
        }
        NSCAssert(![MuesliSourceAdmission admitURL:root lease:lease liveSource:live error:&error],@"wrong source UUID before import");
        Manifest(root,source.UUIDString);
        @autoreleasepool {
            MuesliSourceAdmission *pin=[MuesliSourceAdmission admitURL:root lease:lease liveSource:live error:&error];NSCAssert(pin,@"fresh admission");
            NSURL *moved=[root URLByAppendingPathComponent:@"old-audio"];
            NSCAssert(rename([root URLByAppendingPathComponent:@"audio"].fileSystemRepresentation,moved.fileSystemRepresentation)==0,@"move audio directory");
            Manifest(root,source.UUIDString);NSCAssert(![pin validate:&error],@"same UUID replacement directory refused");
        }
        NSURL *manifest=[root URLByAppendingPathComponent:@"audio/source-recording.json"];
        NSCAssert([[NSMutableData dataWithLength:4*1024*1024+1] writeToURL:manifest options:NSDataWritingAtomic error:nil],@"oversize fixture");
        NSCAssert(![MuesliSourceAdmission admitURL:root lease:lease liveSource:live error:&error],@"bounded manifest");
        // Only this executable's freshly created fixtures are removed.
        NSCAssert([NSFileManager.defaultManager removeItemAtURL:root error:nil],@"fixture cleanup");
        NSCAssert([NSFileManager.defaultManager removeItemAtURL:foreign error:nil],@"fixture cleanup");
        puts("Native readonly source admission, lease exclusion, identity and live-manifest tests passed");
    }
}
