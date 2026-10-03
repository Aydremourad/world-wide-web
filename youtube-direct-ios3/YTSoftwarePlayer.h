#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#include "YTFrameQueue.h"
@class YTMediaSource, YTVideoSurface, YTHLSBridge;
@class CADisplayLink;
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
    id _videoSource;
    YTMediaSource *_audioSource, *_videoCache, *_audioCache;
    YTHLSBridge *_hlsBridge;
    NSCondition *_seekCondition;
    YTFrameQueue _frameQueue;
    CADisplayLink *_displayLink;
    NSTimer *_frameTimer;
    unsigned _decodedFrames, _presentedFrames, _supersededFrames;
    double _decodeSeconds, _convertSeconds, _renderSeconds, _readSeconds;
    double _performanceLastTick, _performanceSeconds, _sourceFPS;
    double _seekTime;
    unsigned _seekSerial;
    AudioQueueRef _outputQueue;
    void *_audioPump;
    double _duration, _sampleRate, _lastClock, _clockOffset;
    NSTimeInterval _lastControlTouch;
    int _qualityHeight;
    BOOL _controlsHidden, _oldStatusHidden, _finished, _scrubbing, _wasPaused;
    BOOL _seekPending;
    volatile BOOL _stop, _paused, _sessionStop;
}
- (id)initWithStreams:(NSDictionary *)streams;
@end
