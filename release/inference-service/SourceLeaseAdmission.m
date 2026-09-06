#import "SourceLeaseAdmission.h"
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const AdmissionDomain=@"MuesliSourceAdmission";
static BOOL Fail(NSError **error,NSString *message) {
    if(error)*error=[NSError errorWithDomain:AdmissionDomain code:66 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL Same(struct stat info,uint64_t device,uint64_t inode) { return (uint64_t)info.st_dev==device && info.st_ino==inode; }
static BOOL LockFile(struct stat info) { return S_ISREG(info.st_mode) && info.st_nlink==1 && info.st_uid==geteuid(); }
static BOOL Stable(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size
        && a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec
        && a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
@interface MuesliSourceAdmission () {
    int _directory, _access, _backend, _audio;
    struct stat _audioIdentity;
    MuesliSourceLease *_lease;
    NSString *_audioFolder;
}
@end
@implementation MuesliSourceAdmission
- (instancetype)init { if((self=[super init])) _directory=_access=_backend=_audio=-1; return self; }
- (void)dealloc {
    if(_audio>=0)close(_audio);if(_backend>=0)close(_backend);if(_access>=0)close(_access);if(_directory>=0)close(_directory);
}
+ (instancetype)admitURL:(NSURL *)url lease:(MuesliSourceLease *)lease liveSource:(MuesliLiveSource *)live error:(NSError **)error {
    if(!url.isFileURL || !url.path.isAbsolutePath || ![lease isKindOfClass:MuesliSourceLease.class] || lease.record.length!=56) {
        Fail(error,@"Invalid source admission.");return nil;
    }
    MuesliSourceAdmission *value=[self new];value->_sourceURL=[url copy];value->_lease=lease;
    value->_directory=open(url.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat state;
    if(value->_directory<0 || fstat(value->_directory,&state) || !S_ISDIR(state.st_mode) || !Same(state,lease.directoryDevice,lease.directoryInode)) {
        Fail(error,@"The original meeting directory changed before admission.");return nil;
    }
    const char *names[]={".meeting-access.lock",".backend-owner.lock"};
    uint64_t devices[]={lease.accessDevice,lease.backendDevice},inodes[]={lease.accessInode,lease.backendInode};
    int *slots[]={&value->_access,&value->_backend};
    for(int i=0;i<2;i++) {
        *slots[i]=openat(value->_directory,names[i],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(*slots[i]<0 || fstat(*slots[i],&state) || !LockFile(state) || !Same(state,devices[i],inodes[i]) || flock(*slots[i],LOCK_SH|LOCK_NB)) {
            Fail(error,@"The original meeting ownership is unavailable.");return nil;
        }
    }
    if(live) {
        if(![live isKindOfClass:MuesliLiveSource.class] || ![[MuesliLiveSource alloc] initWithAudioFolder:live.audioFolder sourceID:live.sourceID]) {
            Fail(error,@"Invalid live source selection.");return nil;
        }
        value->_audioFolder=[live.audioFolder copy];value->_liveSourceID=[live.sourceID.UUIDString copy];
        value->_audio=openat(value->_directory,live.audioFolder.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(value->_audio<0 || fstat(value->_audio,&value->_audioIdentity) || !S_ISDIR(value->_audioIdentity.st_mode)) {
            Fail(error,@"The selected live source directory is unavailable.");return nil;
        }
        value->_liveAudioPath=[[url.path stringByAppendingPathComponent:live.audioFolder] copy];
        if(![value validateManifest:error])return nil;
    }
    if(![value validate:error])return nil;
    NSDictionary *token=@{@"version":@1,@"folder":url.path,
        @"directory":@{@"device":@(lease.directoryDevice),@"inode":@(lease.directoryInode)},
        @"locks":@{@".meeting-access.lock":@{@"device":@(lease.accessDevice),@"inode":@(lease.accessInode)},
                   @".backend-owner.lock":@{@"device":@(lease.backendDevice),@"inode":@(lease.backendInode)}}};
    NSData *data=[NSJSONSerialization dataWithJSONObject:token options:NSJSONWritingSortedKeys error:error];
    if(!data || data.length>4096) {Fail(error,@"The source identity token exceeds its bound.");return nil;}
    value->_pythonLeaseToken=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return value;
}
- (BOOL)validateManifest:(NSError **)error {
    int file=openat(_audio,"source-recording.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(file<0)return Fail(error,@"The selected source manifest is unavailable.");
    struct stat before,after,named;
    BOOL valid=fstat(file,&before)==0 && LockFile(before) && before.st_size>0 && before.st_size<=4*1024*1024;
    NSMutableData *bytes=[NSMutableData data];char buffer[65536];
    while(valid) {
        ssize_t count=read(file,buffer,sizeof(buffer));
        if(count<0 && errno==EINTR)continue;
        if(count<0 || (uint64_t)bytes.length+(uint64_t)(count>0?count:0)>(uint64_t)before.st_size) {valid=NO;break;}
        if(count==0)break;
        [bytes appendBytes:buffer length:(NSUInteger)count];
    }
    valid=valid && bytes.length==(uint64_t)before.st_size && fstat(file,&after)==0 && Stable(before,after)
        && fstatat(_audio,"source-recording.json",&named,AT_SYMLINK_NOFOLLOW)==0 && Stable(after,named) && LockFile(named);
    close(file);
    if(!valid)return Fail(error,@"The source manifest changed or exceeded its bound.");
    id object=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if(![object isKindOfClass:NSDictionary.class] || ![object[@"session_id"] isKindOfClass:NSString.class]
        || ![object[@"session_id"] isEqual:_liveSourceID])return Fail(error,@"The selected live source UUID does not match its manifest.");
    return YES;
}
- (BOOL)validate:(NSError **)error {
    struct stat state;
    if(lstat(_sourceURL.fileSystemRepresentation,&state) || !S_ISDIR(state.st_mode) || !Same(state,_lease.directoryDevice,_lease.directoryInode))
        return Fail(error,@"The original meeting directory moved during admission.");
    const char *names[]={".meeting-access.lock",".backend-owner.lock"};
    uint64_t devices[]={_lease.accessDevice,_lease.backendDevice},inodes[]={_lease.accessInode,_lease.backendInode};
    for(int i=0;i<2;i++) {
        if(fstatat(_directory,names[i],&state,AT_SYMLINK_NOFOLLOW) || !LockFile(state) || !Same(state,devices[i],inodes[i]))
            return Fail(error,@"The original meeting ownership changed during admission.");
    }
    if(_audio>=0) {
        if(fstatat(_directory,_audioFolder.fileSystemRepresentation,&state,AT_SYMLINK_NOFOLLOW) || !S_ISDIR(state.st_mode)
            || state.st_dev!=_audioIdentity.st_dev || state.st_ino!=_audioIdentity.st_ino)
            return Fail(error,@"The selected live source directory changed during admission.");
        if(![self validateManifest:error])return NO;
    }
    return YES;
}
@end
