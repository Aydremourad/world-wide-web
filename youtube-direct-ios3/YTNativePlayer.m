#import "YTNativePlayer.h"
#import "YTLoopbackServer.h"
#import <MediaPlayer/MediaPlayer.h>
@implementation YTNativePlayer
- (id)initWithStreams:(NSDictionary *)streams delegate:(id<YTNativePlayerDelegate>)delegate {
    if((self=[super init])) { _streams=[streams retain]; _delegate=delegate; }
    return self;
}
- (NSDictionary *)streams { return _streams; }
- (BOOL)play {
    NSDictionary *info=[_streams objectForKey:@"nativeInfo"];
    _server=[[YTLoopbackServer alloc] initWithURL:[_streams objectForKey:@"videoURL"]
        length:[[info objectForKey:@"length"] longLongValue] userAgent:[_streams objectForKey:@"userAgent"]];
    if(![_server start]) return NO;
    _movie=[[MPMoviePlayerController alloc] initWithContentURL:[_server movieURL]];
    if(!_movie) { [_server stop]; return NO; }
    _movie.scalingMode=MPMovieScalingModeAspectFit;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(movieFinished:) name:MPMoviePlayerPlaybackDidFinishNotification object:_movie];
    [_movie play]; // iPhone OS 3 presents Apple's own full-screen controller.
    return YES;
}
- (void)movieFinished:(NSNotification *)notification {
    if(_finished) return;
    [self retain];
    NSDictionary *info=[notification userInfo];
    NSNumber *reason=[info objectForKey:@"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey"];
    BOOL failed=[[_server errorText] length]>0 || (reason && [reason intValue]==2) || [[info objectForKey:@"error"] isKindOfClass:[NSError class]];
    [self stop]; [_delegate nativePlayer:self finishedWithError:failed];
    [self release];
}
- (void)stop {
    _finished=YES; [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_movie stop]; [_server stop];
}
- (void)dealloc { [self stop]; [_movie release]; [_server release]; [_streams release]; [super dealloc]; }
@end
