#import <Foundation/Foundation.h>
#import "YTMediaSource.h"
#include <assert.h>

@interface YTCanceller : NSObject
+ (void)cancelLater:(YTMediaSource *)source;
@end
@implementation YTCanceller
+ (void)cancelLater:(YTMediaSource *)source {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread sleepForTimeInterval:0.10];
    [source cancel];
    [pool release];
}
@end

static YTMediaSource *Source(NSString *base, NSString *path) {
    return [[[YTMediaSource alloc] initWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]
                                     length:262217 userAgent:@"range-fixture"] autorelease];
}
static void CheckRead(YTMediaSource *source, int offset, int requested, int expected) {
    unsigned char *bytes = malloc(requested);
    int actual = [source readAtOffset:offset into:bytes count:requested];
    assert(actual == expected);
    for (int i = 0; i < actual; i++) assert(bytes[i] == (offset + i) % 251);
    free(bytes);
}
int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    assert(argc == 2);
    NSString *base = [NSString stringWithUTF8String:argv[1]];
    YTMediaSource *source = Source(base, @"/media");
    CheckRead(source, 65000, 2000, 2000); // Cross a 64 KiB chunk boundary.
    CheckRead(source, 100, 1500, 1500); // Seek backward, including cached data.
    CheckRead(source, 262200, 100, 17); // The last range is shorter than one chunk.
    CheckRead(source, 262217, 100, 0);
    CheckRead(Source(base, @"/double"), 65000, 2000, 2000);
    CheckRead(Source(base, @"/header"), 65000, 2000, 2000);
    CheckRead(Source(base, @"/query"), 65000, 2000, 2000);
    CheckRead(Source(base, @"/switch"), 65000, 2000, 2000);
    YTMediaSource *oversized = [[[YTMediaSource alloc] initWithURL:
        [NSURL URLWithString:[base stringByAppendingString:@"/media"]]
        length:400000 userAgent:@"fixture"] autorelease];
    CheckRead(oversized, 262200, 100, 17);
    assert([oversized length] == 262217);
    YTMediaSource *strict = [[[YTMediaSource alloc] initWithURL:
        [NSURL URLWithString:[base stringByAppendingString:@"/strict"]]
        length:400000 userAgent:@"fixture"] autorelease];
    CheckRead(strict, 262200, 100, 17);
    assert([strict length] == 262217);
    YTMediaSource *beyond = [[[YTMediaSource alloc] initWithURL:
        [NSURL URLWithString:[base stringByAppendingString:@"/media"]]
        length:500000 userAgent:@"fixture"] autorelease];
    CheckRead(beyond, 400000, 100, 0);
    assert([beyond length] == 262217 && ![[beyond errorText] length]);
    unsigned char byte;
    assert([Source(base, @"/ignore") readAtOffset:65536 into:&byte count:1] == -1);
    assert([Source(base, @"/wrong") readAtOffset:65536 into:&byte count:1] == -1);
    assert([Source(base, @"/short") readAtOffset:0 into:&byte count:1] == -1);
    YTMediaSource *slow = Source(base, @"/slow");
    [NSThread detachNewThreadSelector:@selector(cancelLater:) toTarget:[YTCanceller class] withObject:slow];
    NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
    assert([slow readAtOffset:0 into:&byte count:1] == -1);
    assert([NSDate timeIntervalSinceReferenceDate] - start < 1.0);
    NSLog(@"Range checks passed: exclusive selectors, nonzero 416 fallback, corrected lengths, strict EOF limits, random seeks, invalid responses and cancellation.");
    [pool release];
    return 0;
}
