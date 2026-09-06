#import <Foundation/Foundation.h>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 64;
        NSError *error = nil;
        NSData *bookmark = [[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES] bookmarkDataWithOptions:0
            includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
        if (!bookmark) return 66;
        puts([bookmark base64EncodedStringWithOptions:0].UTF8String);
        return 0;
    }
}
