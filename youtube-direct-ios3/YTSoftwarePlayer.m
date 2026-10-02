#import "YTSoftwarePlayer.h"
#import "YTMediaSource.h"
#import "YTVideoSurface.h"
#import "YTAudioFile.h"
#import "YTAudioPump.h"
#include "YTPlayerTiming.h"
#include <sched.h>
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
    YTMediaSource *source;
    int64_t position;
    volatile BOOL *stop;
} YTVideoIO;

typedef struct {
    YTSoftwarePlayer *controller;
    YTAudio *audio;
    volatile BOOL *stop;
    volatile BOOL *paused;
    BOOL audioStarted;
    BOOL queuePaused;
    BOOL bufferingShown;
    BOOL catchUp;
    double lastDisplay;
    YTAudioTimeline timeline;
    NSTimeInterval wallStart;
    NSTimeInterval pauseStart;
    NSTimeInterval pauseTotal;
    double firstPTS;
    double nextPTS;
    double frameDuration;
    YTVideoImage image;
} YTPlayback;

@interface YTSoftwarePlayer ()
- (void)presentFrame:(NSDictionary *)frame;
- (void)workerFinished:(NSString *)message;
- (void)setBuffering:(NSNumber *)value;
- (void)attachAudioQueue:(NSDictionary *)info;
- (void)detachAudioQueue;
- (void)controlsTick:(NSTimer *)timer;
@end

static int YTReadVideo(void *opaque, uint8_t *bytes, int count) {
    YTVideoIO *io = opaque;
    if (*io->stop) return AVERROR_EXIT;
    int result = [io->source readAtOffset:io->position into:bytes count:count];
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
            if (playback->audioStarted) AudioQueuePause(playback->audio->queue);
            playback->queuePaused = YES;
            playback->pauseStart = [NSDate timeIntervalSinceReferenceDate];
        }
        [NSThread sleepForTimeInterval:0.03];
    }
    if (playback->queuePaused && !*playback->stop) {
        playback->pauseTotal += [NSDate timeIntervalSinceReferenceDate] - playback->pauseStart;
        if (playback->audioStarted) AudioQueueStart(playback->audio->queue, NULL);
        playback->queuePaused = NO;
    }
    return !*playback->stop && !playback->audio->failed;
}
static double YTPlaybackClock(YTPlayback *playback) {
    if (playback->audio->eof) {
        UInt32 running = 1, size = sizeof(running);
        if (AudioQueueGetProperty(playback->audio->queue, kAudioQueueProperty_IsRunning,
                                  &running, &size) == noErr && !running)
            return [NSDate timeIntervalSinceReferenceDate] - playback->wallStart - playback->pauseTotal;
    }
    AudioTimeStamp time;
    memset(&time, 0, sizeof(time));
    Boolean changed = false;
    if (AudioQueueGetCurrentTime(playback->audio->queue, NULL, &time, &changed) == noErr &&
        (time.mFlags & kAudioTimeStampSampleTimeValid))
        return YTContinuousAudioTime(&playback->timeline, time.mSampleTime / playback->audio->format.mSampleRate);
    return [NSDate timeIntervalSinceReferenceDate] - playback->wallStart - playback->pauseTotal;
}
static BOOL YTDisplayDecodedFrame(YTPlayback *playback, AVFrame *frame, AVRational timeBase) {
    if (!YTWaitForPause(playback)) return NO;
    int64_t timestamp = av_frame_get_best_effort_timestamp(frame);
    double pts = timestamp == AV_NOPTS_VALUE ? playback->nextPTS : timestamp * av_q2d(timeBase);
    if (isnan(playback->firstPTS)) playback->firstPTS = pts;
    pts -= playback->firstPTS;
    playback->nextPTS = pts + playback->firstPTS + playback->frameDuration;
    if (!playback->audioStarted) {
        OSStatus result = AudioQueueStart(playback->audio->queue, NULL);
        if (result != noErr) { playback->audio->error = result; playback->audio->failed = YES; return NO; }
        playback->audioStarted = YES;
        playback->audio->started = YES;
        if (playback->audio->eof) AudioQueueStop(playback->audio->queue, false);
        playback->wallStart = [NSDate timeIntervalSinceReferenceDate];
        playback->pauseTotal = 0;
    }
    double wait = pts - YTPlaybackClock(playback);
    while (wait > 0.01 && !*playback->stop && !playback->audio->failed) {
        if (!YTWaitForPause(playback)) return NO;
        BOOL buffering = playback->audio->starved && !playback->audio->eof;
        if (buffering != playback->bufferingShown) {
            playback->bufferingShown = buffering;
            [playback->controller performSelectorOnMainThread:@selector(setBuffering:)
                withObject:[NSNumber numberWithBool:buffering] waitUntilDone:NO];
        }
        [NSThread sleepForTimeInterval:wait < 0.02 ? wait : 0.02];
        wait = pts - YTPlaybackClock(playback);
        // A truncated audio track must not hold the video thread forever.
        if (playback->audio->eof && wait > 1.0) break;
    }
    if (*playback->stop || playback->audio->failed) return NO;
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (!YTShouldPresentFrame(wait, now, playback->lastDisplay)) return YES;
    playback->lastDisplay = now;
    if (YTConvertVideoFrame(&playback->image, frame) < 0) return NO;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSData dataWithBytes:playback->image.pixels length:playback->image.pixelBytes], @"pixels",
        [NSNumber numberWithInt:playback->image.width], @"width",
        [NSNumber numberWithInt:playback->image.height], @"height", nil];
    [playback->controller performSelectorOnMainThread:@selector(presentFrame:)
                                          withObject:payload waitUntilDone:YES];
    [pool release];
    return !*playback->stop;
}

