#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

// Generated-fixture test harness only. This is never embedded in the service.
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 5) return 64;
        BOOL stale = NO;
        NSData *data = [[NSData alloc] initWithBase64EncodedString:@(argv[4]) options:0];
        NSURL *source = [NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting
            relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
        if (stale || ![source.path isEqual:@(argv[1])]) return 66;
        int directory = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directory < 0) return 66;
        for (const char **name = (const char *[]){".meeting-access.lock", ".backend-owner.lock", NULL}; *name; name++) {
            int fd = openat(directory, *name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (fd < 0 || flock(fd, LOCK_SH | LOCK_NB)) return 75;
            // Deliberately retained until actual native-parent process exit.
        }
        NSString *resources = NSBundle.mainBundle.resourcePath;
        NSTask *child = [NSTask new];
        child.executableURL = [NSURL fileURLWithPath:[resources stringByAppendingPathComponent:@"python/bin/python3.12"]];
        child.arguments = @[@"-I", @"-S", @"-B", [resources stringByAppendingPathComponent:@"lease_probe.py"], @(argv[3])];
        child.environment = @{ @"HOME": NSHomeDirectory(), @"TMPDIR": NSTemporaryDirectory(),
            @"MUESLI_MEETING_LEASE": @(argv[2]), @"MUESLI_ALLOW_MODEL_DOWNLOADS": @"0" };
        child.standardOutput = NSFileHandle.fileHandleWithStandardOutput;
        child.standardError = NSFileHandle.fileHandleWithStandardError;
        NSError *error = nil;
        if (![child launchAndReturnError:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 70; }
        printf("{\"parent\":%d,\"child\":%d}\n", getpid(), child.processIdentifier); fflush(stdout);
        // Driver kills this exact parent only after observing independent child pins.
        while (true) sleep(1);
    }
}
