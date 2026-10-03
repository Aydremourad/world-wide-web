#import "YTHLSBridge.h"
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <limits.h>
#include <string.h>

static BOOL YTHLSSendBytes(int fd,const void *bytes,size_t count) {
    const char *p=bytes;
    while(count) {
#ifdef MSG_NOSIGNAL
        ssize_t sent=send(fd,p,count,MSG_NOSIGNAL);
#else
        ssize_t sent=send(fd,p,count,0);
#endif
        if(sent<0 && errno==EINTR) continue;
        if(sent<=0) return NO;
        p+=sent; count-=(size_t)sent;
    }
    return YES;
}
static BOOL YTHLSSendText(int fd,NSString *text) {
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
    return YTHLSSendBytes(fd,[data bytes],[data length]);
}
static NSURL *YTHLSResolveURL(NSString *text,NSURL *base) {
    NSURL *url=[NSURL URLWithString:text relativeToURL:base];
    return [url absoluteURL];
}
static NSString *YTHLSTrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
static void YTHLSResolution(NSString *line,NSInteger *width,NSInteger *height) {
    *width=*height=0;
    NSRange r=[line rangeOfString:@"RESOLUTION=" options:NSCaseInsensitiveSearch];
    if(r.location==NSNotFound) return;
    NSScanner *scan=[NSScanner scannerWithString:[line substringFromIndex:r.location+r.length]];
    NSInteger w=0,h=0;
    if([scan scanInteger:&w] && [scan scanString:@"x" intoString:NULL] && [scan scanInteger:&h]) {
        *width=w; *height=h;
    }
}
static double YTHLSFrameRate(NSString *line) {
    NSRange r=[line rangeOfString:@"FRAME-RATE=" options:NSCaseInsensitiveSearch];
    if(r.location==NSNotFound) return 0;
    NSScanner *scan=[NSScanner scannerWithString:[line substringFromIndex:r.location+r.length]];
    double fps=0; return [scan scanDouble:&fps] ? fps : 0;
}
static BOOL YTHLSLooksLikeTransportStream(NSData *data) {
    if([data length]<188*3) return NO;
    const uint8_t *p=[data bytes]; NSUInteger n=[data length];
    for(NSUInteger offset=0;offset<188 && offset+188*2<n;offset++)
        if(p[offset]==0x47 && p[offset+188]==0x47 && p[offset+376]==0x47) return YES;
    return NO;
}

@implementation YTHLSBridge

