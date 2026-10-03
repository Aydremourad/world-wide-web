#import <Foundation/Foundation.h>
#include <stdint.h>

// A bounded range reader shared by FFmpeg and Audio File Services.
// It never downloads or converts a complete movie before playback.
@interface YTMediaSource : NSObject {
    NSURL *_url;
    int _localFD;
    NSString *_userAgent;
    int64_t _length;
    NSInteger _rangeMode;
    NSMutableDictionary *_chunks;
    NSMutableArray *_order;
    NSCondition *_cacheLock;
    NSMutableSet *_inflight;
    NSUInteger _chunkBytes;
    NSTimeInterval _requestTimeout;
    NSString *_errorText;
    volatile BOOL _cancelled;
}
- (id)initWithURL:(NSURL *)url length:(int64_t)length userAgent:(NSString *)userAgent;
- (int)readAtOffset:(int64_t)offset into:(void *)buffer count:(int)count;
- (int64_t)length;
- (NSString *)errorText;
- (void)cancel;
- (void)shareCacheWithSource:(YTMediaSource *)source;
- (void)enableStreamingReadAhead;
- (void)setRequestTimeout:(NSTimeInterval)seconds;
- (YTMediaSource *)newReader;
@end
