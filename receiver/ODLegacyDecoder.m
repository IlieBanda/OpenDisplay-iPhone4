#import "ODLegacyDecoder.h"
#import "ODWire.h"
#import "ODLog.h"
#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <arpa/inet.h>

/* iOS 6 ABI, documented by Kodi 16.1's DllVideoToolBox.h. It is NOT
 * the public iOS 8 callback or DecodeFrame signature. Never use it on iOS 8+. */
typedef CFTypeRef ODVTSession;
typedef void (*ODVTCallback)(void *, CFDictionaryRef, OSStatus, uint32_t, CVBufferRef);
typedef struct { ODVTCallback callback; void *refcon; } ODVTCallbacks;
typedef OSStatus (*ODVTCreate)(CFAllocatorRef, CMFormatDescriptionRef, CFTypeRef,
                              CFDictionaryRef, ODVTCallbacks *, ODVTSession *);
typedef OSStatus (*ODVTDecode)(ODVTSession, CMSampleBufferRef, uint32_t, CFDictionaryRef, uint32_t);
typedef OSStatus (*ODVTWait)(ODVTSession);
typedef void (*ODVTInvalidate)(ODVTSession);
typedef OSStatus (*ODVTCopyProperty)(ODVTSession, CFTypeRef, void *, CFTypeRef *);
typedef OSStatus (*ODFigFormat)(CFAllocatorRef, UInt32, UInt32, UInt32, UInt32,
                               const UInt8 *, CFIndex, CFDictionaryRef, CMFormatDescriptionRef *);

@interface ODLegacyDecoder () {
    void *_library, *_coreMedia;
    ODVTCreate _create;
    ODVTDecode _decode;
    ODVTWait _wait;
    ODVTInvalidate _invalidate;
    ODVTCopyProperty _copyProperty;
    ODFigFormat _figFormat;
    ODVTSession _session;
    CMFormatDescriptionRef _format;
    NSData *_sps, *_pps;
    BOOL _waitingIDR;
    NSUInteger _sampleIndex;
    OSStatus _outputStatus;
    NSUInteger _outputErrors;
}
@property(nonatomic, readwrite) NSString *diagnostics;
@property(nonatomic, readwrite) NSUInteger decodedFrames;
@property(nonatomic, readwrite) double lastDecodeMs;
- (void)output:(CVBufferRef)image status:(OSStatus)status;
@end

static void output(void *refcon, CFDictionaryRef frameInfo, OSStatus status,
                   uint32_t flags, CVBufferRef image) {
    @autoreleasepool { [(__bridge ODLegacyDecoder *)refcon output:image status:status]; }
}

