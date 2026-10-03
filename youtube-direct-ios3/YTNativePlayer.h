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
}
- (id)initWithStreams:(NSDictionary *)streams delegate:(id<YTNativePlayerDelegate>)delegate;
- (BOOL)play;
- (void)stop;
- (NSDictionary *)streams;
@end
