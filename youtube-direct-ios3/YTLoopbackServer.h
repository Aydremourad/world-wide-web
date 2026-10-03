#import <Foundation/Foundation.h>
@class YTMediaSource;
@interface YTLoopbackServer : NSObject {
    NSURL *_upstream;
    NSString *_userAgent, *_errorText;
    int64_t _length;
    NSLock *_lock;
    NSMutableDictionary *_clients;
    YTMediaSource *_sharedSource;
    int _listener;
    unsigned short _port;
    unsigned _requestCount, _rangeRequestCount;
    unsigned long long _bytesServed;
    volatile BOOL _stopped;
}
- (id)initWithURL:(NSURL *)url length:(int64_t)length userAgent:(NSString *)userAgent;
- (BOOL)start;
- (NSURL *)movieURL;
- (void)stop;
- (NSString *)errorText;
- (NSString *)diagnosticText;
@end