@implementation YTSoftwarePlayer
- (id)initWithStreams:(NSDictionary *)streams {
    if ((self = [super init])) _streams = [streams retain];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    _oldStatusHidden = [UIApplication sharedApplication].statusBarHidden;
    [[UIApplication sharedApplication] setStatusBarHidden:YES animated:YES];
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
    [_topBar setItems:[NSArray arrayWithObjects:done, space, _fitItem, nil]];
    [self.view addSubview:_topBar];
    _bottomControls = [[UIView alloc] initWithFrame:CGRectMake(0, bounds.size.height-100, bounds.size.width, 100)];
    _bottomControls.backgroundColor = [UIColor colorWithWhite:0 alpha:0.70];
    _bottomControls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:_bottomControls];
    _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 3, 45, 22)];
    _durationLabel = [[UILabel alloc] initWithFrame:CGRectMake(bounds.size.width-55, 3, 45, 22)];
    _durationLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _durationLabel.textAlignment = UITextAlignmentRight;
    for (UILabel *label in [NSArray arrayWithObjects:_elapsedLabel, _durationLabel, nil]) {
        label.textColor=[UIColor whiteColor]; label.backgroundColor=[UIColor clearColor];
        label.font=[UIFont boldSystemFontOfSize:12]; label.text=@"0:00";
        [_bottomControls addSubview:label];
    }
    _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    _progress.frame=CGRectMake(60, 12, bounds.size.width-120, 9);
    _progress.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [_bottomControls addSubview:_progress];
    _transportBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 26, bounds.size.width, 40)];
    _transportBar.barStyle = UIBarStyleBlackTranslucent;
    _transportBar.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    _playItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause target:self action:@selector(togglePause)];
    [_transportBar setItems:[NSArray arrayWithObjects:space, _playItem, space, nil]];
    [_bottomControls addSubview:_transportBar];
    _volume = [[UISlider alloc] initWithFrame:CGRectMake(35, 66, bounds.size.width-70, 30)];
    _volume.minimumValue=0; _volume.maximumValue=1; _volume.value=1;
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
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    _controlsTimer=[[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(controlsTick:) userInfo:nil repeats:YES] retain];
    [self retain];
    [NSThread detachNewThreadSelector:@selector(playThread:) toTarget:self withObject:nil];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { return YES; }
