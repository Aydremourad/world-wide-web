#import "YTSoftwarePlayer.h"
#import "YTMediaSource.h"
#import "YTHLSBridge.h"
#import "YTVideoSurface.h"
#import "YTAudioFile.h"
#import "YTAudioPump.h"
#include "YTPlayerTiming.h"
#import <QuartzCore/QuartzCore.h>
#include <sys/time.h>
#include "YTVideoDecoder.h"
#import <AudioToolbox/AudioToolbox.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libswscale/swscale.h>
#include <errno.h>
#include <math.h>
#include <string.h>

typedef struct {
    id source;
    int64_t position;
    BOOL sequential;
    volatile BOOL *stop;
} YTVideoIO;

@interface YTFramePacket : NSObject {
@public
    NSData *pixels;
    int width, height;
    unsigned serial;
    double time;
    BOOL preview;
}
- (id)initWithPixels:(NSData *)data width:(int)w height:(int)h serial:(unsigned)s;
@end
@implementation YTFramePacket
- (id)initWithPixels:(NSData *)data width:(int)w height:(int)h serial:(unsigned)s {
    if((self=[super init])) { pixels=[data retain]; width=w; height=h; serial=s; }
    return self;
}
- (void)dealloc { [pixels release]; [super dealloc]; }
@end

typedef struct {
    YTSoftwarePlayer *controller;
    YTAudio *audio;
    volatile BOOL *stop;
    volatile BOOL *paused;
    BOOL audioStarted;
    BOOL queuePaused;
    BOOL bufferingShown;
    BOOL droppingNonRef;
    BOOL preferReferenceFrames;
    BOOL aggressiveFrameDrop;
    unsigned serial;
    double startTime;
    BOOL previewShown;
    double lastResync;
    double lastDisplay;
    YTAudioTimeline timeline;
    NSTimeInterval wallStart;
    NSTimeInterval pauseStart;
    NSTimeInterval pauseTotal;
    double firstPTS;
    double nextPTS;
    double frameDuration;
    double videoTimeOffset;
    YTVideoImage image;
} YTPlayback;

@interface YTSoftwarePlayer ()
- (void)presentFrame:(YTFramePacket *)frame;
- (void)queueFrame:(YTFramePacket *)frame;
- (void)displayPendingFrame;
- (void)clearFrameQueue;
- (void)savePlaybackPerformance;
- (void)recordConversion:(double)seconds;
- (void)recordRead:(double)seconds;
- (NSString *)playSessionAtTime:(double)time serial:(unsigned)serial;
- (void)sessionFinished:(NSDictionary *)info;
- (void)updateTransport;
- (void)requestSeek:(double)seconds;
- (void)workerFinished:(NSString *)message;
- (void)setBuffering:(NSDictionary *)info;
- (void)attachAudioQueue:(NSDictionary *)info;
- (void)detachAudioQueue;
- (void)controlsTick:(NSTimer *)timer;
- (void)layoutPlayerChrome;
@end

static double YTPlayerWallTime(void) {
    struct timeval now; gettimeofday(&now,NULL);
    return now.tv_sec+now.tv_usec/1000000.0;
}

static int YTReadVideo(void *opaque, uint8_t *bytes, int count) {
    YTVideoIO *io = opaque;
    if (*io->stop) return AVERROR_EXIT;
    int result = io->sequential ? [io->source readInto:bytes count:count] :
        [io->source readAtOffset:io->position into:bytes count:count];
    if (result < 0) return AVERROR(EIO);
    if (!result) return AVERROR_EOF;
    io->position += result;
    return result;
}
static int64_t YTSeekVideo(void *opaque, int64_t offset, int whence) {
    YTVideoIO *io = opaque;
    if (*io->stop) return AVERROR_EXIT;
    if (whence == AVSEEK_SIZE) return [io->source length];
    whence &= ~AVSEEK_FORCE;
    int64_t target;
    if (whence == SEEK_SET) target = offset;
    else if (whence == SEEK_CUR) target = io->position + offset;
    else if (whence == SEEK_END) target = [io->source length] + offset;
    else return AVERROR(EINVAL);
    if (target < 0 || target > [io->source length]) return AVERROR(EINVAL);
    io->position = target;
    return target;
}
static int YTInterruptVideo(void *opaque) { return *(volatile BOOL *)opaque; }

