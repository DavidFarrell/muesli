#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

// CoreML Tools asks this exact compatibility question through the sealed PATH.
// Do not delegate to a shell, inspect caller environment, or accept other flags.
int main(int argc, const char **argv) {
    if (argc != 2 || strcmp(argv[1], "-productVersion") != 0) {
        fputs("Only -productVersion is supported.\n", stderr);
        return 64;
    }
    @autoreleasepool {
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion <= 0 || version.minorVersion < 0 || version.patchVersion < 0) return 70;
        if (version.patchVersion)
            printf("%ld.%ld.%ld\n", (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion);
        else
            printf("%ld.%ld\n", (long)version.majorVersion, (long)version.minorVersion);
    }
    return 0;
}
