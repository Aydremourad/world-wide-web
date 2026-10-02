#import <UIKit/UIKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>

@interface YTVideoSurface : UIView {
    EAGLContext *_context;
    GLuint _framebuffer, _renderbuffer, _texture;
    GLint _backingWidth, _backingHeight;
    BOOL _aspectFill, _geometryDirty, _hasFrame;
    GLfloat _vertices[8], _coordinates[8];
    int _textureWidth, _textureHeight, _videoWidth, _videoHeight;
}
@property(nonatomic) BOOL aspectFill;
- (void)displayRGB565:(NSData *)pixels width:(int)width height:(int)height;
@end