- (id)initWithURL:(NSURL *)url userAgent:(NSString *)userAgent {
    if((self=[super init])) {
        _masterURL=[url retain];
        _userAgent=[userAgent copy];
        _lock=[[NSLock alloc] init];
        _listener=-1;
    }
    return self;
}
- (void)setFailure:(NSString *)text {
    [_lock lock];
    [_errorText release];
    _errorText=[text copy];
    [_lock unlock];
}
- (NSString *)errorText {
    [_lock lock];
    NSString *text=[[_errorText copy] autorelease];
    [_lock unlock];
    return text;
}
- (NSInteger)selectedHeight { return _selectedHeight; }
- (double)selectedFPS { return _selectedFPS; }
- (NSString *)selectedDescription {
    if(_selectedWidth<=0 || _selectedHeight<=0) return nil;
    return [NSString stringWithFormat:@"Hardware HLS: %dx%d%@, H.264 Baseline + AAC, 3-segment prebuffer",
        (int)_selectedWidth,(int)_selectedHeight,_selectedFPS>0 ?
        [NSString stringWithFormat:@", %.1f fps",_selectedFPS] : @""];
}
- (NSData *)fetchURL:(NSURL *)url timeout:(NSTimeInterval)timeout {
    if(_stopped || !url) return nil;
    if(_prepareDeadline>0) {
        NSTimeInterval remaining=_prepareDeadline-[NSDate timeIntervalSinceReferenceDate];
        if(remaining<=0) { [self setFailure:@"The hardware HLS preparation exceeded 55 seconds."]; return nil; }
        if(timeout>remaining) timeout=remaining;
    }
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    [request setHTTPMethod:@"GET"];
    if([_userAgent length]) [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    NSURLResponse *response=nil; NSError *error=nil;
    NSData *data=[NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    NSInteger status=[response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if(!data || status<200 || status>=300) {
        [self setFailure:error ? [error localizedDescription] :
            [NSString stringWithFormat:@"HLS HTTP %d",(int)status]];
        return nil;
    }
    return data;
}
- (NSString *)fetchText:(NSURL *)url {
    NSData *data=[self fetchURL:url timeout:8.0];
    if(!data) return nil;
    NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if(!text) [self setFailure:@"YouTube returned an invalid HLS playlist."];
    return text;
}
- (NSURL *)mediaURLFromMaster:(NSString *)master {
    NSArray *lines=[master componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSURL *best=nil; long long bestScore=LLONG_MAX;
    NSInteger bestWidth=0,bestHeight=0; double bestFPS=0;
    for(NSUInteger i=0;i<[lines count];i++) {
        NSString *info=YTHLSTrim([lines objectAtIndex:i]);
        if(![info hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;
        NSString *lower=[info lowercaseString];
        // The original iPhone hardware path is the point of this route.
        // Reject Main-profile AVC and reject larger renditions even when they
        // happen to be Baseline. YouTube's compatible target is HLS itag 91:
        // 256x144 Baseline AVC with AAC in MPEG-TS.
        if([lower rangeOfString:@"avc1.42"].location==NSNotFound ||
           [lower rangeOfString:@"mp4a."].location==NSNotFound) continue;
        NSInteger width=0,height=0; YTHLSResolution(info,&width,&height);
        if(width<=0 || height<=0 || width>256 || height>144) continue;
        double fps=YTHLSFrameRate(info);
        long long score=(long long)width*height;
        NSString *address=nil;
        for(NSUInteger j=i+1;j<[lines count];j++) {
            NSString *candidate=YTHLSTrim([lines objectAtIndex:j]);
            if(![candidate length]) continue;
            if([candidate hasPrefix:@"#"]) break;
            address=candidate; break;
        }
        if(address && score<bestScore) {
            best=YTHLSResolveURL(address,_masterURL);
            bestScore=score; bestWidth=width; bestHeight=height; bestFPS=fps;
        }
    }
    if(best) { _selectedWidth=bestWidth; _selectedHeight=bestHeight; _selectedFPS=bestFPS; }
    return best;
}
- (BOOL)parseMediaPlaylist:(NSString *)media baseURL:(NSURL *)base {
    if([media rangeOfString:@"#EXT-X-MAP:"].location!=NSNotFound ||
       [media rangeOfString:@"#EXT-X-BYTERANGE:"].location!=NSNotFound ||
       [media rangeOfString:@"#EXT-X-KEY:"].location!=NSNotFound) {
        [self setFailure:@"This YouTube HLS rendition needs a newer HLS feature than iPhone OS 3 supports."];
        return NO;
    }
    NSArray *lines=[media componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *segments=[NSMutableArray array],*durations=[NSMutableArray array];
    double pending=0;
    for(NSString *raw in lines) {
        NSString *line=YTHLSTrim(raw);
        if([line hasPrefix:@"#EXTINF:"]) {
            NSString *tail=[line substringFromIndex:8];
            pending=[tail doubleValue];
            continue;
        }
        if(![line length] || [line hasPrefix:@"#"]) continue;
        if(pending<=0) continue;
        NSURL *url=YTHLSResolveURL(line,base);
        if(!url) continue;
        [segments addObject:url];
        [durations addObject:[NSNumber numberWithDouble:pending]];
        pending=0;
    }
    if(![segments count]) {
        [self setFailure:@"The YouTube HLS playlist contained no playable MPEG-TS segments."];
        return NO;
    }
    [_segments release]; _segments=[segments copy];
    [_durations release]; _durations=[durations copy];
    return YES;
}
- (NSString *)segmentPath:(NSUInteger)index {
    return [_cacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.ts",(unsigned long)index]];
}
- (NSData *)dataForSegment:(NSUInteger)index {
    if(index>=[_segments count]) return nil;
    NSString *path=[self segmentPath:index];
    NSData *cached=[NSData dataWithContentsOfFile:path];
    if(cached) return cached;
    NSData *data=[self fetchURL:[_segments objectAtIndex:index] timeout:20.0];
    if(data && !_stopped) [data writeToFile:path atomically:YES];
    return data;
}
- (BOOL)prebuffer {
    NSUInteger count=[_segments count]<3 ? [_segments count] : 3;
    for(NSUInteger i=0;i<count;i++) {
        NSData *data=[self dataForSegment:i];
        if(!data) return NO;
        if(i==0 && !YTHLSLooksLikeTransportStream(data)) {
            [self setFailure:@"The 144p HLS rendition was not MPEG-TS, so iPhone OS 3 cannot use it."];
            return NO;
        }
    }
    return YES;
}
- (void)prefetchThread:(id)unused {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    for(NSUInteger i=3;i<[_segments count] && !_stopped;i++) {
        NSAutoreleasePool *part=[[NSAutoreleasePool alloc] init];
        [self dataForSegment:i];
        [part release];
    }
    [pool release];
}
- (void)buildLocalPlaylist {
    NSInteger target=1;
    for(NSNumber *duration in _durations) {
        NSInteger rounded=(NSInteger)ceil([duration doubleValue]);
        if(rounded>target) target=rounded;
    }
    NSMutableString *text=[NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n",(int)target];
    for(NSUInteger i=0;i<[_segments count];i++) {
        NSInteger seconds=(NSInteger)ceil([[_durations objectAtIndex:i] doubleValue]);
        if(seconds<1) seconds=1;
        [text appendFormat:@"#EXTINF:%d,\nhttp://127.0.0.1:%u/seg/%lu.ts\n",
            (int)seconds,_port,(unsigned long)i];
    }
    [text appendString:@"#EXT-X-ENDLIST\n"];
    [_playlist release]; _playlist=[text copy];
}
- (BOOL)startListener {
    int fd=socket(AF_INET,SOCK_STREAM,0); if(fd<0) return NO;
    struct sockaddr_in address; memset(&address,0,sizeof(address));
    address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(fd,(struct sockaddr *)&address,sizeof(address))<0 || listen(fd,4)<0) { close(fd); return NO; }
    socklen_t size=sizeof(address);
    if(getsockname(fd,(struct sockaddr *)&address,&size)<0) { close(fd); return NO; }
    _port=ntohs(address.sin_port); _listener=fd;
    [NSThread detachNewThreadSelector:@selector(acceptThread:) toTarget:self withObject:nil];
    return YES;
}
- (BOOL)start {
    if(!_masterURL) return NO;
    // Preparation is allowed to wait for enough network headroom, but it must
    // never trap the user in a multi-minute experiment.
    _prepareDeadline=[NSDate timeIntervalSinceReferenceDate]+55.0;
    NSString *master=[self fetchText:_masterURL];
    if(!master) return NO;
    NSURL *mediaURL=[self mediaURLFromMaster:master];
    NSString *media=nil;
    if(mediaURL) media=[self fetchText:mediaURL];
    // A direct media playlist does not declare CODECS/RESOLUTION, so it cannot
    // prove that the bytes are Baseline AVC before we hand them to hardware.
    // Reject it instead of repeating the old Main-profile native failure.
    if(!mediaURL || !media) { [self setFailure:@"YouTube did not expose a verified 144p Baseline HLS rendition."]; return NO; }
    if(![self parseMediaPlaylist:media baseURL:mediaURL]) return NO;

    NSString *name=[NSString stringWithFormat:@"YouTube-HLS-%p",self];
    _cacheDir=[[NSTemporaryDirectory() stringByAppendingPathComponent:name] copy];
    [[NSFileManager defaultManager] removeItemAtPath:_cacheDir error:NULL];
    if(![[NSFileManager defaultManager] createDirectoryAtPath:_cacheDir attributes:nil]) {
        [self setFailure:@"Could not create the HLS buffer on disk."]; return NO;
    }
    // Deliberately buffer several complete transport-stream segments before
    // handing playback to iPhone OS 3. This recreates the old YouTube app's
    // network headroom without asking the ARM11 to decode ahead.
    if(![self prebuffer]) return NO;
    if(![self startListener]) { [self setFailure:@"Could not start the local HLS bridge."]; return NO; }
    [self buildLocalPlaylist];
    _prepareDeadline=0;
    [NSThread detachNewThreadSelector:@selector(prefetchThread:) toTarget:self withObject:nil];
    return YES;
}
- (NSURL *)movieURL {
    if(!_port) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/index.m3u8",_port]];
}
- (void)acceptThread:(id)unused {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    while(!_stopped) {
        int listener=_listener; if(listener<0) break;
        fd_set ready; FD_ZERO(&ready); FD_SET(listener,&ready); struct timeval timeout={0,100000};
        int result=select(listener+1,&ready,NULL,NULL,&timeout);
        if(_stopped) break;
        if(result<=0) continue;
        int fd=accept(listener,NULL,NULL); if(fd<0) continue;
        struct timeval limit={20,0};
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof(limit));
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,sizeof(limit));
#ifdef SO_NOSIGPIPE
        int one=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
        [NSThread detachNewThreadSelector:@selector(clientThread:) toTarget:self withObject:[NSNumber numberWithInt:fd]];
    }
    [pool release];
}
- (void)clientThread:(NSNumber *)number {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    int fd=[number intValue];
    char header[4097]; size_t used=0; header[0]=0;
    while(!_stopped && used<sizeof(header)-1 && !strstr(header,"\r\n\r\n")) {
        ssize_t count=recv(fd,header+used,sizeof(header)-1-used,0);
        if(count<0 && errno==EINTR) continue;
        if(count<=0) break;
        used+=(size_t)count; header[used]=0;
    }
    NSString *request=[[[NSString alloc] initWithBytes:header length:used encoding:NSASCIIStringEncoding] autorelease];
    NSArray *lines=[request componentsSeparatedByString:@"\r\n"];
    NSArray *first=[([lines count] ? [lines objectAtIndex:0] : @"") componentsSeparatedByString:@" "];
    NSString *method=[first count]>=2 ? [first objectAtIndex:0] : @"";
    NSString *path=[first count]>=2 ? [first objectAtIndex:1] : @"";
    BOOL head=[method isEqualToString:@"HEAD"];
    if((head || [method isEqualToString:@"GET"]) && [path isEqualToString:@"/index.m3u8"]) {
        NSData *body=[_playlist dataUsingEncoding:NSUTF8StringEncoding];
        YTHLSSendText(fd,[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: %lu\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",(unsigned long)[body length]]);
        if(!head) YTHLSSendBytes(fd,[body bytes],[body length]);
    } else if((head || [method isEqualToString:@"GET"]) && [path hasPrefix:@"/seg/"]) {
        NSString *leaf=[[path lastPathComponent] stringByDeletingPathExtension];
        NSInteger index=[leaf integerValue];
        NSData *body=(index>=0 && (NSUInteger)index<[_segments count]) ? [self dataForSegment:(NSUInteger)index] : nil;
        if(body) {
            YTHLSSendText(fd,[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: video/MP2T\r\nContent-Length: %lu\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n",(unsigned long)[body length]]);
            if(!head) YTHLSSendBytes(fd,[body bytes],[body length]);
        } else YTHLSSendText(fd,@"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    } else {
        YTHLSSendText(fd,@"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
    shutdown(fd,SHUT_RDWR); close(fd);
    [pool release];
}
- (void)stop {
    _stopped=YES;
    if(_listener>=0) { shutdown(_listener,SHUT_RDWR); close(_listener); _listener=-1; }
}
- (void)dealloc {
    [self stop];
    [[NSFileManager defaultManager] removeItemAtPath:_cacheDir error:NULL];
    [_masterURL release]; [_userAgent release]; [_segments release]; [_durations release];
    [_playlist release]; [_cacheDir release]; [_errorText release]; [_lock release];
    [super dealloc];
}
@end
