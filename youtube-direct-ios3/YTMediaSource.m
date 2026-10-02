#import "YTMediaSource.h"
#include <string.h>

#define YT_CHUNK_BYTES (64 * 1024)
#define YT_CACHED_CHUNKS 8

@interface YTBoundedRequest : NSObject {
@public
    NSMutableData *data;
    NSString *error;
    NSURLConnection *connection;
    BOOL done;
    NSInteger status;
    NSUInteger limit;
    int64_t expectedOffset;
    volatile BOOL *cancelled;
}
- (void)fail:(NSString *)message;
@end

@implementation YTBoundedRequest
- (id)init {
    if ((self = [super init])) data = [[NSMutableData alloc] init];
    return self;
}
- (void)fail:(NSString *)message {
    if (!error) error = [message copy];
    done = YES;
    [connection cancel];
}
- (void)connection:(NSURLConnection *)sender didReceiveResponse:(NSURLResponse *)response {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        [self fail:@"The media server did not return an HTTP response."];
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    status = [http statusCode];
    if (status != 200 && status != 206) {
        [self fail:[NSString stringWithFormat:@"Video server returned HTTP %d.", (int)status]];
        return;
    }
    NSString *type = [response MIMEType];
    if ([type length] && ![type hasPrefix:@"video/"] && ![type hasPrefix:@"audio/"] &&
        ![type isEqualToString:@"application/octet-stream"]) {
        [self fail:[NSString stringWithFormat:@"Video server returned %@ instead of media.", type]];
        return;
    }
    long long receivedLength = [response expectedContentLength];
    if (receivedLength > (long long)limit) {
        [self fail:@"The media server ignored the requested byte range."];
        return;
    }
    if (status == 206) {
        NSString *range = nil;
        NSDictionary *headers = [http allHeaderFields];
        for (NSString *key in headers) {
            if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame)
                range = [headers objectForKey:key];
        }
        if ([range length]) {
            NSScanner *scan = [NSScanner scannerWithString:range];
            long long start = -1;
            if (![scan scanString:@"bytes" intoString:NULL] ||
                ![scan scanLongLong:&start] || start != expectedOffset) {
                [self fail:@"The media server returned the wrong byte range."];
            }
        }
    }
}
- (void)connection:(NSURLConnection *)sender didReceiveData:(NSData *)bytes {
    if (done) return;
    if ((cancelled && *cancelled) || [data length] + [bytes length] > limit) {
        [self fail:(cancelled && *cancelled) ? @"Playback cancelled." :
                    @"The media response exceeded the requested chunk size."];
        return;
    }
    [data appendData:bytes];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)sender { done = YES; }
- (void)connection:(NSURLConnection *)sender didFailWithError:(NSError *)failure {
    [self fail:[failure localizedDescription]];
}
- (void)dealloc {
    [connection cancel];
    [connection release];
    [data release];
    [error release];
    [super dealloc];
}
@end

@implementation YTMediaSource
- (id)initWithURL:(NSURL *)url length:(int64_t)length userAgent:(NSString *)userAgent {
    if ((self = [super init])) {
        _url = [url retain];
        _length = length;
        _userAgent = [userAgent copy];
        _chunks = [[NSMutableDictionary alloc] init];
        _order = [[NSMutableArray alloc] init];
    }
    return self;
}
- (int64_t)length { return _length; }
- (NSString *)errorText { return _errorText; }
- (void)cancel { _cancelled = YES; }

