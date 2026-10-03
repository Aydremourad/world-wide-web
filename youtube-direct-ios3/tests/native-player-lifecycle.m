#import "YTNativePlayer.h"
#import "YTLoopbackServer.h"
#import "YTPlaybackLog.h"
#import <MediaPlayer/MediaPlayer.h>
#include <assert.h>
NSString *const MPMoviePlayerContentPreloadDidFinishNotification=@"preload";
NSString *const MPMoviePlayerPlaybackDidFinishNotification=@"finish";
static int Mode,Plays;
static BOOL BridgeFails;
@implementation MPMoviePlayerController
@synthesize scalingMode=_scalingMode;
- (id)initWithContentURL:(NSURL *)url {
    if((self=[super init])) {
        _url=[url retain];
        if(Mode==1 || Mode==2) {
            NSDictionary *info=Mode==2 ? [NSDictionary dictionaryWithObject:
                [NSError errorWithDomain:@"legacy" code:42 userInfo:
                    [NSDictionary dictionaryWithObject:@"Old player rejected movie" forKey:NSLocalizedDescriptionKey]] forKey:@"error"] : nil;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"preload" object:self userInfo:info];
        }
    }
    return self;
}
- (void)play {
    Plays++;
    if(Mode==3) [[NSNotificationCenter defaultCenter] postNotificationName:@"finish" object:self];
}
- (void)stop { }
- (void)dealloc { [_url release]; [super dealloc]; }
@end
@implementation YTLoopbackServer
- (id)initWithURL:(NSURL *)url length:(int64_t)length userAgent:(NSString *)userAgent { return [super init]; }
- (BOOL)start { return !BridgeFails; }
- (NSURL *)movieURL { return [NSURL URLWithString:@"http://127.0.0.1:1234/movie.mp4"]; }
- (NSString *)errorText { return BridgeFails ? @"CDN unavailable" : nil; }
- (NSString *)diagnosticText { return @"requests=2 ranges=2 bytes=100 length=100 upstream=none"; }
- (void)stop { }
@end
@interface Probe : NSObject <YTNativePlayerDelegate> {
@public YTNativePlayer *player; int calls; BOOL failed;
}
- (void)open;
@end
@implementation Probe
- (void)open {
    YTWritePlaybackLog(@"Version lifecycle-test");
    NSDictionary *streams=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSURL URLWithString:@"https://example.test/movie.mp4"],@"videoURL",
        [NSNumber numberWithLongLong:100],@"videoLength",nil];
    player=[[YTNativePlayer alloc] initWithStreams:streams delegate:self];
    assert([player play]);
}
- (void)nativePlayer:(YTNativePlayer *)sender finishedWithError:(BOOL)error {
    assert(sender==player); calls++; failed=error;
    [player release]; player=nil;
}
- (void)dealloc { [player stop]; [player release]; [super dealloc]; }
@end
static void Pump(void) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:0.05];
    while([end timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}
int main(void) {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    // OS 3 preload error can occur during init, before the ivar is assigned.
    Mode=2; Plays=0; Probe *p=[[Probe alloc] init]; [p open];
    assert(p->calls==0); Pump(); assert(p->calls==1 && p->failed && Plays==0);
    assert([YTReadPlaybackLog() rangeOfString:@"Old player rejected movie"].location!=NSNotFound);
    [p release];
    // Real failure case: empty finish dictionary and no successful preload.
    Mode=3; p=[[Probe alloc] init]; [p open]; Pump();
    assert(p->calls==1 && p->failed);
    assert([YTReadPlaybackLog() rangeOfString:@"preloaded=no"].location!=NSNotFound);
    assert([YTReadPlaybackLog() rangeOfString:@"closed before"].location!=NSNotFound);
    [p release];
    // Empty legacy finish after preload success is a normal finish/Done.
    Mode=1; p=[[Probe alloc] init]; [p open]; Pump();
    NSObject *other=[[NSObject alloc] init];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"finish" object:other];
    Pump(); assert(p->calls==0); [other release];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"finish" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"finish" object:nil];
    Pump(); assert(p->calls==1 && !p->failed);
    assert([YTReadPlaybackLog() rangeOfString:@"Apple finished"].location!=NSNotFound);
    [p release];
    // Stop cancels deferred start and callbacks, including a queued failure.
    Mode=2; Plays=0; p=[[Probe alloc] init]; [p open]; [p->player stop]; Pump();
    assert(p->calls==0 && Plays==0); [p release];
    // The observed profile-77 movie is rejected before opening the bridge.
    NSDictionary *bad=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES],@"nativeCandidate",
        [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO] forKey:@"eligible"],@"nativeInfo",nil];
    YTNativePlayer *unsupported=[[YTNativePlayer alloc] initWithStreams:bad delegate:nil];
    assert(![unsupported play] && [[unsupported errorText] rangeOfString:@"codec is incompatible"].location!=NSNotFound);
    [unsupported release];
    BridgeFails=YES;
    YTNativePlayer *failed=[[YTNativePlayer alloc] initWithStreams:[NSDictionary dictionary] delegate:nil];
    assert(![failed play] && [[failed errorText] isEqualToString:@"CDN unavailable"]);
    assert([YTReadPlaybackLog() rangeOfString:@"bridge startup failed"].location!=NSNotFound);
    [failed release];
    // The Info report survives losing the temporary-file copy.
    [[NSFileManager defaultManager] removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTube-playback.txt"] error:NULL];
    assert([YTReadPlaybackLog() length]>0);
    NSLog(@"Native lifecycle passed: OS 3 preload errors, empty finish, success/Done, duplicate and unrelated notifications, deferred ownership, stop, bridge failure and durable report.");
    [pool release]; return 0;
}