- (NSString *)timeString:(double)seconds {
    int time=(int)(seconds > 0 ? seconds : 0);
    return [NSString stringWithFormat:@"%d:%02d",time/60,time%60];
}
- (void)setControlsHidden:(BOOL)hidden {
    _controlsHidden=hidden; _topBar.hidden=hidden; _bottomControls.hidden=hidden;
}
- (void)toggleControls {
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    [self setControlsHidden:!_controlsHidden];
}
- (void)toggleFit {
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    _surface.aspectFill=!_surface.aspectFill;
    _fitItem.title=_surface.aspectFill ? @"Fit" : @"Fill";
}
- (void)togglePause {
    if (_finished) return;
    _paused=!_paused; _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    if (_outputQueue) {
        if (_paused) AudioQueuePause(_outputQueue);
        else AudioQueueStart(_outputQueue,NULL);
    }
    [_playItem release];
    _playItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:_paused ? UIBarButtonSystemItemPlay : UIBarButtonSystemItemPause target:self action:@selector(togglePause)];
    UIBarButtonItem *space=[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
    [_transportBar setItems:[NSArray arrayWithObjects:space,_playItem,space,nil]];
}
- (void)volumeChanged {
    _lastControlTouch=[NSDate timeIntervalSinceReferenceDate];
    if (_outputQueue) AudioQueueSetParameter(_outputQueue,kAudioQueueParam_Volume,_volume.value);
}
- (void)attachAudioQueue:(NSDictionary *)info {
    _outputQueue=[[info objectForKey:@"queue"] pointerValue];
    _sampleRate=[[info objectForKey:@"rate"] doubleValue];
    _duration=[[info objectForKey:@"duration"] doubleValue];
    _durationLabel.text=[self timeString:_duration]; [self volumeChanged];
}
- (void)detachAudioQueue { _outputQueue=NULL; }
- (void)controlsTick:(NSTimer *)timer {
    if (_stop) return;
    if (_outputQueue && _sampleRate > 0) {
        AudioTimeStamp time; memset(&time,0,sizeof(time)); Boolean changed=false;
        if (AudioQueueGetCurrentTime(_outputQueue,NULL,&time,&changed)==noErr && (time.mFlags & kAudioTimeStampSampleTimeValid)) {
            double raw=time.mSampleTime/_sampleRate;
            if (raw+_clockOffset < _lastClock-0.25) _clockOffset=_lastClock-raw;
            double seconds=raw+_clockOffset;
            if (seconds < _lastClock) seconds=_lastClock; _lastClock=seconds;
            _elapsedLabel.text=[self timeString:seconds];
            _progress.progress=_duration > 0 ? fmin(1,seconds/_duration) : 0;
        }
    }
    if (!_paused && !_finished && _message.hidden && [NSDate timeIntervalSinceReferenceDate]-_lastControlTouch > 5)
        [self setControlsHidden:YES];
}
- (void)close {
    _stop=YES; _outputQueue=NULL;
    [_controlsTimer invalidate];
    [_videoSource cancel]; [_audioSource cancel];
    [[UIApplication sharedApplication] setStatusBarHidden:_oldStatusHidden animated:YES];
    [self dismissModalViewControllerAnimated:YES];
}
- (void)presentFrame:(NSDictionary *)frame {
    if (_stop) return;
    _message.hidden=YES; [_spinner stopAnimating];
    [_surface displayRGB565:[frame objectForKey:@"pixels"] width:[[frame objectForKey:@"width"] intValue] height:[[frame objectForKey:@"height"] intValue]];
}
- (void)setBuffering:(NSNumber *)value {
    if (_stop) return;
    _message.text=@"Buffering..."; _message.hidden=![value boolValue];
    if ([value boolValue]) [_spinner startAnimating]; else [_spinner stopAnimating];
}
- (void)workerFinished:(NSString *)message {
    if (!_stop) {
        _finished=YES; _message.text=message; _message.hidden=NO;
        [_spinner stopAnimating]; _playItem.enabled=NO; [self setControlsHidden:NO];
    }
    [_controlsTimer invalidate];
    [_videoSource release]; _videoSource=nil; [_audioSource release]; _audioSource=nil;
    [self release];
}
- (void)playThread:(id)unused {
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
    io.stop = &_stop;
    audio.stop = &_stop; audio.paused = &_paused;
    playback.controller = self; playback.audio = &audio;
    playback.stop = &_stop; playback.paused = &_paused;
    playback.firstPTS = NAN; playback.frameDuration = 1.0 / 15.0;
    _videoSource = [[_streams objectForKey:@"videoSource"] retain];
    _audioSource = [[_streams objectForKey:@"audioSource"] retain];
    if (!_videoSource) _videoSource = [[YTMediaSource alloc] initWithURL:[_streams objectForKey:@"videoURL"]
        length:[[_streams objectForKey:@"videoLength"] longLongValue] userAgent:[_streams objectForKey:@"userAgent"]];
    if (!_audioSource) _audioSource = [[YTMediaSource alloc] initWithURL:[_streams objectForKey:@"audioURL"]
        length:[[_streams objectForKey:@"audioLength"] longLongValue] userAgent:[_streams objectForKey:@"userAgent"]];
    io.source = _videoSource; audio.source = _audioSource;
    if (_stop) goto finished;
    av_register_all();
    format = avformat_alloc_context();
    uint8_t *readBuffer = av_malloc(32768);
    if (!format || !readBuffer) { av_free(readBuffer); failure = @"Not enough memory for the player."; goto finished; }
    ioContext = avio_alloc_context(readBuffer, 32768, 0, &io, YTReadVideo, NULL, YTSeekVideo);
    if (!ioContext) { av_free(readBuffer); failure = @"Could not create the video reader."; goto finished; }
    format->pb = ioContext;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    format->probesize = 65536;
    format->max_analyze_duration = AV_TIME_BASE;
    format->interrupt_callback.callback = YTInterruptVideo;
    format->interrupt_callback.opaque = (void *)&_stop;
    if (avformat_open_input(&format, NULL, NULL, NULL) < 0) {
        failure = @"Could not open the MP4 video stream."; goto finished;
    }
    int videoStream = -1;
    for (unsigned int i = 0; i < format->nb_streams; i++) {
        if (format->streams[i]->codec->codec_type == AVMEDIA_TYPE_VIDEO) { videoStream = i; break; }
    }
    if (videoStream < 0) { failure = @"The response did not contain a video track."; goto finished; }
    codec = format->streams[videoStream]->codec;
    if (YTOpenH264Decoder(codec) < 0) {
        failure = [NSString stringWithFormat:@"Could not start H.264 video (%dx%d).", codec->width, codec->height];
        goto finished;
    }
    codecOpened = YES;
    frame = av_frame_alloc();
    if (!frame) { failure = @"Not enough memory for a video frame."; goto finished; }
    AVRational frameRate = format->streams[videoStream]->avg_frame_rate;
    if (frameRate.num > 0 && frameRate.den > 0) playback.frameDuration = av_q2d(av_inv_q(frameRate));
    OSStatus audioResult = YTPrepareAudio(&audio);
    if (audioResult != noErr) {
        failure = [NSString stringWithFormat:@"Could not start AAC audio (%ld).", (long)audioResult]; goto finished;
    }
    NSDictionary *queueInfo=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSValue valueWithPointer:audio.queue], @"queue",
        [NSNumber numberWithDouble:audio.format.mSampleRate], @"rate",
        [NSNumber numberWithDouble:format->duration > 0 ? (double)format->duration / AV_TIME_BASE : 0], @"duration", nil];
    [self performSelectorOnMainThread:@selector(attachAudioQueue:) withObject:queueInfo waitUntilDone:YES];
    AVPacket packet;
    int readResult = 0;
    while (!_stop && !audio.failed && (readResult = av_read_frame(format, &packet)) >= 0) {
        if (packet.stream_index == videoStream) {
            BOOL key=(packet.flags & AV_PKT_FLAG_KEY) != 0;
            int64_t stamp=packet.pts != AV_NOPTS_VALUE ? packet.pts : packet.dts;
            if (playback.audioStarted && stamp != AV_NOPTS_VALUE && !isnan(playback.firstPTS)) {
                double packetTime=stamp * av_q2d(format->streams[videoStream]->time_base) - playback.firstPTS;
                if (YTNeedsVideoCatchUp(packetTime,YTPlaybackClock(&playback),codec->width*codec->height > 38400,key)) playback.catchUp=YES;
            }
            if (playback.catchUp && !key) { av_free_packet(&packet); sched_yield(); continue; }
            if (playback.catchUp) { avcodec_flush_buffers(codec); playback.catchUp=NO; }
            AVPacket part = packet;
            while (part.size > 0 && !_stop && !audio.failed) {
                int gotFrame = 0;
                int used = avcodec_decode_video2(codec, frame, &gotFrame, &part);
                if (used < 0) { failure = @"The H.264 video could not be decoded."; break; }
                if (gotFrame) {
                    sawFrame = YES;
                    if (!YTDisplayDecodedFrame(&playback, frame, format->streams[videoStream]->time_base)) {
                        if (!_stop && !audio.failed) failure = @"Could not display the video frame.";
                        break;
                    }
                }
                if (!used) break;
                part.data += used; part.size -= used;
            }
        }
        av_free_packet(&packet);
        sched_yield();
        if (failure) break;
    }
    if (!_stop && !failure && !audio.failed && readResult == AVERROR_EOF) {
        av_init_packet(&packet); packet.data = NULL; packet.size = 0;
        for (int i = 0; i < 16 && !_stop; i++) {
            int gotFrame = 0;
            if (avcodec_decode_video2(codec, frame, &gotFrame, &packet) < 0 || !gotFrame) break;
            sawFrame = YES;
            if (!YTDisplayDecodedFrame(&playback, frame, format->streams[videoStream]->time_base)) break;
        }
        // Let the final queued AAC buffers finish, with a bound for truncated streams.
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 5.0;
        while (playback.audioStarted && !_stop && !audio.failed &&
               [NSDate timeIntervalSinceReferenceDate] < deadline) {
            if (!YTWaitForPause(&playback)) break;
            UInt32 running = 0, size = sizeof(running);
            if (AudioQueueGetProperty(audio.queue, kAudioQueueProperty_IsRunning, &running, &size) != noErr || !running) break;
            [NSThread sleepForTimeInterval:0.03];
        }
    } else if (!_stop && !failure && !audio.failed && readResult < 0) failure = @"The video stream stopped unexpectedly.";
    if (!_stop && !sawFrame && !failure) failure = @"The decoder did not produce a video frame.";
