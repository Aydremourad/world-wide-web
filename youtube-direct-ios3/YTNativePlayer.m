#import "YTNativePlayer.h"
#import "YTLoopbackServer.h"
#import "YTPlaybackLog.h"
#import <MediaPlayer/MediaPlayer.h>

@implementation YTNativePlayer
- (id)initWithStreams:(NSDictionary *)streams delegate:(id<YTNativePlayerDelegate>)delegate {
    if((self=[super init])) { _streams=[streams retain]; _delegate=delegate; }
    return self;
}
- (NSDictionary *)streams { return _streams; }
- (NSString *)errorText { return _errorText; }
- (void)recordEvent:(NSString *)event info:(NSDictionary *)info {
    NSDictionary *nativeInfo=[_streams objectForKey:@"nativeInfo"];
    NSString *detail=[NSString stringWithFormat:
        @"%@\nApple %@ (%.1fs)\npreloaded=%@\nnotification=%@\nbridge=%@\nnativeInfo=%@\n",
        YTReadPlaybackLog() ? YTReadPlaybackLog() : @"",event,
        [NSDate timeIntervalSinceReferenceDate]-_openedAt,_preloaded ? @"yes" : @"no",
        info ? info : [NSDictionary dictionary],[_server diagnosticText],
        nativeInfo ? nativeInfo : [NSDictionary dictionary]];
    YTWritePlaybackLog(detail);
}
- (BOOL)play {
    _openedAt=[NSDate timeIntervalSinceReferenceDate];
    NSDictionary *info=[_streams objectForKey:@"nativeInfo"];
    int64_t length=[[info objectForKey:@"length"] longLongValue];
    if(length<=0) length=[[_streams objectForKey:@"videoLength"] longLongValue];
    _server=[[YTLoopbackServer alloc] initWithURL:[_streams objectForKey:@"videoURL"]
        length:length userAgent:[_streams objectForKey:@"userAgent"]];
    if(![_server start]) {
        _errorText=[([[_server errorText] length] ? [_server errorText] : @"Could not start the video bridge.") copy];
        [self recordEvent:@"bridge startup failed" info:nil];
        return NO;
    }
    // iPhone OS 3 reports loading errors on ContentPreloadDidFinish, not the
    // finish-reason key introduced in the later MediaPlayer API. Initialization
    // starts preloading, so subscribe before allocating the movie controller.
    NSNotificationCenter *center=[NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(moviePreloaded:) name:MPMoviePlayerContentPreloadDidFinishNotification object:nil];
    [center addObserver:self selector:@selector(movieFinished:) name:MPMoviePlayerPlaybackDidFinishNotification object:nil];
    _opening=YES;
    _movie=[[MPMoviePlayerController alloc] initWithContentURL:[_server movieURL]];
    _opening=NO;
    if(!_movie) {
        _errorText=[@"Apple could not create the movie player." copy];
        [self recordEvent:@"initialization failed" info:nil];
        [self stop]; return NO;
    }
    _movie.scalingMode=MPMovieScalingModeAspectFit;
    [self recordEvent:@"opening" info:nil];
    // Defer legacy play until the next main-loop turn, after the resolver and
    // controller have finished handing off ownership. OS 3 preloads at init;
    // prepareToPlay is a newer API and is deliberately not part of this path.
    [self performSelector:@selector(startMovie) withObject:nil afterDelay:0.0];
    return YES;
}
- (void)startMovie { if(!_finished && !_finishPending) [_movie play]; }
- (BOOL)isOurNotification:(NSNotification *)notification {
    id object=[notification object];
    return !_finished && (_opening || !object || object==_movie);
}
- (void)scheduleFinish {
    if(_finishPending || _finished) return;
    _finishPending=YES;
    // A preload callback can arrive inside init/play. Do not release the owner
    // or stop MediaPlayer from inside its own initialization stack.
    [self performSelector:@selector(finishMovie) withObject:nil afterDelay:0.0];
}
- (void)moviePreloaded:(NSNotification *)notification {
    if(![self isOurNotification:notification]) return;
    NSDictionary *info=[notification userInfo];
    id error=[info objectForKey:@"error"];
    if([error isKindOfClass:[NSError class]]) {
        [_preloadError release]; _preloadError=[error retain];
        [self recordEvent:@"preload failed" info:info];
        [self scheduleFinish];
    } else {
        _preloaded=YES;
        [self recordEvent:@"preload succeeded" info:info];
    }
}
- (void)movieFinished:(NSNotification *)notification {
    if(![self isOurNotification:notification]) return;
    [_finishInfo release]; _finishInfo=[[notification userInfo] copy];
    // Record even an empty OS 3 notification; previously it disappeared as a
    // supposedly normal finish and there was no diagnostic at all.
    [self recordEvent:@"finished" info:_finishInfo];
    [self scheduleFinish];
}
- (void)finishMovie {
    if(_finished) return;
    [self retain];
    NSNumber *reason=[_finishInfo objectForKey:@"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey"];
    id error=[_finishInfo objectForKey:@"error"];
    NSError *movieError=[error isKindOfClass:[NSError class]] ? error : _preloadError;
    // With the old API, closing before a successful preload has no modern
    // reason value. It must not masquerade as a completed movie.
    BOOL failed=[[_server errorText] length]>0 || movieError ||
        (reason && [reason intValue]==2) || (!reason && !_preloaded);
    if(failed) {
        NSString *message=movieError ? [movieError localizedDescription] :
            ([[_server errorText] length] ? [_server errorText] : @"Apple's player closed before the movie finished loading.");
        [_errorText release]; _errorText=[message copy];
        [self recordEvent:@"failed" info:[NSDictionary dictionaryWithObject:message forKey:@"error"]];
    }
    [self stop]; [_delegate nativePlayer:self finishedWithError:failed];
    [self release];
}
- (void)stop {
    _finished=YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_movie stop]; [_server stop];
}
- (void)dealloc {
    [self stop]; [_movie release]; [_server release]; [_streams release];
    [_preloadError release]; [_finishInfo release]; [_errorText release]; [super dealloc];
}
@end
