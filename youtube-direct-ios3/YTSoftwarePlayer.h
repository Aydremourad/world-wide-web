#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
@class YTMediaSource, YTVideoSurface;
@interface YTSoftwarePlayer : UIViewController {
    NSDictionary *_streams;
    YTVideoSurface *_surface;
    UILabel *_message, *_elapsedLabel, *_durationLabel, *_qualityLabel;
    UIActivityIndicatorView *_spinner;
    UIToolbar *_topBar, *_transportBar;
    UIBarButtonItem *_playItem, *_fitItem, *_backItem, *_forwardItem;
    UIView *_bottomControls;
    UISlider *_progress;
    UISlider *_volume;
    NSTimer *_controlsTimer;
    YTMediaSource *_videoSource, *_audioSource, *_videoCache, *_audioCache;
    NSCondition *_seekCondition;
    id _pendingFrame;
    double _seekTime;
    unsigned _seekSerial;
    AudioQueueRef _outputQueue;
    void *_audioPump;
    double _duration, _sampleRate, _lastClock, _clockOffset;
    NSTimeInterval _lastControlTouch;
    int _qualityHeight;
    BOOL _controlsHidden, _oldStatusHidden, _finished, _scrubbing, _wasPaused;
    BOOL _seekPending, _frameScheduled;
    volatile BOOL _stop, _paused, _sessionStop;
}
- (id)initWithStreams:(NSDictionary *)streams;
@end
