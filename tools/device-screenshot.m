#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
int main(int argc,char **argv) {
    @autoreleasepool {
        CGImageRef (*capture)(void) = dlsym(RTLD_DEFAULT,"UIGetScreenImage");
        if (!capture) { fprintf(stderr,"UIGetScreenImage unavailable\n"); return 1; }
        CGImageRef screen = capture();
        if (!screen) { fprintf(stderr,"Screen capture returned nil\n"); return 2; }
        NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:screen]);
        NSString *path = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"/var/mobile/Media/OpenDisplay-screen.png";
        BOOL ok = [png writeToFile:path atomically:YES];
        printf("%zux%zu: %s\n",CGImageGetWidth(screen),CGImageGetHeight(screen),ok ? "saved" : "failed");
        CGImageRelease(screen); return ok ? 0 : 3;
    }
}