finished:
    [self performSelectorOnMainThread:@selector(detachAudioQueue) withObject:nil waitUntilDone:YES];
    YTShutdownAudio(&audio);
    YTFreeVideoImage(&playback.image);
    av_frame_free(&frame);
    if (codecOpened) avcodec_close(codec);
    if (format) avformat_close_input(&format);
    if (ioContext) { av_free(ioContext->buffer); av_free(ioContext); }
    if (!_stop) {
        NSString *networkError = [_videoSource errorText];
        if (![networkError length]) networkError = [_audioSource errorText];
        if ([networkError length]) failure = networkError;
        else if (audio.failed) failure = [NSString stringWithFormat:@"AAC playback stopped (%ld).", (long)audio.error];
    }
    NSString *message = failure ? failure : @"Finished.";
    [self performSelectorOnMainThread:@selector(workerFinished:) withObject:message waitUntilDone:NO];
    [pool release];
}
- (void)dealloc {
    [_controlsTimer invalidate]; [_controlsTimer release];
    [_streams release]; [_surface release]; [_message release]; [_spinner release];
    [_elapsedLabel release]; [_durationLabel release]; [_topBar release]; [_transportBar release];
    [_playItem release]; [_fitItem release]; [_bottomControls release]; [_progress release]; [_volume release];
    [super dealloc];
}
@end
