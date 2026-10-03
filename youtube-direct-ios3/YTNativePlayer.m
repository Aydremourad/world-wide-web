#import "YTNativePlayer.h"
#import "YTLoopbackServer.h"
#import "YTHLSBridge.h"
#import <MediaPlayer/MediaPlayer.h>
@implementation YTNativePlayer
- (id)initWithStreams:(NSDictionary *)streams delegate:(id<YTNativePlayerDelegate>)delegate {
    if((self=[super init])) { _streams=[streams retain]; _delegate=delegate; }
    return self;
}
- (NSDictionary *)streams { return _streams; }
- (BOOL)play {
    NSURL *movieURL=nil;
    if([[_streams objectForKey:@"nativeHLS"] boolValue]) {
        // The resolver already validated and prebuffered this bridge off the
        // main thread. Keep it alive for the whole Apple-player session.
        _hlsBridge=[[_streams objectForKey:@"hlsBridge"] retain];
        if(!_hlsBridge) {
            _hlsBridge=[[YTHLSBridge alloc] initWithURL:[_streams objectForKey:@"hlsURL"]
                userAgent:[_streams objectForKey:@"userAgent"]];
            if(![_hlsBridge start]) return NO;
        }
        movieURL=[_hlsBridge movieURL];
    } else {
        NSDictionary *info=[_streams objectForKey:@"nativeInfo"];
        _server=[[YTLoopbackServer alloc] initWithURL:[_streams objectForKey:@"videoURL"]
            length:[[info objectForKey:@"length"] longLongValue] userAgent:[_streams objectForKey:@"userAgent"]];
        if(![_server start]) return NO;
        movieURL=[_server movieURL];
    }
    if(!movieURL) return NO;
    _movie=[[MPMoviePlayerController alloc] initWithContentURL:movieURL];
    if(!_movie) { [_server stop]; [_hlsBridge stop]; return NO; }
    _movie.scalingMode=MPMovieScalingModeAspectFit;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(movieFinished:)
        name:MPMoviePlayerPlaybackDidFinishNotification object:nil];
    [_movie play];
    return YES;
}
- (void)movieFinished:(NSNotification *)notification {
    if(_finished) return;
    [self retain];
    NSDictionary *info=[notification userInfo];
    NSNumber *reason=[info objectForKey:@"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey"];
    BOOL failed=[[_server errorText] length]>0 || [[_hlsBridge errorText] length]>0 ||
        // MPMovieFinishReasonPlaybackError is value 1; use the value directly
        // because the iPhoneOS 3.1.3 SDK does not expose every later MediaPlayer symbol.
        (reason && [reason intValue]==1) ||
        [[info objectForKey:@"error"] isKindOfClass:[NSError class]];
    [self stop]; [_delegate nativePlayer:self finishedWithError:failed];
    [self release];
}
- (void)stop {
    _finished=YES; [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_movie stop]; [_server stop]; [_hlsBridge stop];
}
- (void)dealloc {
    [self stop];
    [_movie release]; [_server release]; [_hlsBridge release]; [_streams release];
    [super dealloc];
}
@end
