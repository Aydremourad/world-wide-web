#import <Foundation/Foundation.h>
typedef enum { MPMovieScalingModeAspectFit=1 } MPMovieScalingMode;
extern NSString *const MPMoviePlayerContentPreloadDidFinishNotification;
extern NSString *const MPMoviePlayerPlaybackDidFinishNotification;
@interface MPMoviePlayerController : NSObject {
    NSURL *_url;
    MPMovieScalingMode _scalingMode;
}
@property(nonatomic) MPMovieScalingMode scalingMode;
- (id)initWithContentURL:(NSURL *)url;
- (void)play;
- (void)stop;
@end
