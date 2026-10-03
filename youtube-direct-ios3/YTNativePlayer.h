#import <Foundation/Foundation.h>
@class MPMoviePlayerController,YTLoopbackServer,YTNativePlayer;
@protocol YTNativePlayerDelegate
- (void)nativePlayer:(YTNativePlayer *)player finishedWithError:(BOOL)failed;
@end
@interface YTNativePlayer : NSObject {
    MPMoviePlayerController *_movie;
    YTLoopbackServer *_server;
    NSDictionary *_streams;
    id<YTNativePlayerDelegate> _delegate;
    BOOL _finished;
    BOOL _opening;
    BOOL _preloaded;
    BOOL _finishPending;
    NSTimeInterval _openedAt;
    NSError *_preloadError;
    NSDictionary *_finishInfo;
    NSString *_errorText;
}
- (id)initWithStreams:(NSDictionary *)streams delegate:(id<YTNativePlayerDelegate>)delegate;
- (BOOL)play;
- (void)stop;
- (NSDictionary *)streams;
- (NSString *)errorText;
@end