static BOOL YTWaitForPause(YTPlayback *playback) {
    while (*playback->paused && !*playback->stop && !playback->audio->failed) {
        if (!playback->queuePaused) {
            playback->queuePaused = YES;
            playback->pauseStart = [NSDate timeIntervalSinceReferenceDate];
        }
        [NSThread sleepForTimeInterval:0.03];
    }
    if (playback->queuePaused && !*playback->stop) {
        playback->pauseTotal += [NSDate timeIntervalSinceReferenceDate] - playback->pauseStart;
        playback->queuePaused = NO;
    }
    return !*playback->stop && !playback->audio->failed;
}
static double YTPlaybackClock(YTPlayback *playback) {
    return YTAudioMediaTime(playback->audio);
}
static NSData *YTWrapVideoPixels(YTVideoImage *image) {
    if(!image->pixels || image->pixelBytes<=0) return nil;
    // Borrow one slot from the reusable RGB565 ring. Five slots cover the
    // three-frame queue, the frame being drawn, and the decoder's next frame.
    return [[NSData alloc] initWithBytesNoCopy:image->pixels
        length:(NSUInteger)image->pixelBytes freeWhenDone:NO];
}
static BOOL YTDisplayDecodedFrame(YTPlayback *playback, AVFrame *frame, AVRational timeBase) {
    int64_t timestamp = av_frame_get_best_effort_timestamp(frame);
    double pts = timestamp == AV_NOPTS_VALUE ? playback->nextPTS : timestamp * av_q2d(timeBase);
    if (isnan(playback->firstPTS)) playback->firstPTS = pts;
    pts -= playback->firstPTS;
    pts += playback->videoTimeOffset;
    playback->nextPTS = pts + playback->firstPTS + playback->frameDuration;
    if(pts < playback->startTime-0.025) return !*playback->stop;
    if(*playback->paused && !playback->audioStarted && !playback->previewShown) {
        double conversionStart=YTPlayerWallTime();
        if(YTConvertVideoFrame(&playback->image,frame)<0) return NO;
        [playback->controller recordConversion:YTPlayerWallTime()-conversionStart];
        NSData *previewPixels=YTWrapVideoPixels(&playback->image);
        YTFramePacket *preview=[[YTFramePacket alloc] initWithPixels:previewPixels
            width:playback->image.width height:playback->image.height serial:playback->serial];
        preview->time=pts; preview->preview=YES;
        [previewPixels release];
        [playback->controller queueFrame:preview];
        [preview release];
        playback->previewShown=YES;
    }
    if (!YTWaitForPause(playback)) return NO;
    if (!playback->audioStarted) {
        OSStatus result = AudioQueueStart(playback->audio->queue, NULL);
        if (result != noErr) { playback->audio->error = result; playback->audio->failed = YES; return NO; }
        playback->audioStarted = YES;
        playback->audio->started = YES;
        if (playback->audio->eof) AudioQueueStop(playback->audio->queue, false);
        playback->wallStart = [NSDate timeIntervalSinceReferenceDate];
        playback->pauseTotal = 0;
    }
    // Decode ahead instead of sleeping until every picture's PTS. A bounded
    // queue applies backpressure, and the display link uses the audio clock.
    double wait=pts-YTPlaybackClock(playback);
    BOOL buffering=playback->audio->starved && !playback->audio->eof;
    if(buffering!=playback->bufferingShown) {
        playback->bufferingShown=buffering;
        [playback->controller performSelectorOnMainThread:@selector(setBuffering:)
            withObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:buffering],@"buffering",
                [NSNumber numberWithUnsignedInt:playback->serial],@"serial",nil] waitUntilDone:NO];
    }
    if (*playback->stop || playback->audio->failed) return NO;
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (!YTShouldPresentFrame(wait, now, playback->lastDisplay)) return YES;
    playback->lastDisplay = now;
    double conversionStart=YTPlayerWallTime();
    if (YTConvertVideoFrame(&playback->image, frame) < 0) return NO;
    [playback->controller recordConversion:YTPlayerWallTime()-conversionStart];
    NSData *framePixels=YTWrapVideoPixels(&playback->image);
    YTFramePacket *payload=[[YTFramePacket alloc] initWithPixels:framePixels
        width:playback->image.width height:playback->image.height serial:playback->serial];
    payload->time=pts;
    [framePixels release];
    [playback->controller queueFrame:payload];
    [payload release];
    return !*playback->stop && !playback->audio->failed;
}

