#import <Foundation/Foundation.h>

@interface YTHLSBridge : NSObject {
    NSURL *_masterURL;
    NSString *_userAgent;
    NSArray *_segments;
    NSArray *_durations;
    NSString *_playlist;
    NSString *_cacheDir;
    NSString *_errorText;
    NSLock *_lock;
    int _listener;
    unsigned short _port;
    volatile BOOL _stopped;
}
- (id)initWithURL:(NSURL *)url userAgent:(NSString *)userAgent;
- (BOOL)start;
- (NSURL *)movieURL;
- (void)stop;
- (NSString *)errorText;
@end
