#import "ODReceiver.h"
#import "ODLegacyDecoder.h"
#import "ODWire.h"
#import "ODLog.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>

@interface ODReceiver () {
    NSNetService *_service;
    NSMutableArray *_outbox;
    NSUInteger _outboxBytes, _generation;
    BOOL _running, _busy, _connected, _overflow, _portrait;
    NSString *_identity;
    double _keyframeAt;
}
- (void)payload:(const uint8_t *)bytes length:(size_t)length decoder:(ODLegacyDecoder *)decoder;
- (void)status:(NSString *)message;
@end
typedef struct { __unsafe_unretained ODReceiver *receiver; __unsafe_unretained ODLegacyDecoder *decoder; NSUInteger videoPackets; } ODFrameContext;
static void receiveFrame(void *context, const uint8_t *p, size_t n) {
    ODFrameContext *c = context;
    if (!od_is_control(p,n)) ++c->videoPackets;
    @autoreleasepool { [c->receiver payload:p length:n decoder:c->decoder]; }
}
static NSData *frameJSON(NSDictionary *message) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    if (!json || !json.length || json.length >= 32768) return nil;
    uint32_t n = htonl((uint32_t)json.length);
    NSMutableData *data = [NSMutableData dataWithBytes:&n length:4]; [data appendData:json]; return data;
}
static int listener(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) return -1;
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0}; addr.sin_len = sizeof(addr); addr.sin_family = AF_INET;
    addr.sin_port = htons(port); addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 2)) { close(fd); return -1; }
    fcntl(fd, F_SETFL, O_NONBLOCK); return fd;
}