@implementation ODLegacyDecoder
- (BOOL)open {
    if (_library) return _create && _decode && _wait && _invalidate;
    double version = [[[UIDevice currentDevice] systemVersion] doubleValue];
    if (version < 6 || version >= 7) {
        self.diagnostics = @"This experimental decoder supports iOS 6.x only.";
        ODLog(@"%@", self.diagnostics); return NO;
    }
    const char *paths[] = {"/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox",
                          "/System/Library/PrivateFrameworks/VideoToolbox.framework/VideoToolbox"};
    for (unsigned i = 0; i < 2 && !_library; ++i) {
        _library = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        ODLog(@"dlopen %s: %s", paths[i], _library ? "OK" : dlerror());
    }
    if (_library) {
        _create = (ODVTCreate)dlsym(_library, "VTDecompressionSessionCreate");
        _decode = (ODVTDecode)dlsym(_library, "VTDecompressionSessionDecodeFrame");
        _wait = (ODVTWait)dlsym(_library, "VTDecompressionSessionWaitForAsynchronousFrames");
        _invalidate = (ODVTInvalidate)dlsym(_library, "VTDecompressionSessionInvalidate");
        _copyProperty = (ODVTCopyProperty)dlsym(_library, "VTDecompressionSessionCopyProperty");
    }
    _coreMedia = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_NOW | RTLD_LOCAL);
    if (_coreMedia) _figFormat = (ODFigFormat)dlsym(_coreMedia, "FigVideoFormatDescriptionCreateWithSampleDescriptionExtensionAtom");
    BOOL ready = _create && _decode && _wait && _invalidate;
    self.diagnostics = [NSString stringWithFormat:@"iOS 6 VideoToolbox: %@; Fig format: %@",
                        ready ? @"symbols found" : @"missing symbols", _figFormat ? @"found" : @"unavailable"];
    ODLog(@"%@", self.diagnostics); _waitingIDR = YES;
    return ready;
}
- (void)destroySession {
    if (_session) { _wait(_session); _invalidate(_session); CFRelease(_session); _session = NULL; }
    if (_format) { CFRelease(_format); _format = NULL; }
}
- (void)reset {
    [self destroySession]; _sps = nil; _pps = nil; _waitingIDR = YES;
    _sampleIndex = 0; self.decodedFrames = 0; self.lastDecodeMs = 0; _outputErrors = 0;
}
- (void)dealloc {
    [self destroySession];
    if (_library) dlclose(_library);
    if (_coreMedia) dlclose(_coreMedia);
}
- (BOOL)makeSession {
    ODSPS s;
    if (!od_sps_parse(_sps.bytes, _sps.length, &s) || MAX(s.width,s.height) > 960 || MIN(s.width,s.height) > 640) {
        self.diagnostics = @"Invalid SPS or video above the 960x640 / 640x960 panel limit."; return NO;
    }
    ODLog(@"SPS %ux%u profile=%u level=%u", s.width, s.height, s.profile, s.level);
    /* High@3.2 was verified at 960x640/30 on the connected iPhone3,1.
     * Apple's file-playback specification alone understated this decoder. */
    if (s.profile != 66 && s.profile != 77 && s.profile != 100) {
        self.diagnostics = @"Unsupported H.264 profile.";
        ODLog(@"%@", self.diagnostics); return NO;
    }
    if (s.level > 32 || _sps.length > 65535 || _pps.length > 65535) {
        self.diagnostics = @"H.264 exceeds the tested Level 3.2 envelope."; return NO;
    }
    const uint8_t *sp = _sps.bytes;
    uint8_t head[] = {1, sp[1], sp[2], sp[3], 0xff, 0xe1,
                     (uint8_t)(_sps.length >> 8), (uint8_t)_sps.length};
    NSMutableData *avcc = [NSMutableData dataWithBytes:head length:sizeof(head)];
    [avcc appendData:_sps];
    uint8_t ph[] = {1, (uint8_t)(_pps.length >> 8), (uint8_t)_pps.length};
    [avcc appendBytes:ph length:sizeof(ph)]; [avcc appendData:_pps];
    OSStatus status;
    if (_figFormat) {
        status = _figFormat(NULL, 'avc1', s.width, s.height, 'avcC', avcc.bytes, avcc.length, NULL, &_format);
    } else {
        NSDictionary *ext = @{(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{@"avcC": avcc}};
        status = CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_H264, s.width, s.height,
                                               (__bridge CFDictionaryRef)ext, &_format);
    }
    ODLog(@"format creation status=%d", (int)status);
    if (status || !_format) { self.diagnostics = [NSString stringWithFormat:@"Format creation failed: %d", (int)status]; return NO; }
    NSDictionary *attrs = @{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                           (__bridge NSString *)kCVPixelBufferWidthKey: @(s.width),
                           (__bridge NSString *)kCVPixelBufferHeightKey: @(s.height),
                           (__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
                           (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    ODVTCallbacks callbacks = {output, (__bridge void *)self};
    status = _create(NULL, _format, NULL, (__bridge CFDictionaryRef)attrs, &callbacks, &_session);
    if (status) {
        if (_session) { _invalidate(_session); CFRelease(_session); _session = NULL; }
        NSMutableDictionary *fullRange = [attrs mutableCopy];
        fullRange[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
        status = _create(NULL,_format,NULL,(__bridge CFDictionaryRef)fullRange,&callbacks,&_session);
        ODLog(@"NV12 full-range fallback status=%d",(int)status);
    }
    if (status) {
        if (_session) { _invalidate(_session); CFRelease(_session); _session = NULL; }
        NSMutableDictionary *bgra = [attrs mutableCopy];
        bgra[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        [bgra removeObjectForKey:(__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey];
        status = _create(NULL,_format,NULL,(__bridge CFDictionaryRef)bgra,&callbacks,&_session);
        ODLog(@"NV12 compatibility fallback status=%d SPS=%@",(int)status,_sps);
    }
    self.diagnostics = [NSString stringWithFormat:@"Decoder %ux%u profile %u level %u: status %d", s.width, s.height, s.profile, s.level, (int)status];
    ODLog(@"%@", self.diagnostics);
    if (!status && _session && _copyProperty) {
        CFTypeRef value = NULL;
        OSStatus property = _copyProperty(_session, CFSTR("UsingHardwareAcceleratedVideoDecoder"), NULL, &value);
        ODLog(@"Hardware decoder property: status=%d value=%@", (int)property, value ? (__bridge id)value : @"unavailable");
        if (value) CFRelease(value);
    }
    BOOL ready = !status && _session;
    if (!ready) [self destroySession];
    return ready;
}
- (BOOL)decode:(const uint8_t *)bytes length:(size_t)length {
    if (!_create) return NO;
    size_t cursor = 0; ODNalu nal; BOOL changed = NO, idr = NO;
    NSMutableData *slices = [NSMutableData data];
    while (od_nalu_next(bytes, length, &cursor, &nal)) {
        if (nal.type == 7 || nal.type == 8) {
            if (nal.size > 4096) return NO;
            NSData *data = [NSData dataWithBytes:nal.data length:nal.size];
            if (nal.type == 7 && ![data isEqualToData:_sps]) { _sps = data; changed = YES; }
            if (nal.type == 8 && ![data isEqualToData:_pps]) { _pps = data; changed = YES; }
        } else if (nal.type == 1 || nal.type == 5) {
            idr |= nal.type == 5;
            uint32_t size = htonl((uint32_t)nal.size);
            [slices appendBytes:&size length:4]; [slices appendBytes:nal.data length:nal.size];
        }
    }
    if (changed) { [self destroySession]; _waitingIDR = YES; }
    if (!slices.length) return YES;
    if (_waitingIDR && !idr) return NO;
    if (!_session && (!_sps || !_pps || ![self makeSession])) return NO;
    _waitingIDR = NO;
    CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, slices.length, NULL, NULL, 0,
                                                        slices.length, 0, &block);
    if (!status) status = CMBlockBufferReplaceDataBytes(slices.bytes, block, 0, slices.length);
    size_t size = slices.length;
    CMSampleTimingInfo timing = {CMTimeMake(1,30), CMTimeMake((int64_t)_sampleIndex++,30), kCMTimeInvalid};
    if (!status) status = CMSampleBufferCreate(NULL, block, YES, NULL, NULL, _format, 1, 1,
                                             &timing, 1, &size, &sample);
    double start = CACurrentMediaTime(); _outputStatus = 0;
    if (!status) {
        NSDictionary *info = @{@"DisplayTime": @(start), @"PTS": @(start), @"DTS": @(start)};
        status = _decode(_session, sample, 0, (__bridge CFDictionaryRef)info, 0);
        OSStatus waited = _wait(_session); if (!status) status = waited;
        if (!status) status = _outputStatus;
    }
    self.lastDecodeMs = (CACurrentMediaTime()-start)*1000;
    if (sample) CFRelease(sample); if (block) CFRelease(block);
    if (status) {
        self.diagnostics = [NSString stringWithFormat:@"Decode failed: %d", (int)status];
        if (_outputErrors++ < 3) ODLog(@"%@", self.diagnostics);
        [self destroySession]; _waitingIDR = YES; return NO;
    }
    return YES;
}
- (void)output:(CVBufferRef)image status:(OSStatus)status {
    if (status || !image) { _outputStatus = status ? status : -1; return; }
    if (CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange && CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_32BGRA) { _outputStatus = -2; return; }
    self.decodedFrames++;
    if (self.decodedFrames == 1) ODLog(@"FIRST IMAGE %zux%zu format=0x%x", CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), (unsigned)CVPixelBufferGetPixelFormatType(image));
    if (self.onImage) self.onImage(image);
}
@end
