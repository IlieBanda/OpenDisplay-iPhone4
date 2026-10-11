#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
@interface ODLegacyDecoder : NSObject
@property(nonatomic, copy) void (^onImage)(CVPixelBufferRef image);
@property(nonatomic, readonly) NSString *diagnostics;
@property(nonatomic, readonly) NSUInteger decodedFrames;
@property(nonatomic, readonly) double lastDecodeMs;
- (BOOL)open;
- (BOOL)decode:(const uint8_t *)bytes length:(size_t)length;
- (void)reset;
@end
