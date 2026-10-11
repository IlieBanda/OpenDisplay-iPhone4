#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
@interface ODReceiver : NSObject <NSNetServiceDelegate>
@property(nonatomic, copy) void (^onImage)(CVPixelBufferRef);
@property(nonatomic, copy) void (^onStatus)(NSString *);
@property(nonatomic, copy) void (^onStats)(NSString *);
@property(nonatomic, copy) void (^onCursor)(NSDictionary *);
@property(nonatomic, copy) NSUInteger (^presentedFrames)(void);
@property(nonatomic, readonly) BOOL running;
- (void)setPortrait:(BOOL)portrait;
- (void)start;
- (void)stop;
- (void)sendControl:(NSDictionary *)control;
- (void)runSelfTest;
@end
