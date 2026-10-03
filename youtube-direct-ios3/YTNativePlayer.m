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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(movieFinished:) name:MPMoviePlayerPlaybackDidFinishNotification object:nil];
    // Apple's documentation separates initialization from preparation. On
    // legacy MediaPlayer builds this also gives the local range server a clean
    // preload phase before playback starts.
    if([_movie respondsToSelector:@selector(prepareToPlay)])
        [_movie performSelector:@selector(prepareToPlay)];
    [_movie play]; // iPhone OS 3 presents Apple's own full-screen controller.
    return YES;
}
- (void)movieFinished:(NSNotification *)notification {
    if(_finished) return;
    [self retain];
    NSDictionary *info=[notification userInfo];
    NSNumber *reason=[info objectForKey:@"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey"];
    NSError *movieError=[[info objectForKey:@"error"] isKindOfClass:[NSError class]] ? [info objectForKey:@"error"] : nil;
    BOOL failed=[[_server errorText] length]>0 || (reason && [reason intValue]==2) || movieError!=nil;
    if(failed) {
        NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTube-playback.txt"];
        NSString *old=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *nativeInfo=[_streams objectForKey:@"nativeInfo"];
        NSString *detail=[NSString stringWithFormat:
            @"%@\nApple player failure\nreason=%@\nerror=%@ (%@/%ld)\nbridge=%@\nnativeInfo=%@\n",
            old ? old : @"", reason ? reason : @"missing",
            movieError ? [movieError localizedDescription] : @"none",
            movieError ? [movieError domain] : @"none",(long)(movieError ? [movieError code] : 0),
            [_server diagnosticText],nativeInfo ? nativeInfo : [NSDictionary dictionary]];
        [detail writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    [self stop]; [_delegate nativePlayer:self finishedWithError:failed];
    [self release];
}
- (void)stop {
    _finished=YES; [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_movie stop]; [_server stop];
}
- (void)dealloc { [self stop]; [_movie release]; [_server release]; [_streams release]; [super dealloc]; }
@end
