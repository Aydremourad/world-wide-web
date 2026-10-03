#import "YTMediaSource.h"
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define YT_CHUNK_BYTES (64 * 1024)
#define YT_CACHE_BYTES (1024 * 1024)

@interface YTBoundedRequest : NSObject {
@public
    NSMutableData *data;
    NSString *error;
    NSURLConnection *connection;
    BOOL done;
    NSInteger status;
    NSUInteger limit;
    int64_t expectedOffset;
    int64_t expectedLength;
    int64_t totalLength;
    NSUInteger responseBytes;
    BOOL queryRange;
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
    NSString *range = nil;
    for (NSString *key in [http allHeaderFields])
        if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame)
            range = [[http allHeaderFields] objectForKey:key];
    if (status == 416) {
        if ([range hasPrefix:@"bytes */"]) totalLength = [[range substringFromIndex:8] longLongValue];
        [self fail:[NSString stringWithFormat:@"HTTP 416 for bytes %lld-%lld (file %lld; %@ range).",
            (long long)expectedOffset, (long long)(expectedOffset + limit - 1),
            (long long)expectedLength, queryRange ? @"URL" : @"header"]];
        return;
    }
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
    if ([range length]) {
        NSScanner *scan = [NSScanner scannerWithString:range];
        long long first = -1, last = -1, total = -1;
        if (![scan scanString:@"bytes" intoString:NULL] || ![scan scanLongLong:&first] ||
            ![scan scanString:@"-" intoString:NULL] || ![scan scanLongLong:&last] ||
            ![scan scanString:@"/" intoString:NULL] || ![scan scanLongLong:&total] ||
            first != expectedOffset || last < first || last - first + 1 > (long long)limit || total <= last) {
            [self fail:@"The media server returned the wrong byte range."]; return;
        }
        totalLength = total;
        responseBytes = (NSUInteger)(last - first + 1);
    } else if (!queryRange && (status == 206 || expectedOffset > 0)) {
        [self fail:@"The media server omitted the requested Content-Range."];
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

@interface YTMediaSource ()
- (NSData *)loadChunkAt:(int64_t)start;
@end

@implementation YTMediaSource
- (id)initWithURL:(NSURL *)url length:(int64_t)length userAgent:(NSString *)userAgent {
    if ((self = [super init])) {
        _localFD=-1;
        _url = [url retain];
        _length = length;
        if([url isFileURL]) {
            _localFD=open([[url path] fileSystemRepresentation],O_RDONLY);
            struct stat info; if(_localFD>=0 && fstat(_localFD,&info)==0) _length=info.st_size;
        }
        _userAgent = [userAgent copy];
        _chunks = [[NSMutableDictionary alloc] init];
        _order = [[NSMutableArray alloc] init];
        _cacheLock = [[NSCondition alloc] init];
        _inflight = [[NSMutableSet alloc] init];
        _chunkBytes = YT_CHUNK_BYTES;
        _requestTimeout=12.0;
    }
    return self;
}
- (int64_t)length { return _length; }
- (NSString *)errorText { return _errorText; }
- (void)cancel { _cancelled = YES; }
- (YTMediaSource *)newReader {
    YTMediaSource *reader=[[YTMediaSource alloc] initWithURL:_url length:_length userAgent:_userAgent];
    [reader shareCacheWithSource:self];
    reader->_rangeMode=_rangeMode; reader->_requestTimeout=_requestTimeout;
    return reader;
}

- (void)shareCacheWithSource:(YTMediaSource *)source {
    // Attach before either reader starts. File positions and errors remain independent.
    if (!source || source==self || ![_url isEqual:source->_url]) return;
    [_chunks release]; _chunks=[source->_chunks retain];
    [_order release]; _order=[source->_order retain];
    [_cacheLock release]; _cacheLock=[source->_cacheLock retain];
    [_inflight release]; _inflight=[source->_inflight retain];
    _chunkBytes=source->_chunkBytes;
}
- (void)setRequestTimeout:(NSTimeInterval)seconds { _requestTimeout=seconds<1 ? 1 : seconds>12 ? 12 : seconds; }
- (void)enableStreamingReadAhead {
    // Configure before playback readers start. Four larger requests per MiB
    // avoid a new HTTPS exchange for every 64 KiB while keeping the same cap.
    [_cacheLock lock];
    if(!_inflight.count && _chunkBytes!=262144) {
        _chunkBytes=262144; [_chunks removeAllObjects]; [_order removeAllObjects];
    }
    [_cacheLock unlock];
}
- (NSData *)chunkAt:(int64_t)start {
    NSNumber *key=[NSNumber numberWithLongLong:start];
    [_cacheLock lock];
    while(!_cancelled) {
        NSData *cached=[_chunks objectForKey:key];
        if(cached) {
            [cached retain]; [_order removeObject:key]; [_order addObject:key];
            [_cacheLock unlock]; return [cached autorelease];
        }
        if(![_inflight containsObject:key]) break;
        [_cacheLock waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if(_cancelled) { [_cacheLock unlock]; return nil; }
    [_inflight addObject:key]; [_cacheLock unlock];
    // Never hold the shared cache lock during DNS, TLS or a network download.
    // Cached audio and unrelated chunks remain readable while video is slow.
    NSData *result=[[self loadChunkAt:start] retain];
    [_cacheLock lock];
    if(result) {
        [_chunks setObject:result forKey:key]; [_order removeObject:key]; [_order addObject:key];
        while([_order count]>YT_CACHE_BYTES/_chunkBytes) {
            NSNumber *old=[_order objectAtIndex:0]; [_chunks removeObjectForKey:old]; [_order removeObjectAtIndex:0];
        }
    }
    [_inflight removeObject:key]; [_cacheLock broadcast]; [_cacheLock unlock];
    return [result autorelease];
}
- (NSData *)loadChunkAt:(int64_t)start {
    if (_cancelled || start >= _length || _length <= 0) return nil;
    // Never send both selectors: a server may first slice the URL range and
    // then apply the HTTP range to that slice, causing 416 after the first chunk.
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
    NSData *result = nil;
    NSString *lastError = nil;
    NSInteger mode = _rangeMode;
    NSUInteger selectorAttempts = 0;
    BOOL retriedLength = NO;
    for (NSUInteger attempt = 0; attempt < 3 && !_cancelled; attempt++) {
        if (start >= _length) break;
        int64_t end = start + _chunkBytes - 1;
        if (end >= _length) end = _length - 1;
        NSUInteger count = (NSUInteger)(end - start + 1);
        NSString *range = [NSString stringWithFormat:@"%lld-%lld", (long long)start, (long long)end];
        NSString *requestAddress = address;
        if (mode == 1) {
            NSString *separator = [address rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
            requestAddress = [NSString stringWithFormat:@"%@%@range=%@", address, separator, range];
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:requestAddress]
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:_requestTimeout];
        if (mode == 0) [request setValue:[@"bytes=" stringByAppendingString:range] forHTTPHeaderField:@"Range"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        if ([_userAgent length]) [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
        YTBoundedRequest *transfer = [[YTBoundedRequest alloc] init];
        transfer->limit = count;
        transfer->responseBytes = count;
        transfer->expectedOffset = start;
        transfer->expectedLength = _length;
        transfer->queryRange = mode == 1;
        transfer->cancelled = &_cancelled;
        transfer->connection = [[NSURLConnection alloc] initWithRequest:request delegate:transfer];
        if (!transfer->connection) [transfer fail:@"Could not start the media request."];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:_requestTimeout+1.0];
        while (!transfer->done && !_cancelled && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!transfer->done) [transfer fail:_cancelled ? @"Playback cancelled." : @"Media request timed out."];
        if (!transfer->error && [transfer->data length] == transfer->responseBytes) {
            if (transfer->totalLength > 0 && transfer->totalLength != _length) {
                _length = transfer->totalLength;
            }
            result = [[transfer->data copy] autorelease];
            _rangeMode = mode;
            [transfer release];
            break;
        }
        lastError = [[(transfer->error ? transfer->error : @"The media chunk was incomplete.") copy] autorelease];
        NSInteger code = transfer->status;
        long long actualLength = transfer->totalLength;
        [transfer release];
        if (code == 403 || code == 404 || code == 410) break;
        if (code == 416 && actualLength > 0 && actualLength != _length && !retriedLength) {
            _length = actualLength;
            retriedLength = YES;
            if (start >= _length) {
                [_errorText release]; _errorText = nil;
                return nil;
            }
            continue;
        }
        if (++selectorAttempts >= 2) break;
        mode = 1 - mode;
    }
    if (!result) {
        [_errorText release];
        _errorText = [(lastError ? lastError : @"Playback cancelled.") copy];
        return nil;
    }
    [_errorText release];
    _errorText = nil;
    return result;
}
- (int)readAtOffset:(int64_t)offset into:(void *)buffer count:(int)count {
    if (_cancelled || offset < 0 || _length <= 0 || count < 0) return -1;
    if (offset >= _length || !count) return 0;
    if([_url isFileURL]) {
        if(_localFD<0) return -1;
        int64_t remaining=_length-offset;
        if(count>remaining) count=(int)remaining;
        return (int)pread(_localFD,buffer,(size_t)count,(off_t)offset);
    }
    int copied = 0;
    while (copied < count && offset < _length && !_cancelled) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        int64_t start = (offset / _chunkBytes) * _chunkBytes;
        NSData *chunk = [self chunkAt:start];
        if (!chunk) {
            [pool release];
            return !_cancelled && offset >= _length && ![_errorText length] ? copied : -1;
        }
        NSUInteger inside = (NSUInteger)(offset - start);
        if (inside >= [chunk length]) {
            [pool release];
            return offset >= _length ? copied : -1;
        }
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
    if(_localFD>=0) close(_localFD);
    [_url release]; [_userAgent release]; [_chunks release]; [_order release]; [_cacheLock release]; [_inflight release]; [_errorText release];
    [super dealloc];
}
@end
