#import <UIKit/UIKit.h>
@class YTMediaSource, YTVideoSurface;

@interface YTSoftwarePlayer : UIViewController {
    NSDictionary *_streams;
    YTVideoSurface *_surface;
    UILabel *_message;
    UIButton *_pauseButton;
    YTMediaSource *_videoSource;
    YTMediaSource *_audioSource;
    volatile BOOL _stop;
    volatile BOOL _paused;
}
- (id)initWithStreams:(NSDictionary *)streams;
@end
