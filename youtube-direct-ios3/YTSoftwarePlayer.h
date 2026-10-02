#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
@class YTMediaSource, YTVideoSurface;
@interface YTSoftwarePlayer : UIViewController {
    NSDictionary *_streams;
    YTVideoSurface *_surface;
    UILabel *_message, *_elapsedLabel, *_durationLabel;
    UIActivityIndicatorView *_spinner;
    UIToolbar *_topBar, *_transportBar;
    UIBarButtonItem *_playItem, *_fitItem;
    UIView *_bottomControls;
    UIProgressView *_progress;
    UISlider *_volume;
    NSTimer *_controlsTimer;
    YTMediaSource *_videoSource, *_audioSource;
    AudioQueueRef _outputQueue;
    void *_audioPump;
    double _duration, _sampleRate, _lastClock, _clockOffset;
    NSTimeInterval _lastControlTouch;
    BOOL _controlsHidden, _oldStatusHidden, _finished;
    volatile BOOL _stop, _paused;
}
- (id)initWithStreams:(NSDictionary *)streams;
@end
