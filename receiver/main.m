#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "ODReceiver.h"
#import "ODVideoView.h"
#import "ODLog.h"

@interface ODController : UIViewController
@property(nonatomic,strong) ODReceiver *receiver;
@property(nonatomic,strong) ODVideoView *video;
@property(nonatomic,strong) UIView *ready;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UIImageView *icon;
@end
@implementation ODController
- (void)loadView {
    self.video = [[ODVideoView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.video.contentScaleFactor = 2; self.view = self.video;
    self.receiver = [ODReceiver new];
    [self.receiver setPortrait:self.view.bounds.size.height > self.view.bounds.size.width];
    self.ready = [[UIView alloc] initWithFrame:CGRectZero];
    self.ready.backgroundColor = [UIColor colorWithRed:0.86 green:0.88 blue:0.91 alpha:1];
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[(__bridge id)[UIColor colorWithWhite:0.98 alpha:1].CGColor,(__bridge id)[UIColor colorWithRed:0.78 green:0.82 blue:0.88 alpha:1].CGColor];
    [self.ready.layer insertSublayer:gradient atIndex:0]; [self.view addSubview:self.ready];
    self.icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"LegacyIcon.png"]]; [self.ready addSubview:self.icon];
    self.titleLabel = [UILabel new]; self.titleLabel.backgroundColor = [UIColor clearColor];
    self.titleLabel.text = @"Ready to connect"; self.titleLabel.font = [UIFont boldSystemFontOfSize:25];
    self.titleLabel.textColor = [UIColor colorWithRed:0.22 green:0.27 blue:0.34 alpha:1];
    self.titleLabel.shadowColor = [UIColor whiteColor]; self.titleLabel.shadowOffset = CGSizeMake(0,1);
    self.titleLabel.textAlignment = NSTextAlignmentCenter; [self.ready addSubview:self.titleLabel];
    self.detailLabel = [UILabel new]; self.detailLabel.backgroundColor = [UIColor clearColor];
    self.detailLabel.text = @"Select iPhone 4 in OpenDisplay on your Mac.\nConnect over Wi-Fi or USB.";
    self.detailLabel.font = [UIFont systemFontOfSize:14]; self.detailLabel.numberOfLines = 3;
    self.detailLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1]; self.detailLabel.textAlignment = NSTextAlignmentCenter;
    self.detailLabel.shadowColor = [UIColor whiteColor]; self.detailLabel.shadowOffset = CGSizeMake(0,1);
    [self.ready addSubview:self.detailLabel];
    __weak ODController *weakSelf = self;
    self.receiver.onImage = ^(CVPixelBufferRef image) { [weakSelf.video offerImage:image]; };
    self.receiver.onCursor = ^(NSDictionary *message) { [weakSelf.video offerCursor:message]; };
    self.receiver.presentedFrames = ^NSUInteger { return weakSelf.video.presentedFrames; };
    self.receiver.onStatus = ^(NSString *message) {
        if ([message hasPrefix:@"Disconnected"] || [message hasPrefix:@"Waiting"]) {
            [weakSelf.video clear]; weakSelf.ready.hidden = NO;
        } else if ([message hasPrefix:@"Cannot"] || [message hasPrefix:@"Bonjour failed"]) {
            weakSelf.detailLabel.text = message; weakSelf.ready.hidden = NO;
        }
    };
    self.video.onFirstImage = ^{ weakSelf.ready.hidden = YES; };
    self.video.onTouch = ^(NSString *phase,double x,double y) {
        [weakSelf.receiver sendControl:@{@"type":@"touch",@"phase":phase,@"x":@(x),@"y":@(y)}];
    };
    self.video.onScroll = ^(double dx,double dy) { [weakSelf.receiver sendControl:@{@"type":@"scroll",@"dx":@(dx),@"dy":@(dy)}]; };
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; CGRect b = self.view.bounds;
    [self.receiver setPortrait:b.size.height > b.size.width];
    self.ready.frame = b; ((CALayer *)self.ready.layer.sublayers[0]).frame = b;
    self.icon.frame = CGRectMake((b.size.width-57)/2,b.size.height/2-95,57,57);
    self.titleLabel.frame = CGRectMake(0,b.size.height/2-25,b.size.width,38);
    self.detailLabel.frame = CGRectMake(12,b.size.height/2+22,b.size.width-24,66);
}
- (void)captureReady {
    UIGraphicsBeginImageContextWithOptions(self.ready.bounds.size,YES,2);
    [self.ready.layer renderInContext:UIGraphicsGetCurrentContext()];
    NSData *png = UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext());
    UIGraphicsEndImageContext();
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/OpenDisplay-ready.png"];
    [png writeToFile:path atomically:YES];
}
- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }
- (void)start { if (!self.receiver.running) { [self.video clear]; self.ready.hidden = NO; [self.receiver start]; } }
@end

@interface ODApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) ODController *controller;
@end
@implementation ODApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    ODLog(@"LAUNCH %@ iOS %@",[[UIDevice currentDevice] model],[[UIDevice currentDevice] systemVersion]);
    application.statusBarHidden = YES; application.idleTimerDisabled = YES;
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.controller = [ODController new]; self.window.rootViewController = self.controller; [self.window makeKeyAndVisible];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"CaptureReady"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{ [self.controller captureReady]; });
    }
    return YES;
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)source annotation:(id)annotation {
    if (![[url scheme] isEqual:@"opendisplay4"]) return NO;
    [self.controller start]; return YES;
}
- (void)applicationWillResignActive:(UIApplication *)application {
    [self.controller.receiver stop]; [self.controller.video pause]; application.idleTimerDisabled = NO;
}
- (void)applicationWillTerminate:(UIApplication *)application {
    [self.controller.receiver stop]; [self.controller.video shutdown];
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self.controller.receiver stop];
    [self.controller.video shutdown];
    self.window.rootViewController = nil;
    self.controller = nil;
    // Release GLKit, its EAGL context and shader-cache mappings before suspension.
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    if (!self.controller) {
        self.controller = [ODController new]; self.window.rootViewController = self.controller;
    }
    [self.controller.video resume]; application.idleTimerDisabled = YES;
    // A previous worker can take one poll cycle to shut down after backgrounding.
    [self.controller start];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/5),dispatch_get_main_queue(), ^{
        if (application.applicationState == UIApplicationStateActive) [self.controller start];
    });
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass([ODApp class])); } }
