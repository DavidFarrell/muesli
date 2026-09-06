#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <sys/socket.h>
#include <unistd.h>
#ifndef MUESLI_PROBE_SOURCE_FILE
#error Compile with the exact generated external source file; never use client data.
#endif
#ifndef MUESLI_PROBE_CONTROL_FILE
#error Compile with a generated unbookmarked control file.
#endif

// Diagnostic replacement ONLY: this is not FFmpeg and never qualifies decode.
// It is signed with the real decoder's identifier, team and child entitlements.
static NSDictionary *Network(int family, int type) {
    int fd = socket(family, type, 0), result = -1;
    if (fd < 0) return @{ @"result": @(-1), @"errno": @(errno), @"stage": @"socket" };
    if (family == AF_INET) {
        struct sockaddr_in address = {.sin_len=sizeof(address), .sin_family=AF_INET,
            .sin_port=htons(9), .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        result = type == SOCK_DGRAM ? (int)sendto(fd, "p", 1, 0, (void *)&address, sizeof(address))
                                    : connect(fd, (void *)&address, sizeof(address));
    } else {
        struct sockaddr_in6 address = {.sin6_len=sizeof(address), .sin6_family=AF_INET6,
            .sin6_port=htons(9), .sin6_addr=IN6ADDR_LOOPBACK_INIT};
        result = type == SOCK_DGRAM ? (int)sendto(fd, "p", 1, 0, (void *)&address, sizeof(address))
                                    : connect(fd, (void *)&address, sizeof(address));
    }
    int error = result < 0 ? errno : 0;
    close(fd);
    return @{ @"result": @(result), @"errno": @(error), @"stage": @"operation" };
}
static NSDictionary *Read(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), error = errno;
    char byte;
    ssize_t result = fd < 0 ? -1 : read(fd, &byte, 1);
    if (fd >= 0) { error = result < 0 ? errno : 0; close(fd); }
    return @{ @"result": @(result), @"errno": @(error) };
}
static NSDictionary *Version(NSString *path, NSArray *arguments) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:path]; task.arguments = arguments;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe]; task.standardOutput = out; task.standardError = err;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) { dispatch_semaphore_signal(done); };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return @{ @"launch_error": error.localizedDescription ?: @"unknown" };
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) _exit(74);
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    if (data.length > 64) _exit(74);
    return @{ @"exit_status": @(task.terminationStatus),
        @"stdout": [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"invalid UTF-8" };
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "-version") == 0) { puts("diagnostic child, not FFmpeg"); return 0; }
        const char *input = NULL;
        for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "-i") == 0) input = argv[i + 1];
        if (!input) return 64;
        NSString *home = @(getenv("HOME") ?: ""), *temporary = @(getenv("TMPDIR") ?: "");
        if (!home.isAbsolutePath || ![temporary hasPrefix:[home stringByAppendingString:@"/"]]) return 74;
        char executable[PATH_MAX]; uint32_t size = sizeof(executable);
        if (_NSGetExecutablePath(executable, &size)) return 74;
        NSString *utility = [[@(executable) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"sw_vers"];
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        NSString *actual = version.patchVersion ? [NSString stringWithFormat:@"%ld.%ld.%ld\n", (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion]
                                               : [NSString stringWithFormat:@"%ld.%ld\n", (long)version.majorVersion, (long)version.minorVersion];
        NSDictionary *valid = Version(utility, @[@"-productVersion"]);
        NSDictionary *report = @{ @"diagnostic_replacement": @YES, @"pid": @(getpid()), @"parent": @(getppid()),
            @"process_group": @(getpgrp()), @"home": home, @"temporary": temporary,
            @"container_input": @(input), @"container_read": Read(input),
            @"external_generated_source_read": Read(MUESLI_PROBE_SOURCE_FILE),
            @"unbookmarked_generated_control_read": Read(MUESLI_PROBE_CONTROL_FILE),
            @"tcp4": Network(AF_INET, SOCK_STREAM), @"udp4": Network(AF_INET, SOCK_DGRAM),
            @"tcp6": Network(AF_INET6, SOCK_STREAM), @"udp6": Network(AF_INET6, SOCK_DGRAM),
            @"version": valid, @"version_matches_actual": @([valid[@"stdout"] isEqual:actual] && [valid[@"exit_status"] intValue] == 0),
            @"no_argument": Version(utility, @[]), @"wrong_argument": Version(utility, @[@"-buildVersion"]),
            @"extra_argument": Version(utility, @[@"-productVersion", @"extra"]) };
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
        NSString *path = [temporary stringByAppendingPathComponent:[NSString stringWithFormat:@"muesli-child-policy-%d.json", getppid()]];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return 74;
        ssize_t written = write(fd, data.bytes, data.length);
        BOOL saved = written == (ssize_t)data.length && fsync(fd) == 0;
        close(fd);
        // Return evidence through the existing captured decoder diagnostics;
        // the host need not acquire access to another application's container.
        if (saved) { write(STDERR_FILENO, data.bytes, data.length); write(STDERR_FILENO, "\n", 1); }
        // Deliberately fail conversion. This variant proves policy, not inference.
        return saved ? 65 : 74;
    }
}
