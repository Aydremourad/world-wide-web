#import <Foundation/Foundation.h>
#include <stdint.h>

// A bounded range reader shared by FFmpeg and Audio File Services.
// It never downloads or converts a complete movie before playback.
@interface YTMediaSource : NSObject {
    NSURL *_url;
    NSString *_userAgent;
    int64_t _length;
    NSInteger _rangeMode;
    NSMutableDictionary *_chunks;
    NSMutableArray *_order;
    NSString *_errorText;
    volatile BOOL _cancelled;
}
- (id)initWithURL:(NSURL *)url length:(int64_t)length userAgent:(NSString *)userAgent;
- (int)readAtOffset:(int64_t)offset into:(void *)buffer count:(int)count;
- (int64_t)length;
- (NSString *)errorText;
- (void)cancel;
@end
