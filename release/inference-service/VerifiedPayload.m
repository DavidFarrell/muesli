#import "VerifiedPayload.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL Fail(NSError **error) {
    if (error) *error=[NSError errorWithDomain:@"MuesliPayload" code:65 userInfo:@{NSLocalizedDescriptionKey:@"The sealed runtime/model payload failed verification"}];
    return NO;
}
static NSString *Hex(const unsigned char *bytes) {
    NSMutableString *text=[NSMutableString stringWithCapacity:64];
    for (int i=0;i<32;i++) [text appendFormat:@"%02x",bytes[i]];
    return text;
}
static BOOL Relative(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || path.length>4096 || [path hasPrefix:@"/"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || [part rangeOfString:@"\0"].location!=NSNotFound) return NO;
    return YES;
}
static int Parent(int root,NSString *path) {
    if (!Relative(path)) return -1;
    int fd=dup(root); NSArray *parts=[path componentsSeparatedByString:@"/"];
    for (NSUInteger i=0;fd>=0 && i+1<parts.count;i++) {
        int next=openat(fd,[parts[i] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        close(fd);fd=next;
    }
    return fd;
}
static BOOL Same(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size
        && a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec
        && a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
static NSData *ReadManifest(int root,NSString *name) {
    int fd=openat(root,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return nil;
    struct stat before,after; NSMutableData *data=nil;
    if(!fstat(fd,&before) && S_ISREG(before.st_mode) && before.st_nlink==1 && before.st_size>0 && before.st_size<=8*1024*1024) {
        data=[NSMutableData dataWithLength:(NSUInteger)before.st_size]; NSUInteger count=0;
        while(count<data.length) { ssize_t n=read(fd,(char*)data.mutableBytes+count,data.length-count); if(n<=0)break;count+=(NSUInteger)n; }
        if(count!=data.length || fstat(fd,&after) || !Same(before,after)) data=nil;
    }
    close(fd);return data;
}
static BOOL VerifyEntry(int root,NSDictionary *entry,uint64_t *total) {
    if (![entry isKindOfClass:NSDictionary.class]) return NO;
    NSString *path=entry[@"path"],*kind=entry[@"kind"];int parent=Parent(root,path);
    if(parent<0)return NO;
    const char *name=path.lastPathComponent.fileSystemRepresentation;
    struct stat before,after;BOOL good=fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)==0;
    if(good && [kind isEqual:@"link"]) {
        char bytes[4097];ssize_t count=readlinkat(parent,name,bytes,4096);
        NSString *target=count>0 ? [[NSString alloc]initWithBytes:bytes length:(NSUInteger)count encoding:NSUTF8StringEncoding] : nil;
        good=S_ISLNK(before.st_mode) && [target isEqual:entry[@"target"]];
    } else if(good && [kind isEqual:@"directory"]) good=S_ISDIR(before.st_mode);
    else if(good && [kind isEqual:@"file"]) {
        NSNumber *size=entry[@"bytes"];NSString *expected=entry[@"sha256"];
        good=[size isKindOfClass:NSNumber.class] && size.doubleValue>=0 && size.doubleValue==size.unsignedLongLongValue
            && size.unsignedLongLongValue<=4ULL*1024*1024*1024 && [expected isKindOfClass:NSString.class] && expected.length==64
            && S_ISREG(before.st_mode) && before.st_nlink==1 && before.st_size==(off_t)size.unsignedLongLongValue;
        if(good) {
            *total+=size.unsignedLongLongValue;good=*total<=8ULL*1024*1024*1024;
            int fd=good ? openat(parent,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC) : -1;
            if(fd<0) good=NO;
            else {
                CC_SHA256_CTX hash;CC_SHA256_Init(&hash); char buffer[64*1024];uint64_t count=0;ssize_t n;
                while((n=read(fd,buffer,sizeof(buffer)))>0) {count+=(uint64_t)n;if(count>size.unsignedLongLongValue)break;CC_SHA256_Update(&hash,buffer,(CC_LONG)n);}
                unsigned char digest[32];CC_SHA256_Final(digest,&hash);
                good=n==0 && count==size.unsignedLongLongValue && !fstat(fd,&after) && Same(before,after) && [Hex(digest) isEqual:expected];
                close(fd);
            }
        }
    } else good=NO;
    good=good && !fstatat(parent,name,&after,AT_SYMLINK_NOFOLLOW) && Same(before,after);
    close(parent);return good;
}
@implementation MuesliVerifiedPayload
+ (instancetype)verifyBundle:(NSBundle *)bundle error:(NSError **)error {
    // Verify the actual service resource seal and nested executable signatures
    // before trusting manifest declarations. This is local preflight, not an
    // immutable file snapshot across later model execution.
    SecStaticCodeRef code=NULL;
    OSStatus status=SecStaticCodeCreateWithPath((__bridge CFURLRef)bundle.bundleURL,kSecCSDefaultFlags,&code);
    if(status==errSecSuccess) status=SecStaticCodeCheckValidity(code,kSecCSCheckAllArchitectures|kSecCSCheckNestedCode|kSecCSStrictValidate,NULL);
    if(code)CFRelease(code);
    if(status!=errSecSuccess){Fail(error);return nil;}
    int root=open(bundle.resourcePath.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root<0){Fail(error);return nil;}
    NSData *runtime=ReadManifest(root,@"runtime-manifest.json"),*models=ReadManifest(root,@"model-manifest.json");
    NSDictionary *r=runtime ? [NSJSONSerialization JSONObjectWithData:runtime options:0 error:nil] : nil;
    NSDictionary *m=models ? [NSJSONSerialization JSONObjectWithData:models options:0 error:nil] : nil;
    BOOL good=[r isKindOfClass:NSDictionary.class] && [m isKindOfClass:NSDictionary.class]
        && [r[@"schema_version"] isEqual:@1] && [m[@"schema_version"] isEqual:@1]
        && [r[@"kind"] isEqual:@"actual_runtime_files"] && [m[@"kind"] isEqual:@"validated_local_model_assets"]
        && [m[@"asr_directory"] isEqual:@"models/parakeet-tdt-0.6b-v3"]
        && [r[@"entries"] isKindOfClass:NSArray.class] && [m[@"entries"] isKindOfClass:NSArray.class]
        && [r[@"entries"] count]>0 && [r[@"entries"] count]<=25000 && [m[@"entries"] count]>=4 && [m[@"entries"] count]<=128;
    NSMutableSet *paths=[NSMutableSet set],*roles=[NSMutableSet set];uint64_t total=0;
    if(good) for(NSDictionary *entry in r[@"entries"]) {
        if(![entry isKindOfClass:NSDictionary.class]){good=NO;break;}
        NSString *path=entry[@"path"];
        if(![entry isKindOfClass:NSDictionary.class] || !Relative(path) || !([path isEqual:@"python"] || [path hasPrefix:@"python/"])
            || [paths containsObject:path] || !VerifyEntry(root,entry,&total)){good=NO;break;}
        [paths addObject:path];
    }
    if(good) {
        NSMutableSet *observed=[NSMutableSet setWithObject:@"python"];
        NSURL *url=[bundle.resourceURL URLByAppendingPathComponent:@"python"];
        NSDirectoryEnumerator *walker=[NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *unused,NSError *failure){return NO;}];
        if(!walker)good=NO;
        for(NSURL *file in walker) {
            NSString *path=[file.path substringFromIndex:bundle.resourcePath.length+1];
            if(observed.count>=25000 || ![paths containsObject:path]){good=NO;break;}[observed addObject:path];
        }
        good=good && [observed isEqual:paths];
    }
    if(good)for(NSDictionary *entry in m[@"entries"]) {
        if(![entry isKindOfClass:NSDictionary.class]){good=NO;break;}
        NSString *role=entry[@"role"],*path=entry[@"path"];
        if(![path isKindOfClass:NSString.class] || ![role isKindOfClass:NSString.class] || role.length>1024 || [roles containsObject:role]
            || !([path hasPrefix:@"models/parakeet-tdt-0.6b-v3/"] || [paths containsObject:path])
            || ![entry[@"kind"] isEqual:@"file"] || !VerifyEntry(root,entry,&total)){good=NO;break;}[roles addObject:role];
    }
    good=good && [roles containsObject:@"asr/config.json"] && [roles containsObject:@"asr/model.safetensors"];
    close(root);if(!good){Fail(error);return nil;}
    unsigned char rh[32],mh[32];CC_SHA256(runtime.bytes,(CC_LONG)runtime.length,rh);CC_SHA256(models.bytes,(CC_LONG)models.length,mh);
    MuesliVerifiedPayload *value=[self new];value->_runtimeManifestSHA256=[NSData dataWithBytes:rh length:32];
    value->_modelManifestSHA256=[NSData dataWithBytes:mh length:32];
    value->_runtimePath=[bundle.resourcePath stringByAppendingPathComponent:@"python"];
    value->_modelPath=[bundle.resourcePath stringByAppendingPathComponent:@"models/parakeet-tdt-0.6b-v3"];
    return value;
}
@end
