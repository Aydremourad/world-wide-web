#import <Foundation/Foundation.h>

@protocol YTHLSSequentialReading <NSObject>
- (int)readInto:(void *)buffer count:(int)count;
- (void)cancel;
- (NSString *)errorText;
@end

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
    NSInteger _selectedWidth;
    NSInteger _selectedHeight;
    double _selectedFPS;
    BOOL _selectedBaseline;
    NSTimeInterval _prepareDeadline;
}
- (id)initWithURL:(NSURL *)url userAgent:(NSString *)userAgent;
- (BOOL)start;
- (NSURL *)movieURL;
- (void)stop;
- (NSString *)errorText;
- (NSInteger)selectedHeight;
- (double)selectedFPS;
- (NSString *)selectedDescription;
- (BOOL)selectedBaseline;
- (double)totalDuration;
- (id<YTHLSSequentialReading>)newSequentialReaderAtTime:(double)time actualStart:(double *)actualStart;
@end
