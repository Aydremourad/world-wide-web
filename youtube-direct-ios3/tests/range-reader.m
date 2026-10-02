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
    unsigned char byte;
    assert([Source(base, @"/ignore") readAtOffset:65536 into:&byte count:1] == -1);
    assert([Source(base, @"/wrong") readAtOffset:65536 into:&byte count:1] == -1);
    assert([Source(base, @"/short") readAtOffset:0 into:&byte count:1] == -1);
    YTMediaSource *slow = Source(base, @"/slow");
    [NSThread detachNewThreadSelector:@selector(cancelLater:) toTarget:[YTCanceller class] withObject:slow];
    NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
    assert([slow readAtOffset:0 into:&byte count:1] == -1);
    assert([NSDate timeIntervalSinceReferenceDate] - start < 1.0);
    NSLog(@"Range boundaries, random seeks, short responses, range rejection and cancellation passed.");
    [pool release];
    return 0;
}