- (NSData *)chunkAt:(int64_t)start {
    NSNumber *key = [NSNumber numberWithLongLong:start];
    NSData *cached = [_chunks objectForKey:key];
    if (cached) {
        [_order removeObject:key];
        [_order addObject:key];
        return cached;
    }
    if (_cancelled || start >= _length || _length <= 0) return nil;
    int64_t end = start + YT_CHUNK_BYTES - 1;
    if (end >= _length) end = _length - 1;
    NSUInteger count = (NSUInteger)(end - start + 1);

    // Googlevideo accepts the range in the query as well as the HTTP header.
    // The query avoids receiving an entire file from Android media endpoints.
    NSString *address = [_url absoluteString];
    NSRange question = [address rangeOfString:@"?"];
    if (question.location != NSNotFound) {
        NSString *base = [address substringToIndex:question.location];
        NSArray *parts = [[address substringFromIndex:question.location + 1]
                          componentsSeparatedByString:@"&"];
        NSMutableArray *kept = [NSMutableArray array];
        for (NSString *part in parts)
            if (![part hasPrefix:@"range="]) [kept addObject:part];
        address = [NSString stringWithFormat:@"%@?%@", base,
                   [kept componentsJoinedByString:@"&"]];
    }
    NSString *separator = [address rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
    NSString *range = [NSString stringWithFormat:@"%lld-%lld", (long long)start, (long long)end];
    NSURL *rangeURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@range=%@",
                                           address, separator, range]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:rangeURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
    [request setValue:[@"bytes=" stringByAppendingString:range] forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if ([_userAgent length]) [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];

    NSData *result = nil;
    NSString *lastError = nil;
    for (NSUInteger attempt = 0; attempt < 2 && !_cancelled; attempt++) {
        YTBoundedRequest *transfer = [[YTBoundedRequest alloc] init];
        transfer->limit = count;
        transfer->expectedOffset = start;
        transfer->cancelled = &_cancelled;
        transfer->connection = [[NSURLConnection alloc] initWithRequest:request delegate:transfer];
        if (!transfer->connection) [transfer fail:@"Could not start the media request."];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:13.0];
        while (!transfer->done && !_cancelled && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!transfer->done) [transfer fail:_cancelled ? @"Playback cancelled." : @"Media request timed out."];
        if (!transfer->error && [transfer->data length] == count) {
            result = [[transfer->data copy] autorelease];
            [transfer release];
            break;
        }
        lastError = [[(transfer->error ? transfer->error : @"The media chunk was incomplete.") copy] autorelease];
        NSInteger code = transfer->status;
        [transfer release];
        if (code == 403 || code == 404 || code == 410) break;
    }
    if (!result) {
        [_errorText release];
        _errorText = [(lastError ? lastError : @"Playback cancelled.") copy];
        return nil;
    }
    [_chunks setObject:result forKey:key];
    [_order addObject:key];
    while ([_order count] > YT_CACHED_CHUNKS) {
        NSNumber *old = [_order objectAtIndex:0];
        [_chunks removeObjectForKey:old];
        [_order removeObjectAtIndex:0];
    }
    return result;
}
- (int)readAtOffset:(int64_t)offset into:(void *)buffer count:(int)count {
    if (_cancelled || offset < 0 || _length <= 0 || count < 0) return -1;
    if (offset >= _length || !count) return 0;
    int copied = 0;
    while (copied < count && offset < _length && !_cancelled) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        int64_t start = (offset / YT_CHUNK_BYTES) * YT_CHUNK_BYTES;
        NSData *chunk = [self chunkAt:start];
        if (!chunk) { [pool release]; return -1; }
        NSUInteger inside = (NSUInteger)(offset - start);
        NSUInteger available = [chunk length] - inside;
        NSUInteger wanted = (NSUInteger)(count - copied);
        NSUInteger bytes = available < wanted ? available : wanted;
        if (!bytes) { [pool release]; return -1; }
        memcpy((uint8_t *)buffer + copied, (const uint8_t *)[chunk bytes] + inside, bytes);
        copied += (int)bytes;
        offset += (int64_t)bytes;
        [pool release];
    }
    return _cancelled ? -1 : copied;
}
- (void)dealloc {
    [_url release]; [_userAgent release]; [_chunks release]; [_order release]; [_errorText release];
    [super dealloc];
}
@end
