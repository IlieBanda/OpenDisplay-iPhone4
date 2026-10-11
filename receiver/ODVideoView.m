#import "ODVideoView.h"
#import "ODLog.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/glext.h>
#include <math.h>
@interface ODVideoView () {
    CVPixelBufferRef _pending[3];
    unsigned _queued;
    BOOL _primed;
    CADisplayLink *_link;
    GLuint _program, _bgraProgram, _texture;
    GLint _bgraSampler;
    GLint _position, _uv, _sampler, _chroma, _range;
    BOOL _fullRange, _bgra;
    CVOpenGLESTextureCacheRef _cache;
    CVOpenGLESTextureRef _lumaTexture, _chromaTexture;
    size_t _width, _height;
    float _textureRight;
    BOOL _hasImage, _redraw;
    CGRect _videoRect;
    UITouch *_finger;
    NSTimer *_holdTimer;
    BOOL _pendingDown, _downSent;
    CGPoint _downNorm, _downPoint;
    CGPoint _scrollPoint;
    BOOL _scrolling;
    NSDictionary *_cursorPosition, *_cursorSprite;
    UIImageView *_cursorView;
    double _cursorX, _cursorY, _cursorW, _cursorH, _cursorAX, _cursorAY;
    BOOL _cursorVisible;
    NSUInteger _cursorSequence;
}
@property(atomic, readwrite) NSUInteger presentedFrames;
@end
static GLuint shader(GLenum kind,const char *source) {
    GLuint s = glCreateShader(kind); glShaderSource(s,1,&source,NULL); glCompileShader(s);
    GLint ok; glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
    if (!ok) { char message[1024]; glGetShaderInfoLog(s,sizeof(message),NULL,message); ODLog(@"GL shader: %s", message); glDeleteShader(s); return 0; }
    return s;
}
static double number(id value,double fallback) {
    if (![value isKindOfClass:[NSNumber class]]) return fallback;
    double n = [value doubleValue]; return isfinite(n) ? n : fallback;
}
static int base64Digit(uint8_t c) {
    if (c >= 'A' && c <= 'Z') return c-'A'; if (c >= 'a' && c <= 'z') return c-'a'+26;
    if (c >= '0' && c <= '9') return c-'0'+52; if (c == '+') return 62; if (c == '/') return 63; return -1;
}
static NSData *cursorPNG(id encoded) {
    if (![encoded isKindOfClass:[NSString class]] || [encoded length] > 32000) return nil;
    NSData *text = [encoded dataUsingEncoding:NSASCIIStringEncoding];
    if (!text.length || text.length%4) return nil;
    const uint8_t *p = text.bytes; NSMutableData *out = [NSMutableData dataWithLength:text.length/4*3];
    uint8_t *dst = out.mutableBytes; size_t used = 0;
    for (size_t i = 0; i < text.length; i += 4) {
        int a = base64Digit(p[i]), b = base64Digit(p[i+1]);
        int c = p[i+2] == '=' ? 0 : base64Digit(p[i+2]);
        int d = p[i+3] == '=' ? 0 : base64Digit(p[i+3]);
        if (a < 0 || b < 0 || c < 0 || d < 0 ||
            ((p[i+2] == '=' || p[i+3] == '=') && i+4 != text.length) ||
            (p[i+2] == '=' && p[i+3] != '=')) return nil;
        dst[used++] = (uint8_t)((a<<2)|(b>>4));
        if (p[i+2] != '=') dst[used++] = (uint8_t)((b<<4)|(c>>2));
        if (p[i+3] != '=') dst[used++] = (uint8_t)((c<<6)|d);
    }
    const uint8_t magic[] = {137,80,78,71,13,10,26,10};
    if (used < 24 || memcmp(dst,magic,8) || memcmp(dst+12,"IHDR",4)) return nil;
    uint32_t w = ((uint32_t)dst[16]<<24)|((uint32_t)dst[17]<<16)|((uint32_t)dst[18]<<8)|dst[19];
    uint32_t h = ((uint32_t)dst[20]<<24)|((uint32_t)dst[21]<<16)|((uint32_t)dst[22]<<8)|dst[23];
    if (!w || !h || w > 512 || h > 512) return nil;
    out.length = used;
    return out;
}
@implementation ODVideoView
- (id)initWithFrame:(CGRect)frame {
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if ((self = [super initWithFrame:frame context:context])) {
        self.delegate = self; self.enableSetNeedsDisplay = NO; self.multipleTouchEnabled = YES;
        self.contentScaleFactor = 2;
        self.opaque = YES;
        self.drawableDepthFormat = GLKViewDrawableDepthFormatNone;
        self.drawableStencilFormat = GLKViewDrawableStencilFormatNone;
        self.drawableColorFormat = GLKViewDrawableColorFormatRGBA8888;
        [EAGLContext setCurrentContext:context];
        GLuint v = shader(GL_VERTEX_SHADER,"attribute vec2 position; attribute vec2 uv; varying vec2 tc; void main(){gl_Position=vec4(position,0.,1.);tc=uv;}");
        GLuint f = shader(GL_FRAGMENT_SHADER,"precision mediump float; varying vec2 tc; uniform sampler2D image; uniform sampler2D chroma; uniform vec4 range; void main(){if(range.x<0.){gl_FragColor=texture2D(image,tc);return;} float y=(texture2D(image,tc).r-range.x)*range.y; vec2 c=texture2D(chroma,tc).ra-vec2(0.501961); gl_FragColor=vec4(y+range.z*c.y,y-range.w*(0.344136*c.x+0.714136*c.y),y+range.w*1.772*c.x,1.);}");
        if (v && f) {
            _program = glCreateProgram(); glAttachShader(_program,v); glAttachShader(_program,f); glBindAttribLocation(_program,0,"position"); glBindAttribLocation(_program,1,"uv"); glLinkProgram(_program);
            GLint ok; glGetProgramiv(_program,GL_LINK_STATUS,&ok);
            if (!ok) { ODLog(@"GL program link failed"); glDeleteProgram(_program); _program = 0; }
        }
        GLuint bgra = shader(GL_FRAGMENT_SHADER,"precision mediump float; varying vec2 tc; uniform sampler2D image; void main(){gl_FragColor=texture2D(image,tc);}");
        if (v && bgra) {
            _bgraProgram = glCreateProgram(); glAttachShader(_bgraProgram,v); glAttachShader(_bgraProgram,bgra);
            glBindAttribLocation(_bgraProgram,0,"position"); glBindAttribLocation(_bgraProgram,1,"uv"); glLinkProgram(_bgraProgram);
            _bgraSampler = glGetUniformLocation(_bgraProgram,"image");
        }
        if (bgra) glDeleteShader(bgra);
        if (v) glDeleteShader(v); if (f) glDeleteShader(f);
        if (_program) {
            _position = glGetAttribLocation(_program,"position"); _uv = glGetAttribLocation(_program,"uv");
            _sampler = glGetUniformLocation(_program,"image");
            _chroma = glGetUniformLocation(_program,"chroma"); _range = glGetUniformLocation(_program,"range");
            CVReturn status = CVOpenGLESTextureCacheCreate(NULL,NULL,context,NULL,&_cache);
            ODLog(@"GLES texture cache status=%d",status);
            glGenTextures(1,&_texture); glBindTexture(GL_TEXTURE_2D,_texture);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        }
        _redraw = YES;
        _cursorView = [UIImageView new]; _cursorView.hidden = YES; _cursorView.userInteractionEnabled = NO;
        [self addSubview:_cursorView];
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)]; _link.frameInterval = 1;
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } return self;
}
- (void)offerImage:(CVPixelBufferRef)image {
    CVPixelBufferRetain(image);
    @synchronized(self) {
        if (_queued == 3) { CVPixelBufferRelease(_pending[0]); _pending[0]=_pending[1]; _pending[1]=_pending[2]; _queued--; }
        _pending[_queued++] = image;
    }
}
- (void)tick:(CADisplayLink *)link {
    NSDictionary *position, *sprite;
    @synchronized(self) { position = _cursorPosition; _cursorPosition = nil; sprite = _cursorSprite; _cursorSprite = nil; }
    if (sprite) {
        NSData *png = cursorPNG(sprite[@"png"]); UIImage *image = png ? [UIImage imageWithData:png] : nil;
        if (image) {
            _cursorView.image = image; _cursorW = MAX(0,MIN(1,number(sprite[@"nw"],0)));
            _cursorH = MAX(0,MIN(1,number(sprite[@"nh"],0)));
            _cursorAX = MAX(0,MIN(1,number(sprite[@"ax"],0))); _cursorAY = MAX(0,MIN(1,number(sprite[@"ay"],0)));
        }
    }
    if (position) {
        if ([position[@"type"] isEqual:@"cursorReset"]) { _cursorVisible = NO; _cursorSequence = 0; }
        else {
            double sequence = number(position[@"s"],0);
            if (!position[@"s"] || sequence > _cursorSequence) {
                if (sequence > 0 && sequence < UINT32_MAX) _cursorSequence = (NSUInteger)sequence;
                _cursorX = MAX(0,MIN(1,number(position[@"x"],0))); _cursorY = MAX(0,MIN(1,number(position[@"y"],0)));
                _cursorVisible = number(position[@"v"],0) != 0;
            }
        }
    }
    double w = _cursorW*_videoRect.size.width, h = _cursorH*_videoRect.size.height;
    _cursorView.frame = CGRectMake(_videoRect.origin.x+_cursorX*_videoRect.size.width-_cursorAX*w,
                                  _videoRect.origin.y+_cursorY*_videoRect.size.height-_cursorAY*h,w,h);
    _cursorView.hidden = !_hasImage || !_cursorVisible || !_cursorView.image;
    BOOL pending; @synchronized(self) { if (_queued >= 2) _primed = YES; pending = _queued && _primed; }
    if (pending || _redraw) [self display];
}
- (void)offerCursor:(NSDictionary *)message {
    @synchronized(self) {
        if ([message[@"type"] isEqual:@"cursorImg"]) _cursorSprite = message;
        else _cursorPosition = message;
    }
}
- (void)layoutSubviews { [super layoutSubviews]; _redraw = YES; }
- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
    CVPixelBufferRef image = NULL;
    @synchronized(self) {
        if (_queued && _primed) { image = _pending[0]; for (unsigned i=1;i<_queued;i++) _pending[i-1]=_pending[i]; _queued--; }
    }
    [EAGLContext setCurrentContext:self.context];
    glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
    if (image && _program) {
        _width = CVPixelBufferGetWidth(image); _height = CVPixelBufferGetHeight(image);
        _fullRange = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        if (_lumaTexture) { CFRelease(_lumaTexture); _lumaTexture = NULL; }
        if (_chromaTexture) { CFRelease(_chromaTexture); _chromaTexture = NULL; }
        if (_cache && self.presentedFrames % 60 == 0) CVOpenGLESTextureCacheFlush(_cache,0);
        _bgra = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA;
        if (_bgra) {
            CVReturn result = CVOpenGLESTextureCacheCreateTextureFromImage(NULL,_cache,image,NULL,
                GL_TEXTURE_2D,GL_RGBA,(GLsizei)_width,(GLsizei)_height,GL_BGRA,GL_UNSIGNED_BYTE,0,&_lumaTexture);
            if (!result) {
                _textureRight = 1; BOOL first = !_hasImage; _hasImage = YES; self.presentedFrames++;
                if (first) { ODLog(@"FIRST PRESENT %zux%zu BGRA zero-copy drawable=%dx%d",_width,_height,self.drawableWidth,self.drawableHeight); if (self.onFirstImage) self.onFirstImage(); }
            } else { _hasImage = NO; ODLog(@"BGRA texture cache status=%d",result); }
        } else {
        CVReturn y = _cache ? CVOpenGLESTextureCacheCreateTextureFromImage(NULL,_cache,image,NULL,
            GL_TEXTURE_2D,GL_LUMINANCE,(GLsizei)_width,(GLsizei)_height,GL_LUMINANCE,GL_UNSIGNED_BYTE,0,&_lumaTexture) : -1;
        CVReturn uv = y == 0 ? CVOpenGLESTextureCacheCreateTextureFromImage(NULL,_cache,image,NULL,
            GL_TEXTURE_2D,GL_LUMINANCE_ALPHA,(GLsizei)(_width/2),(GLsizei)(_height/2),GL_LUMINANCE_ALPHA,GL_UNSIGNED_BYTE,1,&_chromaTexture) : -1;
        if (!y && !uv) {
            _textureRight = 1;
            BOOL first = !_hasImage; _hasImage = YES; self.presentedFrames++;
            if (first) { ODLog(@"FIRST PRESENT %zux%zu GLES2 NV12",_width,_height); if (self.onFirstImage) self.onFirstImage(); }
        } else { _hasImage = NO; ODLog(@"GLES texture cache image status=%d/%d",y,uv); }
        }

    }
    if (image) CVPixelBufferRelease(image);
    if (_hasImage && _program && _width && _height) {
        double scale = MIN(self.bounds.size.width/_width,self.bounds.size.height/_height);
        double w = _width*scale, h = _height*scale;
        _videoRect = CGRectMake((self.bounds.size.width-w)/2,(self.bounds.size.height-h)/2,w,h);
        float x = w/self.bounds.size.width, y = h/self.bounds.size.height;
        float vertices[] = {-x,-y,0,1, x,-y,_textureRight,1, -x,y,0,0, x,y,_textureRight,0};
        glUseProgram(_bgra ? _bgraProgram : _program);
        CVOpenGLESTextureRef textures[] = {_lumaTexture,_chromaTexture};
        for (int plane=0;plane<(_bgra ? 1 : 2);plane++) {
            glActiveTexture(GL_TEXTURE0+plane); glBindTexture(GL_TEXTURE_2D,CVOpenGLESTextureGetName(textures[plane]));
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        }
        if (!_bgra) { glUniform1i(_chroma,1);
        glUniform4f(_range,_bgra ? -1 : (_fullRange ? 0 : 16./255.),_fullRange ? 1 : 255./219.,_fullRange ? 1.402 : 1.596027,_fullRange ? 1 : 255./224.);
        }
        glUniform1i(_bgra ? _bgraSampler : _sampler,0); glEnableVertexAttribArray((GLuint)_position); glEnableVertexAttribArray((GLuint)_uv);
        glVertexAttribPointer((GLuint)_position,2,GL_FLOAT,GL_FALSE,4*sizeof(float),vertices);
        glVertexAttribPointer((GLuint)_uv,2,GL_FLOAT,GL_FALSE,4*sizeof(float),vertices+2);
        glDrawArrays(GL_TRIANGLE_STRIP,0,4);
    }
    _redraw = NO;
}
- (CGPoint)normalized:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    return CGPointMake(MAX(0,MIN(1,(p.x-_videoRect.origin.x)/MAX(1,_videoRect.size.width))),
                       MAX(0,MIN(1,(p.y-_videoRect.origin.y)/MAX(1,_videoRect.size.height))));
}
- (void)emit:(NSString *)phase touch:(UITouch *)touch {
    if (self.onTouch && _hasImage) { CGPoint p = [self normalized:touch]; self.onTouch(phase,p.x,p.y); }
}
- (void)commitPendingDown {
    if (!_pendingDown || _downSent) return;
    [_holdTimer invalidate]; _holdTimer = nil; _downSent = YES;
    if (self.onTouch) self.onTouch(@"began",_downNorm.x,_downNorm.y);
}
- (void)discardPendingDown {
    [_holdTimer invalidate]; _holdTimer = nil; _pendingDown = NO; _downSent = NO;
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    NSArray *active = [[event allTouches] allObjects];
    if (active.count >= 2) {
        if (_finger && _downSent) [self emit:@"cancelled" touch:_finger]; [self discardPendingDown]; _finger = nil;
        CGPoint a = [active[0] locationInView:self], b = [active[1] locationInView:self];
        _scrolling = YES; _scrollPoint = CGPointMake((a.x+b.x)/2,(a.y+b.y)/2);
    } else if (!_scrolling && !_finger) {
        UITouch *t = [touches anyObject];
        if (CGRectContainsPoint(_videoRect,[t locationInView:self])) {
            _finger = t; _downNorm = [self normalized:t]; _downPoint = [t locationInView:self];
            _pendingDown = YES; _downSent = NO;
            _holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 target:self selector:@selector(commitPendingDown) userInfo:nil repeats:NO];
        }
    }
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_scrolling) {
        NSArray *active = [[event allTouches] allObjects]; if (active.count < 2) return;
        CGPoint a = [active[0] locationInView:self], b = [active[1] locationInView:self];
        a = CGPointMake((a.x+b.x)/2,(a.y+b.y)/2);
        if (self.onScroll) self.onScroll((a.x-_scrollPoint.x)*_width/MAX(1,_videoRect.size.width),
                                        (a.y-_scrollPoint.y)*_height/MAX(1,_videoRect.size.height));
        _scrollPoint = a;
    } else if (_finger && [touches containsObject:_finger]) {
        CGPoint p = [_finger locationInView:self];
        if (_pendingDown && !_downSent && hypot(p.x-_downPoint.x,p.y-_downPoint.y) > 10) [self commitPendingDown];
        [self emit:@"moved" touch:_finger];
    }
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_finger && [touches containsObject:_finger]) {
        [self commitPendingDown];
        if (_downSent) [self emit:@"ended" touch:_finger];
        [self discardPendingDown]; _finger = nil;
    }
    BOOL any = NO;
    for (UITouch *t in [event allTouches]) if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) any = YES;
    if (!any) _scrolling = NO;
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_finger && _downSent) [self emit:@"cancelled" touch:_finger]; [self discardPendingDown]; _finger = nil; _scrolling = NO;
}
- (void)clear {
    if (_finger && _downSent) [self emit:@"cancelled" touch:_finger];
    [self discardPendingDown]; _finger = nil; _scrolling = NO;
    @synchronized(self) { for (unsigned i=0;i<_queued;i++) CVPixelBufferRelease(_pending[i]); _queued=0; _primed=NO; _cursorPosition = _cursorSprite = nil; }
    _cursorVisible = NO; _cursorSequence = 0; _cursorView.hidden = YES;
    _hasImage = NO; _width = _height = 0; _videoRect = CGRectZero; _redraw = YES;
}
- (void)shutdown { [self pause]; [_link invalidate]; _link = nil; [self clear]; }
- (void)pause { [self discardPendingDown]; _finger = nil; _scrolling = NO; _link.paused = YES; [EAGLContext setCurrentContext:self.context]; glFinish(); [EAGLContext setCurrentContext:nil]; }
- (void)resume { _link.paused = NO; }
- (void)dealloc {
    [_holdTimer invalidate]; [_link invalidate]; for (unsigned i=0;i<_queued;i++) CVPixelBufferRelease(_pending[i]);
    [EAGLContext setCurrentContext:self.context];
    if (_lumaTexture) CFRelease(_lumaTexture); if (_chromaTexture) CFRelease(_chromaTexture); if (_cache) CFRelease(_cache);
    if (_texture) glDeleteTextures(1,&_texture); if (_program) glDeleteProgram(_program); if (_bgraProgram) glDeleteProgram(_bgraProgram);
    [EAGLContext setCurrentContext:nil];
}
@end