@implementation YTSoftwarePlayer
- (id)initWithStreams:(NSDictionary *)streams {
    if ((self = [super init])) {
        _oldStatusHidden = [UIApplication sharedApplication].statusBarHidden;
        self.wantsFullScreenLayout = YES;
        _streams = [streams retain]; _seekCondition=[[NSCondition alloc] init];
        _hlsBridge=[[_streams objectForKey:@"hlsBridge"] retain];
        _videoCache=[[_streams objectForKey:@"videoSource"] retain];
        _audioCache=[[_streams objectForKey:@"audioSource"] retain];
        if(!_videoCache && ![[_streams objectForKey:@"softwareHLS"] boolValue])
            _videoCache=[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"videoURL"]
                length:[[streams objectForKey:@"videoLength"] longLongValue] userAgent:[streams objectForKey:@"userAgent"]];
        if(!_audioCache) _audioCache=[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"audioURL"]
            length:[[streams objectForKey:@"audioLength"] longLongValue] userAgent:[streams objectForKey:@"userAgent"]];
        [_videoCache enableStreamingReadAhead]; [_audioCache enableStreamingReadAhead];
        if([[streams objectForKey:@"combined"] boolValue]) [_audioCache shareCacheWithSource:_videoCache];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [[UIApplication sharedApplication] setStatusBarHidden:YES animated:NO];
    self.wantsFullScreenLayout = YES;
    AudioSessionInitialize(NULL, NULL, NULL, NULL);
    UInt32 category = kAudioSessionCategory_MediaPlayback;
    AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
    AudioSessionSetActive(true);
    self.view.backgroundColor = [UIColor blackColor];
    CGRect bounds = self.view.bounds;
    _surface = [[YTVideoSurface alloc] initWithFrame:bounds];
    _surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_surface];
    UIButton *touch = [UIButton buttonWithType:UIButtonTypeCustom];
    touch.frame = bounds;
    touch.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [touch addTarget:self action:@selector(toggleControls) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:touch];
    _topBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 44)];
    _topBar.barStyle = UIBarStyleBlackTranslucent;
    _topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIBarButtonItem *done = [[[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(close)] autorelease];
    UIBarButtonItem *space = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
    _fitItem = [[UIBarButtonItem alloc] initWithTitle:@"Fill" style:UIBarButtonItemStyleBordered target:self action:@selector(toggleFit)];
    _qualityLabel=[[UILabel alloc] initWithFrame:CGRectMake(0,0,125,30)];
    _qualityLabel.backgroundColor=[UIColor clearColor]; _qualityLabel.textColor=[UIColor whiteColor];
    _qualityLabel.textAlignment=UITextAlignmentCenter; _qualityLabel.font=[UIFont boldSystemFontOfSize:13];
    _qualityHeight=[[_streams objectForKey:@"height"] intValue];
    if(!_qualityHeight) _qualityHeight=[[[_streams objectForKey:@"nativeInfo"] objectForKey:@"height"] intValue];
    _qualityLabel.text=_qualityHeight>0 ? [NSString stringWithFormat:@"%dp",_qualityHeight] : @"YouTube";
    UIBarButtonItem *qualityItem=[[[UIBarButtonItem alloc] initWithCustomView:_qualityLabel] autorelease];
    [_topBar setItems:[NSArray arrayWithObjects:done, space, qualityItem, space, _fitItem, nil]];
    [self.view addSubview:_topBar];
    _bottomControls = [[UIView alloc] initWithFrame:CGRectMake(0, bounds.size.height-100, bounds.size.width, 100)];
    _bottomControls.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    _bottomControls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:_bottomControls];
    _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 3, 48, 26)];
    _durationLabel = [[UILabel alloc] initWithFrame:CGRectMake(bounds.size.width-58, 3, 50, 26)];
    _durationLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _durationLabel.textAlignment = UITextAlignmentRight;
    for (UILabel *label in [NSArray arrayWithObjects:_elapsedLabel, _durationLabel, nil]) {
        label.textColor=[UIColor whiteColor]; label.backgroundColor=[UIColor clearColor];
        label.font=[UIFont boldSystemFontOfSize:12]; label.text=@"0:00";
        [_bottomControls addSubview:label];
    }
    _progress = [[UISlider alloc] initWithFrame:CGRectMake(60, 0, bounds.size.width-124, 32)];
    _progress.minimumValue=0; _progress.maximumValue=1; _progress.enabled=NO;
    [_progress addTarget:self action:@selector(scrubStarted) forControlEvents:UIControlEventTouchDown];
    [_progress addTarget:self action:@selector(scrubChanged) forControlEvents:UIControlEventValueChanged];
    [_progress addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    _progress.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [_bottomControls addSubview:_progress];
    _transportBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 30, bounds.size.width, 40)];
    _transportBar.barStyle = UIBarStyleBlackTranslucent;
    _transportBar.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    _playItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause target:self action:@selector(togglePause)];
    _backItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRewind target:self action:@selector(skipBack)];
    _forwardItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFastForward target:self action:@selector(skipForward)];
    _backItem.enabled=_forwardItem.enabled=NO; [self updateTransport];
    [_bottomControls addSubview:_transportBar];
    _volume = [[UISlider alloc] initWithFrame:CGRectMake(35, 70, bounds.size.width-70, 30)];
    _volume.minimumValue=0; _volume.maximumValue=1; _volume.value=1; _volume.continuous=YES;
    _volume.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [_volume addTarget:self action:@selector(volumeChanged) forControlEvents:UIControlEventValueChanged];
    [_bottomControls addSubview:_volume];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center=CGPointMake(bounds.size.width/2, bounds.size.height/2-15);
    _spinner.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _spinner.hidesWhenStopped=YES; [_spinner startAnimating]; [self.view addSubview:_spinner];
    _message=[[UILabel alloc] initWithFrame:CGRectMake(20, bounds.size.height/2+10, bounds.size.width-40, 55)];
    _message.autoresizingMask=UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _message.textColor=[UIColor whiteColor]; _message.backgroundColor=[UIColor clearColor];
    _message.font=[UIFont systemFontOfSize:14]; _message.textAlignment=UITextAlignmentCenter;
    _message.numberOfLines=3; _message.text=@"Loading..."; [self.view addSubview:_message];
    [self layoutPlayerChrome];
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    _performanceLastTick=YTPlayerWallTime();
    Class displayLinkClass=NSClassFromString(@"CADisplayLink");
    if(displayLinkClass) {
        _displayLink=[[displayLinkClass displayLinkWithTarget:self selector:@selector(displayPendingFrame)] retain];
        _displayLink.frameInterval=2;
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else {
        _frameTimer=[[NSTimer timerWithTimeInterval:1.0/30.0 target:self selector:@selector(displayPendingFrame)
            userInfo:nil repeats:YES] retain];
        [[NSRunLoop mainRunLoop] addTimer:_frameTimer forMode:NSRunLoopCommonModes];
    }
    _controlsTimer=[[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(controlsTick:) userInfo:nil repeats:YES] retain];
    [self retain];
    [NSThread detachNewThreadSelector:@selector(playThread:) toTarget:self withObject:nil];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { return YES; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[UIApplication sharedApplication] setStatusBarHidden:YES animated:NO];
    self.wantsFullScreenLayout=YES;
    [self layoutPlayerChrome];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self layoutPlayerChrome];
    [self performSelector:@selector(layoutPlayerChrome) withObject:nil afterDelay:0.0];
}
- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration {
    [self layoutPlayerChrome];
}
- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    [self layoutPlayerChrome];
}
- (void)layoutPlayerChrome {
    CGRect bounds=self.view.bounds;
    CGFloat width=bounds.size.width, height=bounds.size.height;
    CGFloat bottomHeight=100.0f;
    _surface.frame=bounds;
    _topBar.frame=CGRectMake(0,0,width,44);
    _bottomControls.frame=CGRectMake(0,height-bottomHeight,width,bottomHeight);
    _elapsedLabel.frame=CGRectMake(8,3,48,26);
    _durationLabel.frame=CGRectMake(width-58,3,50,26);
    _progress.frame=CGRectMake(60,0,width-124,32);
    _transportBar.frame=CGRectMake(0,30,width,40);
    _volume.frame=CGRectMake(35,68,width-70,30);
    _spinner.center=CGPointMake(width/2,height/2-15);
    _message.frame=CGRectMake(20,height/2+10,width-40,55);
}
- (NSString *)timeString:(double)seconds {
    int time=(int)(seconds > 0 ? seconds : 0);
    return [NSString stringWithFormat:@"%d:%02d",time/60,time%60];
}
- (void)setControlsHidden:(BOOL)hidden {
    _controlsHidden=hidden; _topBar.hidden=hidden; _bottomControls.hidden=hidden;
}
- (void)toggleControls {
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    BOOL hidden=!_controlsHidden;
    [self setControlsHidden:hidden];
    if(!hidden) [self controlsTick:nil];
}
- (void)toggleFit {
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    _surface.aspectFill=!_surface.aspectFill;
    _fitItem.title=_surface.aspectFill ? @"Fit" : @"Fill";
}
- (void)togglePause {
    if (_finished) { _paused=NO; [self requestSeek:0]; return; }
    _paused=!_paused; _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    [self updateTransport];
}
- (void)updateTransport {
    [_playItem release];
    _playItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:(_paused || _finished) ? UIBarButtonSystemItemPlay : UIBarButtonSystemItemPause target:self action:@selector(togglePause)];
    UIBarButtonItem *space=[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
    NSMutableArray *items=[NSMutableArray array];
    for(UIBarButtonItem *button in [NSArray arrayWithObjects:_backItem,_playItem,_forwardItem,nil]) {
        [items addObject:[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease]];
        [items addObject:button];
    }
    [items addObject:space]; [_transportBar setItems:items];
}
- (void)scrubStarted {
    if(_duration<=0 || _stop) return;
    _scrubbing=YES; _wasPaused=_paused; _paused=YES;
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate]; [self setControlsHidden:NO];
}
- (void)scrubChanged {
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    _elapsedLabel.text=[self timeString:_progress.value];
    _durationLabel.text=[@"-" stringByAppendingString:[self timeString:_duration-_progress.value]];
}
- (void)scrubEnded {
    if(!_scrubbing) return;
    _scrubbing=NO; _paused=_wasPaused; [self requestSeek:_progress.value];
}
- (void)skipBack { [self requestSeek:(_audioPump ? YTAudioMediaTime((YTAudio *)_audioPump) : _progress.value)-15]; }
- (void)skipForward { [self requestSeek:(_audioPump ? YTAudioMediaTime((YTAudio *)_audioPump) : _progress.value)+15]; }
- (void)requestSeek:(double)seconds {
    if(_stop || _duration<=0) return;
    seconds=YTClampSeekTime(seconds,_duration);
    if(_finished) _paused=NO;
    _finished=NO; _outputQueue=NULL; _audioPump=NULL;
    [_seekCondition lock];
    _seekTime=seconds; _seekPending=YES; _seekSerial++; _sessionStop=YES;
    [_videoSource cancel]; [_audioSource cancel];
    [self clearFrameQueue];
    [_seekCondition broadcast]; [_seekCondition unlock];
    _progress.value=seconds; [self scrubChanged]; [self updateTransport];
    _message.text=@"Seeking..."; _message.hidden=NO; [_spinner startAnimating];
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate]; [self setControlsHidden:NO];
}
- (void)volumeChanged {
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    if (_outputQueue) AudioQueueSetParameter(_outputQueue,kAudioQueueParam_Volume,_volume.value);
}
- (void)attachAudioQueue:(NSDictionary *)info {
    if(_stop || _sessionStop || [[info objectForKey:@"serial"] unsignedIntValue]!=_seekSerial) return;
    _outputQueue=[[info objectForKey:@"queue"] pointerValue];
    _audioPump=[[info objectForKey:@"audio"] pointerValue];
    _sampleRate=[[info objectForKey:@"rate"] doubleValue];
    _duration=[[info objectForKey:@"duration"] doubleValue];
    _progress.maximumValue=_duration>0 ? _duration : 1; _progress.enabled=_duration>0;
    _backItem.enabled=_forwardItem.enabled=_duration>0;
    [self controlsTick:nil]; [self volumeChanged];
}
- (void)detachAudioQueue { _outputQueue=NULL; _audioPump=NULL; }
- (void)controlsTick:(NSTimer *)timer {
    if (_stop) return;
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    if (_audioPump && !_scrubbing && !_controlsHidden) {
        double seconds=YTAudioMediaTime((YTAudio *)_audioPump);
        _elapsedLabel.text=[self timeString:seconds];
        _progress.value=seconds;
        _durationLabel.text=[@"-" stringByAppendingString:[self timeString:fmax(0,_duration-seconds)]];
    }
    if (!_paused && !_finished && !_scrubbing && _message.hidden && now-_lastControlTouch > 5)
        [self setControlsHidden:YES];
}
- (void)close {
    _stop=YES; _outputQueue=NULL; _audioPump=NULL;
    [_controlsTimer invalidate]; [_displayLink invalidate]; [_frameTimer invalidate];
    [self savePlaybackPerformance];
    [_seekCondition lock]; _sessionStop=YES;
    [_videoSource cancel]; [_audioSource cancel]; [self clearFrameQueue];
    [_seekCondition broadcast]; [_seekCondition unlock];
    // Restore the status bar before UIKit reveals the underlying navigation
    // controller so it receives the 320x460 application geometry immediately.
    [[UIApplication sharedApplication] setStatusBarHidden:_oldStatusHidden animated:NO];
    [self dismissModalViewControllerAnimated:NO];
}
- (void)presentFrame:(YTFramePacket *)frame {
    if (_stop || _sessionStop || frame->serial!=_seekSerial) return;
    if(!_message.hidden) { _message.hidden=YES; [_spinner stopAnimating]; }
    double started=YTPlayerWallTime();
    [_surface displayRGB565:frame->pixels width:frame->width height:frame->height];
    _renderSeconds+=YTPlayerWallTime()-started; _presentedFrames++;
}
- (void)clearFrameQueue {
    // Called with _seekCondition held. The queue is small and strictly bounded.
    id frame;
    while((frame=(id)YTFrameQueuePop(&_frameQueue))) [frame release];
}
- (void)queueFrame:(YTFramePacket *)frame {
    [_seekCondition lock];
    while(!_stop && !_sessionStop && frame->serial==_seekSerial &&
          _frameQueue.count==YT_FRAME_QUEUE_CAPACITY) {
        if(_audioPump && ((YTAudio *)_audioPump)->failed) break;
        NSDate *deadline=[[NSDate alloc] initWithTimeIntervalSinceNow:0.1];
        [_seekCondition waitUntilDate:deadline]; [deadline release];
    }
    if(!_stop && !_sessionStop && frame->serial==_seekSerial &&
       _frameQueue.count<YT_FRAME_QUEUE_CAPACITY) {
        [frame retain]; YTFrameQueuePush(&_frameQueue,frame,frame->time);
    }
    [_seekCondition unlock];
}
- (void)displayPendingFrame {
    double now=YTPlayerWallTime();
    if(_audioPump && !_paused && !_sessionStop && !_finished)
        _performanceSeconds+=now-_performanceLastTick;
    _performanceLastTick=now;
    if(_stop || _sessionStop) return;
    double time=_audioPump ? YTAudioMediaTime((YTAudio *)_audioPump) : 0;
    if(_audioPump && !_paused && YTAudioIsDrained((YTAudio *)_audioPump)) time=HUGE_VAL;
    YTFramePacket *selected=nil;
    [_seekCondition lock];
    while(_frameQueue.count) {
        YTFramePacket *first=(YTFramePacket *)_frameQueue.frames[_frameQueue.head];
        if(first->serial!=_seekSerial) { [(id)YTFrameQueuePop(&_frameQueue) release]; continue; }
        if(first->preview) {
            [selected release];
            selected=(YTFramePacket *)YTFrameQueuePop(&_frameQueue); break;
        }
        if(_paused || !_audioPump || !YTFrameQueueIsDue(&_frameQueue,time)) break;
        if(selected) { [selected release]; _supersededFrames++; }
        selected=(YTFramePacket *)YTFrameQueuePop(&_frameQueue);
    }
    [_seekCondition broadcast]; [_seekCondition unlock];
    if(selected) [self presentFrame:selected]; [selected release];
}
- (void)recordConversion:(double)seconds {
    [_seekCondition lock]; _convertSeconds+=seconds; [_seekCondition unlock];
}
- (void)recordRead:(double)seconds {
    [_seekCondition lock]; _readSeconds+=seconds; [_seekCondition unlock];
}
- (void)savePlaybackPerformance {
    [_seekCondition lock];
    double frames=_decodedFrames ? _decodedFrames : 1;
    double duration=_performanceSeconds;
    NSString *details=[NSString stringWithFormat:@"Quality: %dp\nSource: %.1f fps\nDecoded: %.1f fps\nDisplayed: %.1f fps\n\nTiming per decoded frame\nDecode: %.1f ms\nConversion: %.1f ms\nRead: %.1f ms\nDisplay: %.1f ms\n",
        _qualityHeight,_sourceFPS,duration>0 ? _decodedFrames/duration : 0,
        duration>0 ? _presentedFrames/duration : 0,1000*_decodeSeconds/frames,
        1000*_convertSeconds/frames,1000*_readSeconds/frames,
        _presentedFrames ? 1000*_renderSeconds/_presentedFrames : 0];
    [_seekCondition unlock];
    [details writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTube-playback.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
- (void)setBuffering:(NSDictionary *)info {
    if (_stop || _sessionStop || [[info objectForKey:@"serial"] unsignedIntValue]!=_seekSerial) return;
    NSNumber *value=[info objectForKey:@"buffering"];
    _message.text=@"Buffering..."; _message.hidden=![value boolValue];
    if ([value boolValue]) [_spinner startAnimating]; else [_spinner stopAnimating];
}
- (void)workerFinished:(NSString *)message {
    [_controlsTimer invalidate]; [_displayLink invalidate]; [_frameTimer invalidate];
    [self release];
}
- (void)sessionFinished:(NSDictionary *)info {
    if(_stop || _seekPending || [[info objectForKey:@"serial"] unsignedIntValue]!=_seekSerial) return;
    _finished=YES; _message.text=[info objectForKey:@"message"]; _message.hidden=NO;
    [_spinner stopAnimating]; [self updateTransport]; [self setControlsHidden:NO];
    [self savePlaybackPerformance];
}
- (void)playThread:(id)unused {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    double time=0;
    while(!_stop) {
        [_seekCondition lock];
        if(_seekPending) { time=_seekTime; _seekPending=NO; }
        _sessionStop=_stop; unsigned serial=_seekSerial; [_seekCondition unlock];
        NSAutoreleasePool *sessionPool=[[NSAutoreleasePool alloc] init];
        NSString *message=[self playSessionAtTime:time serial:serial];
        NSDictionary *info=[NSDictionary dictionaryWithObjectsAndKeys:message,@"message",
            [NSNumber numberWithUnsignedInt:serial],@"serial",nil];
        [self performSelectorOnMainThread:@selector(sessionFinished:) withObject:info waitUntilDone:YES];
        [sessionPool release];
        [_seekCondition lock];
        while(!_seekPending && !_stop) [_seekCondition wait];
        [_seekCondition unlock];
    }
    [self performSelectorOnMainThread:@selector(workerFinished:) withObject:nil waitUntilDone:NO];
    [pool release];
}
- (NSString *)playSessionAtTime:(double)time serial:(unsigned)serial {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *failure = nil;
    AVFormatContext *format = NULL;
    AVIOContext *ioContext = NULL;
    AVCodecContext *codec = NULL;
    AVFrame *frame = NULL;
    BOOL codecOpened = NO;
    BOOL sawFrame = NO;
    YTVideoIO io;
    YTAudio audio;
    YTPlayback playback;
    memset(&io, 0, sizeof(io)); memset(&audio, 0, sizeof(audio)); memset(&playback, 0, sizeof(playback));
    io.stop = &_sessionStop;
    audio.stop = &_sessionStop; audio.paused = &_paused; audio.startTime=time;
    playback.controller = self; playback.audio = &audio;
    playback.stop = &_sessionStop; playback.paused = &_paused; playback.serial=serial; playback.startTime=time;
    playback.firstPTS = NAN; playback.frameDuration = 1.0 / 15.0;
    BOOL softwareHLS=[[_streams objectForKey:@"softwareHLS"] boolValue] && _hlsBridge;
    double hlsStart=0;
    [_seekCondition lock];
    if(softwareHLS) {
        _videoSource=[[_hlsBridge newSequentialReaderAtTime:time actualStart:&hlsStart] retain];
        playback.videoTimeOffset=hlsStart;
    } else _videoSource=[_videoCache newReader];
    _audioSource=[_audioCache newReader];
    if(_sessionStop) { [_videoSource cancel]; [_audioSource cancel]; }
    [_seekCondition unlock];
    io.source = _videoSource; io.sequential=softwareHLS; audio.source = _audioSource;
    [NSThread setThreadPriority:0.85];
    if (_sessionStop) goto finished;
    av_register_all();
    format = avformat_alloc_context();
    uint8_t *readBuffer = av_malloc(65536);
    if (!format || !readBuffer) { av_free(readBuffer); failure = @"Not enough memory for the player."; goto finished; }
    ioContext = avio_alloc_context(readBuffer, 65536, 0, &io, YTReadVideo, NULL,
        softwareHLS ? NULL : YTSeekVideo);
    if (!ioContext) { av_free(readBuffer); failure = @"Could not create the video reader."; goto finished; }
    format->pb = ioContext;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    format->probesize = 65536;
    format->max_analyze_duration2 = AV_TIME_BASE;
    format->interrupt_callback.callback = YTInterruptVideo;
    format->interrupt_callback.opaque = (void *)&_sessionStop;
    if (avformat_open_input(&format, NULL, NULL, NULL) < 0) {
        failure = @"Could not open the MP4 video stream."; goto finished;
    }
    if(YTReadVideoMetadata(format)<0) { failure=@"Could not read the video format."; goto finished; }
    int videoStream = -1;
    for (unsigned int i = 0; i < format->nb_streams; i++) {
        if (format->streams[i]->codec->codec_type == AVMEDIA_TYPE_VIDEO && videoStream < 0) videoStream = i;
    }
    if (videoStream < 0) { failure = @"The response did not contain a video track."; goto finished; }
    for (unsigned int i = 0; i < format->nb_streams; i++)
        if ((int)i != videoStream) format->streams[i]->discard = AVDISCARD_ALL;
    codec = format->streams[videoStream]->codec;
    if (YTOpenH264Decoder(codec) < 0) {
        failure = [NSString stringWithFormat:@"Could not start video (%dx%d).", codec->width, codec->height];
        goto finished;
    }
    codecOpened = YES;
    frame = av_frame_alloc();
    if (!frame) { failure = @"Not enough memory for a video frame."; goto finished; }
    AVRational frameRate = format->streams[videoStream]->avg_frame_rate;
    if (frameRate.num > 0 && frameRate.den > 0) playback.frameDuration = av_q2d(av_inv_q(frameRate));
    _sourceFPS=1.0/playback.frameDuration;
    playback.preferReferenceFrames=YTPreferReferenceFrames(codec->width,codec->height,_sourceFPS);
    // A 15 fps 256x144 stream is already the CPU-saving rendition. Dropping
    // its B pictures again turns useful motion into the ~4-5 fps slideshow we
    // are trying to avoid. Reserve B-picture discard for 24/30 fps or larger
    // Main-profile sources.
    playback.aggressiveFrameDrop=(codec->codec_id==AV_CODEC_ID_H264 &&
        codec->profile>66 && (_sourceFPS>18.0 || codec->width*codec->height>38400));
    if(codec->codec_id==AV_CODEC_ID_H264) {
        if(playback.aggressiveFrameDrop) {
            // Main-profile YouTube video uses expensive B pictures. On ARM11,
            // discarding bidirectional pictures before reconstruction saves far
            // more CPU than decoding them and dropping them after the fact.
            codec->skip_frame=AVDISCARD_BIDIR;
            codec->skip_idct=AVDISCARD_BIDIR;
        } else if(playback.preferReferenceFrames) codec->skip_frame=AVDISCARD_NONREF;
    }
    playback.firstPTS=YTVideoTimeOrigin(format->streams[videoStream]);
    playback.nextPTS=playback.firstPTS+time;
    if(time>0 && !softwareHLS && YTSeekVideoToTime(format,videoStream,codec,time)<0) {
        failure=@"Could not seek to this part of the video."; goto finished;
    }
    OSStatus audioResult = YTPrepareAudio(&audio);
    if (audioResult != noErr) {
        failure = [NSString stringWithFormat:@"Could not start AAC audio (%ld).", (long)audioResult]; goto finished;
    }
    NSDictionary *queueInfo=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSValue valueWithPointer:audio.queue], @"queue",
        [NSValue valueWithPointer:&audio], @"audio",
        [NSNumber numberWithDouble:audio.format.mSampleRate], @"rate",
        [NSNumber numberWithBool:audio.directAAC], @"directAAC",
        [NSNumber numberWithDouble:softwareHLS ? [_hlsBridge totalDuration] :
            (format->duration > 0 ? (double)format->duration / AV_TIME_BASE : 0)], @"duration",
        [NSNumber numberWithUnsignedInt:serial],@"serial", nil];
    [self performSelectorOnMainThread:@selector(attachAudioQueue:) withObject:queueInfo waitUntilDone:YES];
    AVPacket packet;
    int readResult = 0;
    while (!_sessionStop && !audio.failed) {
        NSAutoreleasePool *packetPool=[[NSAutoreleasePool alloc] init];
        double readStarted=YTPlayerWallTime();
        readResult=av_read_frame(format,&packet);
        [self recordRead:YTPlayerWallTime()-readStarted];
        if(readResult<0) { [packetPool release]; break; }
        if (packet.stream_index == videoStream) {
            int64_t stamp=packet.pts!=AV_NOPTS_VALUE ? packet.pts : packet.dts;
            double now=[NSDate timeIntervalSinceReferenceDate];
            double audioTime=YTPlaybackClock(&playback);
            if(playback.audioStarted && !_paused && stamp!=AV_NOPTS_VALUE && codec->codec_id==AV_CODEC_ID_H264) {
                double packetTime=stamp*av_q2d(format->streams[videoStream]->time_base)-playback.firstPTS;
                double behind=audioTime-packetTime;
                playback.droppingNonRef=playback.preferReferenceFrames || YTShouldDropNonRef(playback.droppingNonRef,behind);
                if(playback.aggressiveFrameDrop) {
                    codec->skip_frame=AVDISCARD_BIDIR;
                    codec->skip_idct=AVDISCARD_BIDIR;
                } else {
                    codec->skip_frame=playback.droppingNonRef ? AVDISCARD_NONREF : AVDISCARD_DEFAULT;
                    codec->skip_idct=AVDISCARD_DEFAULT;
                }
            }
            if(playback.audioStarted && !_paused && stamp!=AV_NOPTS_VALUE &&
                YTNeedsVideoResync(stamp*av_q2d(format->streams[videoStream]->time_base)-playback.firstPTS,
                    audioTime,now,playback.lastResync)) {
                // Catch up at a future keyframe, never at a keyframe behind
                // audio that would make us repeatedly decode the same GOP.
                double target=audioTime+playback.frameDuration;
                if(YTAdvanceVideoToTime(format,videoStream,codec,target,playback.firstPTS)>=0) {
                    playback.lastResync=now;
                    playback.startTime=target; playback.nextPTS=target+playback.firstPTS;
                    [_seekCondition lock]; [self clearFrameQueue]; [_seekCondition broadcast]; [_seekCondition unlock];
                    av_free_packet(&packet); [packetPool release]; continue;
                }
            }
            AVPacket part = packet;
            while (part.size > 0 && !_sessionStop && !audio.failed) {
                int gotFrame = 0;
                double decodeStarted=YTPlayerWallTime();
                int used = avcodec_decode_video2(codec, frame, &gotFrame, &part);
                double decodeElapsed=YTPlayerWallTime()-decodeStarted;
                [_seekCondition lock]; _decodeSeconds+=decodeElapsed; if(gotFrame) _decodedFrames++; [_seekCondition unlock];
                if (used < 0) { failure = @"The video could not be decoded."; break; }
                if (gotFrame) {
                    sawFrame = YES;
                    if (!YTDisplayDecodedFrame(&playback, frame, format->streams[videoStream]->time_base)) {
                        if (!_sessionStop && !audio.failed) failure = @"Could not display the video frame.";
                        break;
                    }
                }
                if (!used) break;
                part.data += used; part.size -= used;
            }

        }
        av_free_packet(&packet);
        [packetPool release];
        if (failure) break;
    }
    if (!_sessionStop && !failure && !audio.failed && readResult == AVERROR_EOF) {
        av_init_packet(&packet); packet.data = NULL; packet.size = 0;
        for (int i = 0; i < 16 && !_sessionStop; i++) {
            int gotFrame = 0;
            if (avcodec_decode_video2(codec, frame, &gotFrame, &packet) < 0 || !gotFrame) break;
            sawFrame = YES;
            if (!YTDisplayDecodedFrame(&playback, frame, format->streams[videoStream]->time_base)) break;
        }
        [_seekCondition lock];
        while(_frameQueue.count && !_sessionStop && !audio.failed) {
            [_seekCondition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            if(audio.eof && YTAudioIsDrained(&audio)) { [self clearFrameQueue]; break; }
        }
        [_seekCondition unlock];
        // Let the final queued AAC buffers finish, with a bound for truncated streams.
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 5.0;
        while (playback.audioStarted && !_sessionStop && !audio.failed &&
               [NSDate timeIntervalSinceReferenceDate] < deadline) {
            if (!YTWaitForPause(&playback)) break;
            UInt32 running = 0, size = sizeof(running);
            if (AudioQueueGetProperty(audio.queue, kAudioQueueProperty_IsRunning, &running, &size) != noErr || !running) break;
            [NSThread sleepForTimeInterval:0.03];
        }
    } else if (!_sessionStop && !failure && !audio.failed && readResult < 0) failure = @"The video stream stopped unexpectedly.";
    if (!_sessionStop && !sawFrame && !failure) failure = @"The decoder did not produce a video frame.";
finished:
    [self performSelectorOnMainThread:@selector(detachAudioQueue) withObject:nil waitUntilDone:YES];
    // Frame packets borrow the conversion ring, so release queued packets
    // before freeing it. The main-thread round trip above lets an active draw finish.
    [_seekCondition lock]; [self clearFrameQueue]; [_seekCondition broadcast]; [_seekCondition unlock];
    YTShutdownAudio(&audio);
    YTFreeVideoImage(&playback.image);
    av_frame_free(&frame);
    if (codecOpened) avcodec_close(codec);
    if (format) avformat_close_input(&format);
    if (ioContext) { av_free(ioContext->buffer); av_free(ioContext); }
    if (!_sessionStop) {
        NSString *networkError = [_videoSource errorText];
        if (![networkError length]) networkError = [_audioSource errorText];
        if ([networkError length]) failure = networkError;
        else if (audio.failed) failure = [NSString stringWithFormat:@"AAC playback stopped (%ld).", (long)audio.error];
    }
    NSString *message = [(failure ? failure : @"Playback complete.\nTap Play to replay.") retain];
    [_seekCondition lock];
    [_videoSource release]; _videoSource=nil; [_audioSource release]; _audioSource=nil;
    [_seekCondition unlock];
    [pool release];
    return [message autorelease];
}
- (void)dealloc {
    [_controlsTimer invalidate]; [_controlsTimer release];
    [_streams release]; [_hlsBridge release]; [_surface release]; [_message release]; [_spinner release];
    [_elapsedLabel release]; [_durationLabel release]; [_qualityLabel release]; [_topBar release]; [_transportBar release];
    [_playItem release]; [_fitItem release]; [_backItem release]; [_forwardItem release];
    [_bottomControls release]; [_progress release]; [_volume release];
    [_displayLink invalidate]; [_displayLink release]; [_frameTimer invalidate]; [_frameTimer release];
    [_videoCache release]; [_audioCache release]; [self clearFrameQueue]; [_seekCondition release];
    [super dealloc];
}
@end
