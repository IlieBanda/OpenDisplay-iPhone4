#import "ODLog.h"
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
NSString *ODLogPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"OpenDisplay-iPhone4.log"];
}
void ODLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    NSLog(@"[OD4] %@", message);
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    const char *path = [ODLogPath() fileSystemRepresentation];
    struct stat st;
    if (!stat(path, &st) && st.st_size > 1024*1024) {
        NSString *old = [ODLogPath() stringByAppendingString:@".previous"];
        rename(path, [old fileSystemRepresentation]);
    }
    FILE *file = fopen(path, "a");
    if (file) { fprintf(file, "%s %s\n", [[[NSDate date] description] UTF8String], [message UTF8String]); fclose(file); }
    pthread_mutex_unlock(&lock);
}
