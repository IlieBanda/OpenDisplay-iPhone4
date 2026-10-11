#import <GLKit/GLKit.h>
#import <CoreVideo/CoreVideo.h>
@interface ODVideoView : GLKView <GLKViewDelegate>
@property(nonatomic, copy) void (^onFirstImage)(void);
@property(nonatomic, copy) void (^onTouch)(NSString *, double, double);
@property(nonatomic, copy) void (^onScroll)(double, double);
@property(atomic, readonly) NSUInteger presentedFrames;
- (void)offerImage:(CVPixelBufferRef)image;
- (void)offerCursor:(NSDictionary *)message;
- (void)clear;
- (void)shutdown;
- (void)pause;
- (void)resume;
@end
