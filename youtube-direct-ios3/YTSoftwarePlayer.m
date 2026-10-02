#import "YTSoftwarePlayer.h"
#import "YTMediaSource.h"
#import "YTVideoSurface.h"
#import "YTAudioFile.h"
#import "YTAudioPump.h"
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
        return time.mSampleTime / playback->audio->format.mSampleRate;
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
    if (wait < -0.20) return YES; // Drop only the display, preserving H.264 reference frames.
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
    AudioSessionInitialize(NULL, NULL, NULL, NULL);
    UInt32 category = kAudioSessionCategory_MediaPlayback;
    AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
    AudioSessionSetActive(true);
    self.view.backgroundColor = [UIColor blackColor];
    _surface = [[YTVideoSurface alloc] initWithFrame:self.view.bounds];
    _surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_surface];
    _message = [[UILabel alloc] initWithFrame:CGRectMake(15, 70, self.view.bounds.size.width - 30, 110)];
    _message.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _message.backgroundColor = [UIColor clearColor];
    _message.textColor = [UIColor whiteColor];
    _message.textAlignment = UITextAlignmentCenter;
    _message.numberOfLines = 5;
    _message.text = @"Loading the first video chunks...";
    [self.view addSubview:_message];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    done.frame = CGRectMake(10, 10, 65, 35);
    [done setTitle:@"Done" forState:UIControlStateNormal];
    [done addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];
    _pauseButton = [[UIButton buttonWithType:UIButtonTypeRoundedRect] retain];
    _pauseButton.frame = CGRectMake(self.view.bounds.size.width - 85, 10, 75, 35);
    _pauseButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_pauseButton setTitle:@"Pause" forState:UIControlStateNormal];
    [_pauseButton addTarget:self action:@selector(togglePause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_pauseButton];
    [self retain]; // Released on the main thread after the playback worker exits.
    [NSThread detachNewThreadSelector:@selector(playThread:) toTarget:self withObject:nil];
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { return YES; }
- (void)togglePause {
    _paused = !_paused;
    [_pauseButton setTitle:_paused ? @"Resume" : @"Pause" forState:UIControlStateNormal];
}
- (void)close {
    _stop = YES;
    [_videoSource cancel]; [_audioSource cancel];
    [self dismissModalViewControllerAnimated:YES];
}
- (void)presentFrame:(NSDictionary *)frame {
    if (_stop) return;
    _message.hidden = YES;
    [_surface displayRGB565:[frame objectForKey:@"pixels"]
                     width:[[frame objectForKey:@"width"] intValue]
                    height:[[frame objectForKey:@"height"] intValue]];
}
- (void)setBuffering:(NSNumber *)value {
    if (_stop) return;
    _message.text = @"Buffering...";
    _message.hidden = ![value boolValue];
}
- (void)workerFinished:(NSString *)message {
    if (!_stop) {
        _message.text = message;
        _message.hidden = NO;
        _pauseButton.enabled = NO;
    }
    [_videoSource release]; _videoSource = nil;
    [_audioSource release]; _audioSource = nil;
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
    AVPacket packet;
    int readResult = 0;
    while (!_stop && !audio.failed && (readResult = av_read_frame(format, &packet)) >= 0) {
        if (packet.stream_index == videoStream) {
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
    NSString *message = failure ? failure : @"Finished. Tap Done to choose another video.";
    [self performSelectorOnMainThread:@selector(workerFinished:) withObject:message waitUntilDone:NO];
    [pool release];
}
- (void)dealloc {
    [_streams release]; [_surface release]; [_message release]; [_pauseButton release];
    [super dealloc];
}
@end
