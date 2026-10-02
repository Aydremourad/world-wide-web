#import "YTVideoSurface.h"
#import <QuartzCore/QuartzCore.h>

@implementation YTVideoSurface
@synthesize aspectFill = _aspectFill;
- (void)setAspectFill:(BOOL)value {
    _aspectFill=value;
    if (_lastPixels) [self displayRGB565:_lastPixels width:_videoWidth height:_videoHeight];
}
+ (Class)layerClass { return [CAEAGLLayer class]; }
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = YES;
        layer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
            kEAGLColorFormatRGB565, kEAGLDrawablePropertyColorFormat, nil];
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
        [EAGLContext setCurrentContext:_context];
        glGenFramebuffersOES(1, &_framebuffer);
        glGenRenderbuffersOES(1, &_renderbuffer);
        glGenTextures(1, &_texture);
        glBindTexture(GL_TEXTURE_2D, _texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_BLEND);
        glEnable(GL_TEXTURE_2D);
        glEnableClientState(GL_VERTEX_ARRAY);
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    }
    return self;
}
- (void)layoutSubviews {
    [EAGLContext setCurrentContext:_context];
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(CAEAGLLayer *)self.layer];
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &_backingWidth);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &_backingHeight);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES,
                                GL_RENDERBUFFER_OES, _renderbuffer);
    if (_lastPixels) [self displayRGB565:_lastPixels width:_videoWidth height:_videoHeight];
}
- (void)displayRGB565:(NSData *)pixels width:(int)width height:(int)height {
    if (width <= 0 || height <= 0 || [pixels length] != (NSUInteger)(width * height * 2)) return;
    if (pixels != _lastPixels) { [pixels retain]; [_lastPixels release]; _lastPixels=pixels; }
    if (!_backingWidth || !_backingHeight) [self layoutSubviews];
    [EAGLContext setCurrentContext:_context];
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glBindTexture(GL_TEXTURE_2D, _texture);
    if (width != _videoWidth || height != _videoHeight) {
        _videoWidth = width; _videoHeight = height;
        _textureWidth = 1; _textureHeight = 1;
        while (_textureWidth < width) _textureWidth *= 2;
        while (_textureHeight < height) _textureHeight *= 2;
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, _textureWidth, _textureHeight, 0,
                     GL_RGB, GL_UNSIGNED_SHORT_5_6_5, NULL);
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height,
                   GL_RGB, GL_UNSIGNED_SHORT_5_6_5, [pixels bytes]);
    glViewport(0, 0, _backingWidth, _backingHeight);
    glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    glMatrixMode(GL_PROJECTION); glLoadIdentity();
    glMatrixMode(GL_MODELVIEW); glLoadIdentity();
    GLfloat x = 1.0f, y = 1.0f;
    GLfloat videoAspect = (GLfloat)width / (GLfloat)height;
    GLfloat viewAspect = (GLfloat)_backingWidth / (GLfloat)_backingHeight;
    if (_aspectFill) {
        if (videoAspect > viewAspect) x = videoAspect / viewAspect;
        else y = viewAspect / videoAspect;
    } else {
        if (videoAspect > viewAspect) y = viewAspect / videoAspect;
        else x = videoAspect / viewAspect;
    }
    const GLfloat vertices[] = {-x, -y, x, -y, -x, y, x, y};
    GLfloat u = (GLfloat)width / (GLfloat)_textureWidth;
    GLfloat v = (GLfloat)height / (GLfloat)_textureHeight;
    const GLfloat coordinates[] = {0, v, u, v, 0, 0, u, 0};
    glVertexPointer(2, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coordinates);
    glColor4f(1, 1, 1, 1);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER_OES];
}
- (void)dealloc {
    [EAGLContext setCurrentContext:_context];
    if (_texture) glDeleteTextures(1, &_texture);
    if (_framebuffer) glDeleteFramebuffersOES(1, &_framebuffer);
    if (_renderbuffer) glDeleteRenderbuffersOES(1, &_renderbuffer);
    [EAGLContext setCurrentContext:nil];
    [_lastPixels release];
    [_context release];
    [super dealloc];
}
@end