@implementation ODReceiver
- (id)init {
    if ((self = [super init])) {
        _outbox = [NSMutableArray array];
        _identity = [[NSUserDefaults standardUserDefaults] stringForKey:@"receiverID"];
        if (!_identity) {
            CFUUIDRef uuid = CFUUIDCreate(NULL); _identity = CFBridgingRelease(CFUUIDCreateString(NULL, uuid)); CFRelease(uuid);
            [[NSUserDefaults standardUserDefaults] setObject:_identity forKey:@"receiverID"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    } return self;
}
- (BOOL)running { @synchronized(self) { return _running || _busy; } }
- (BOOL)active:(NSUInteger)generation { @synchronized(self) { return _running && _generation == generation; } }
- (void)status:(NSString *)message {
    ODLog(@"%@", message);
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onStatus) self.onStatus(message); });
}
- (void)start {
    NSUInteger generation;
    @synchronized(self) { if (_busy) return; _running = _busy = YES; generation = ++_generation; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
        @autoreleasepool { [self serve:generation]; }
    });
}
- (void)advertise:(NSUInteger)generation {
    if (![self active:generation]) return;
    _service = [[NSNetService alloc] initWithDomain:@"local." type:@"_opensidecar._tcp."
                                             name:@"iPhone 4" port:9000];
    _service.delegate = self;
    [_service setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:
                               @{@"id": [_identity dataUsingEncoding:NSUTF8StringEncoding],
                                 @"pv": [@"3" dataUsingEncoding:NSUTF8StringEncoding]}]];
    [_service publish];
}
- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)error {
    [self status:[NSString stringWithFormat:@"Bonjour failed: %@. USB TCP still available.", error]];
}
- (void)stop {
    @synchronized(self) { _running = NO; _connected = NO; }
    [_service stop]; _service = nil;
}
- (void)setPortrait:(BOOL)portrait {
    @synchronized(self) { if (_portrait == portrait) return; _portrait = portrait; }
    ODLog(@"Orientation: %@",portrait ? @"portrait 640x960" : @"landscape 960x640");
    [self sendControl:[self hello]];
}
- (NSDictionary *)hello {
    BOOL portrait; @synchronized(self) { portrait = _portrait; }
    NSUInteger width = portrait ? 640 : 960, height = portrait ? 960 : 640, fps = 60;
    return @{@"type": @"hello", @"pv": @3, @"id": _identity, @"device": @"iPhone 4",
             @"pixelsWide": @(width), @"pixelsHigh": @(height), @"scale": @2,
             @"panel": @{@"pixelsWide": @(width), @"pixelsHigh": @(height), @"scale": @2},
             @"displayMaxFrameRate": @(fps), @"maxEncodeWide": @(width), @"maxEncodeHigh": @(height),
             @"videoCaps": @[@{@"codec": @"h264", @"maxWidth": @(width), @"maxHeight": @(height),
                               @"maxFrameRate": @(fps), @"maxPixelsPerSecond": @(width*height*fps)}]};
}
- (void)sendControl:(NSDictionary *)control {
    NSData *frame = frameJSON(control); if (!frame) return;
    @synchronized(self) {
        if (!_connected) return;
        if (_outboxBytes + frame.length > 65536) { _overflow = YES; return; }
        [_outbox addObject:frame]; _outboxBytes += frame.length;
    }
}
- (NSData *)takeOutput {
    @synchronized(self) {
        if (!_outbox.count) return nil;
        NSData *data = _outbox[0]; [_outbox removeObjectAtIndex:0]; _outboxBytes -= data.length; return data;
    }
}
- (void)connected:(BOOL)value {
    @synchronized(self) { _connected = value; [_outbox removeAllObjects]; _outboxBytes = 0; _overflow = NO; }
}
- (void)payload:(const uint8_t *)bytes length:(size_t)length decoder:(ODLegacyDecoder *)decoder {
    if (od_is_control(bytes,length)) {
        if (!od_json_depth_safe(bytes,length)) return;
        id json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:NULL];
        if (![json isKindOfClass:[NSDictionary class]]) return;
        NSString *type = json[@"type"];
        if ([type isEqual:@"streamConfig"]) {
            ODLog(@"streamConfig %@", json);
            if (![json[@"codec"] isEqual:@"h264"]) [self status:@"Unsupported video codec; this client requires H.264."];
        } else if ([type isEqual:@"updateRequired"]) [self status:@"Sender requires a newer receiver protocol."];
        else if ([type isEqual:@"welcome"]) ODLog(@"welcome %@", json);
        else if ([type isEqual:@"cursor"] || [type isEqual:@"cursorImg"]) { if (self.onCursor) self.onCursor(json); }
        /* Unknown controls are ignored. */
        return;
    }
    if (![decoder decode:bytes length:length] && CACurrentMediaTime()-_keyframeAt > 1) {
        _keyframeAt = CACurrentMediaTime(); [self sendControl:@{@"type": @"kf"}];
        [self status:decoder.diagnostics ?: @"Waiting for SPS/PPS and an IDR keyframe."];
    }
}
- (void)serve:(NSUInteger)generation {
    ODLegacyDecoder *decoder = [ODLegacyDecoder new];
    decoder.onImage = ^(CVPixelBufferRef image) { if ([self active:generation] && self.onImage) self.onImage(image); };
    if (![decoder open]) { [self status:decoder.diagnostics]; goto finished; }
    {
        NSInteger requested = [[NSUserDefaults standardUserDefaults] integerForKey:@"ListenPort"];
        uint16_t port = requested > 0 && requested < 65536 ? (uint16_t)requested : 9000;
        int server = listener(port);
        if (server < 0) { [self status:[NSString stringWithFormat:@"Cannot listen on TCP %u: %s", port, strerror(errno)]]; goto finished; }
        if (port == 9000) dispatch_async(dispatch_get_main_queue(), ^{ [self advertise:generation]; });
        [self status:[NSString stringWithFormat:@"Ready on TCP %u. Choose iPhone 4 in OpenDisplay.",port]];
        int peer = -1; ODFramer framer = {0}; ODFrameContext context = {self, decoder,0};
        NSData *pending = nil; size_t sent = 0;
        double lastRead = 0, lastPing = 0, lastStats = 0; NSUInteger lastFrames = 0, lastPresented = 0, basePresented = 0;
        while ([self active:generation]) {
            @autoreleasepool {
                if (peer >= 0 && !pending) pending = [self takeOutput];
                struct pollfd fds[2] = {{server, POLLIN,0}, {peer, (short)(POLLIN | (pending ? POLLOUT : 0)),0}};
                int result = poll(fds,2,50); if (result < 0 && errno != EINTR) break;
                if (fds[0].revents & POLLIN) {
                    int next = accept(server,NULL,NULL);
                    if (next >= 0) {
                        if (peer >= 0) close(peer); peer = next; fcntl(peer,F_SETFL,O_NONBLOCK);
                        int one = 1; setsockopt(peer,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
                        setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
                        od_framer_reset(&framer); [decoder reset]; context.videoPackets = 0; [self connected:YES]; _keyframeAt = 0;
                        if (self.onCursor) self.onCursor(@{@"type":@"cursorReset"});
                        pending = frameJSON([self hello]); sent = 0;
                        lastRead = lastPing = lastStats = CACurrentMediaTime(); lastFrames = 0;
                        basePresented = lastPresented = self.presentedFrames ? self.presentedFrames() : 0;
                        [self status:@"Sender connected. Waiting for H.264…"];
                        /* re-poll: revents below belongs to the replaced socket */
                        continue;
                    }
                }
                BOOL dead = NO;
                if (peer >= 0 && (fds[1].revents & POLLIN)) {
                    uint8_t bytes[16384]; ssize_t count = recv(peer,bytes,sizeof(bytes),0);
                    if (count > 0) { lastRead = CACurrentMediaTime(); dead = !od_framer_feed(&framer,bytes,(size_t)count,receiveFrame,&context); }
                    else if (count == 0 || (errno != EAGAIN && errno != EINTR)) dead = YES;
                }
                if (peer >= 0 && pending && (fds[1].revents & POLLOUT)) {
                    ssize_t n = send(peer,(const uint8_t *)pending.bytes+sent,pending.length-sent,0);
                    if (n > 0) { sent += (size_t)n; if (sent == pending.length) { pending = nil; sent = 0; } }
                    else if (n < 0 && errno != EAGAIN && errno != EINTR) dead = YES;
                }
                double now = CACurrentMediaTime();
                if (peer >= 0 && now-lastPing >= 2) {
                    [self sendControl:@{@"type": @"ping", @"t": @([[NSDate date] timeIntervalSince1970]*1000)}]; lastPing = now;
                }
                if (peer >= 0 && now-lastStats >= 5) {
                    double fps = (decoder.decodedFrames-lastFrames)/(now-lastStats);
                    NSUInteger presented = self.presentedFrames ? self.presentedFrames() : 0;
                    double displayFPS = (presented-lastPresented)/(now-lastStats);
                    NSString *stats = [NSString stringWithFormat:@"%.1f shown / %.1f decoded FPS · %.1f ms decode",displayFPS,fps,decoder.lastDecodeMs];
                    ODLog(@"%@", stats);
                    [self sendControl:@{@"type": @"stats", @"fps": @(displayFPS), @"decodeFPS": @(fps), @"presented": @(presented-basePresented), @"decLast": @(decoder.lastDecodeMs), @"decoded": @(decoder.decodedFrames), @"received": @(context.videoPackets), @"transport": @"TCP/iOS6"}];
                    dispatch_async(dispatch_get_main_queue(), ^{ if ([self active:generation] && self.onStats) self.onStats(stats); });
                    lastStats = now; lastFrames = decoder.decodedFrames; lastPresented = presented;
                }
                @synchronized(self) { if (_overflow) dead = YES; }
                if (peer >= 0 && (now-lastRead > 5 || fds[1].revents & (POLLERR|POLLHUP|POLLNVAL))) dead = YES;
                if (dead && peer >= 0) {
                    ODLog(@"SESSION END: %lu video packets; %lu decoded images; %lu presented images",(unsigned long)context.videoPackets,(unsigned long)decoder.decodedFrames,(unsigned long)((self.presentedFrames ? self.presentedFrames() : basePresented)-basePresented));
                    close(peer); peer = -1; pending = nil; sent = 0;
                    [self connected:NO]; od_framer_reset(&framer); [decoder reset];
                    [self status:@"Disconnected. Waiting for sender…"];
                }
            }
        }
        if (peer >= 0) {
            NSData *closing = frameJSON(@{@"type": @"closing"});
            /* Do not interleave a courtesy message into a partially sent frame. */
            if (!pending || sent == 0) send(peer,closing.bytes,closing.length,0);
            close(peer);
        }
        close(server); od_framer_reset(&framer); [decoder reset]; [self connected:NO];
    }
finished:
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) { if (_generation != generation) return; _running = _busy = NO; }
        [_service stop]; _service = nil;
    });
}
- (void)runSelfTest {
    NSUInteger generation;
    @synchronized(self) { if (_busy) return; _running = _busy = YES; generation = ++_generation; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
        @autoreleasepool {
            ODLegacyDecoder *decoder = [ODLegacyDecoder new];
            decoder.onImage = ^(CVPixelBufferRef image) { if ([self active:generation] && self.onImage) self.onImage(image); };
            [self status:@"30-second test: H.264 Main@3.1, 480x320…"];
            BOOL ok = [decoder open]; double start = CACurrentMediaTime();
            NSData *clip = [NSData dataWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"selftest" ofType:@"odframes"]];
            if (!clip) { ok = NO; [self status:@"Bundled test clip is missing."]; }
            ODFramer framer = {0}; ODFrameContext context = {self,decoder,0};
            const uint8_t *p = clip.bytes; size_t offset = 0; unsigned count = 0, loops = 0;
            /* Clip file contains length-prefixed access units, as on the network. */
            while (ok && loops < 10 && offset+4 <= clip.length && [self active:generation]) {
                uint32_t len; memcpy(&len,p+offset,4); len = ntohl(len);
                if (!len || len > OD_MAX_FRAME || len > clip.length-offset-4) { ok = NO; break; }
                ok = od_framer_feed(&framer,p+offset,len+4,receiveFrame,&context); offset += len+4;
                ++count; double deadline = start+count/30.0;
                double remaining = deadline-CACurrentMediaTime(); if (remaining > 0) usleep((useconds_t)(remaining*1000000));
                if (offset == clip.length) { ++loops; if (loops < 10) offset = 0; }
            }
            od_framer_reset(&framer);
            NSString *message;
            if (![self active:generation]) message = @"Test cancelled.";
            else if (ok && decoder.decodedFrames == count && count > 0 && loops == 10 && offset == clip.length)
                message = [NSString stringWithFormat:@"TEST PASSED: %lu decoded images. Last decode %.1f ms.",(unsigned long)decoder.decodedFrames,decoder.lastDecodeMs];
            else message = [NSString stringWithFormat:@"TEST FAILED: %@", decoder.diagnostics ?: @"invalid test stream"];
            [self status:message]; [decoder reset];
            @synchronized(self) { if (_generation == generation) _running = _busy = NO; }
        }
    });
}
@end
