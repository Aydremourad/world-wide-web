#import "YTLoopbackServer.h"
#import "YTMediaSource.h"
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
static BOOL YTSendBytes(int fd,const void *bytes,size_t count) {
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
static BOOL YTSendText(int fd,NSString *text) {
    NSData *data=[text dataUsingEncoding:NSASCIIStringEncoding];
    return YTSendBytes(fd,[data bytes],[data length]);
}
@implementation YTLoopbackServer
- (id)initWithURL:(NSURL *)url length:(int64_t)length userAgent:(NSString *)userAgent {
    if((self=[super init])) {
        _upstream=[url retain]; _length=length; _userAgent=[userAgent copy];
        _sharedSource=[[YTMediaSource alloc] initWithURL:url length:length userAgent:userAgent];
        [_sharedSource enableStreamingReadAhead];
        _lock=[[NSLock alloc] init]; _clients=[[NSMutableDictionary alloc] init]; _listener=-1;
    }
    return self;
}
- (BOOL)start {
    if(_length<=0 || !_upstream) return NO;
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
- (NSURL *)movieURL { return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/movie.mp4",_port]]; }
- (NSString *)errorText { [_lock lock]; NSString *text=[[_errorText copy] autorelease]; [_lock unlock]; return text; }
- (void)acceptThread:(id)unused {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    while(!_stopped) {
        [_lock lock]; int listener=_listener; [_lock unlock]; if(listener<0) break;
        fd_set ready; FD_ZERO(&ready); FD_SET(listener,&ready); struct timeval timeout={0,100000};
        int result=select(listener+1,&ready,NULL,NULL,&timeout);
        if(_stopped) break;
        if(result<=0) continue;
        int fd=accept(listener,NULL,NULL); if(fd<0) continue;
        struct timeval limit={20,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof(limit)); setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,sizeof(limit));
#ifdef SO_NOSIGPIPE
        int one=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
        NSAutoreleasePool *clientPool=[[NSAutoreleasePool alloc] init];
        YTMediaSource *source=[[[YTMediaSource alloc] initWithURL:_upstream length:_length userAgent:_userAgent] autorelease];
        [source shareCacheWithSource:_sharedSource];
        NSNumber *key=[NSNumber numberWithInt:fd];
        [_lock lock]; BOOL full=[_clients count]>=4 || _stopped;
        if(!full) [_clients setObject:source forKey:key]; [_lock unlock];
        if(full) { close(fd); [clientPool release]; continue; }
        [NSThread detachNewThreadSelector:@selector(clientThread:) toTarget:self withObject:key];
        [clientPool release];
    }
    [pool release];
}
- (void)clientThread:(NSNumber *)key {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init]; int fd=[key intValue];
    [_lock lock]; YTMediaSource *source=[[_clients objectForKey:key] retain]; [_lock unlock];
    char header[8193]; size_t used=0; header[0]=0;
    while(!_stopped && used<sizeof(header)-1 && !strstr(header,"\r\n\r\n")) {
        ssize_t count=recv(fd,header+used,sizeof(header)-1-used,0);
        if(count<0 && errno==EINTR) continue;
        if(count<=0) break;
        used+=(size_t)count; header[used]=0;
    }
    NSString *text=[[[NSString alloc] initWithBytes:header length:used encoding:NSASCIIStringEncoding] autorelease];
    NSArray *lines=[text componentsSeparatedByString:@"\r\n"];
    NSArray *request=[([lines count] ? [lines objectAtIndex:0] : @"") componentsSeparatedByString:@" "];
    NSString *method=[request count]>=2 ? [request objectAtIndex:0] : @"";
    BOOL head=[method isEqualToString:@"HEAD"],valid=(head || [method isEqualToString:@"GET"]) && [request count]>=2 && [[request objectAtIndex:1] isEqualToString:@"/movie.mp4"];
    int64_t first=0,last=_length-1; BOOL partial=NO;
    if(valid) for(NSString *line in lines) {
        NSRange colon=[line rangeOfString:@":"]; if(colon.location==NSNotFound) continue;
        if([[line substringToIndex:colon.location] caseInsensitiveCompare:@"Range"]!=NSOrderedSame) continue;
        partial=YES;
        NSString *value=[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSScanner *scan=[NSScanner scannerWithString:value]; long long a=0,b=0;
        if(![scan scanString:@"bytes=" intoString:NULL]) { valid=NO; break; }
        if([scan scanString:@"-" intoString:NULL]) {
            if(![scan scanLongLong:&b] || b<=0) valid=NO;
            else first=b>=_length ? 0 : _length-b;
        } else {
            if(![scan scanLongLong:&a] || ![scan scanString:@"-" intoString:NULL]) valid=NO;
            else { first=a; if(![scan isAtEnd]) { if(![scan scanLongLong:&b]) valid=NO; else last=b; } }
        }
        if(![scan isAtEnd] || first<0 || first>=_length || last<first) valid=NO;
        if(last>=_length) last=_length-1;
        break;
    }
    if(!_stopped && valid) {
        NSString *range=partial ? [NSString stringWithFormat:@"Content-Range: bytes %lld-%lld/%lld\r\n",(long long)first,(long long)last,(long long)_length] : @"";
        NSString *response=[NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: video/mp4\r\nContent-Length: %lld\r\nAccept-Ranges: bytes\r\n%@Connection: close\r\n\r\n",partial ? 206 : 200,partial ? @"Partial Content" : @"OK",(long long)(last-first+1),range];
        if(YTSendText(fd,response) && !head) {
            uint8_t *bytes=malloc(65536);
            if(bytes) while(!_stopped && first<=last) {
                NSAutoreleasePool *chunkPool=[[NSAutoreleasePool alloc] init];
                int wanted=last-first+1>65536 ? 65536 : (int)(last-first+1);
                int count=[source readAtOffset:first into:bytes count:wanted];
                BOOL sent=count>0 && YTSendBytes(fd,bytes,(size_t)count);
                if(count<=0 && !_stopped) { [_lock lock]; [_errorText release]; _errorText=[[source errorText] copy]; [_lock unlock]; }
                [chunkPool release]; if(!sent) break; first+=count;
            }
            free(bytes);
        }
    } else if(!_stopped) {
        YTSendText(fd,[NSString stringWithFormat:@"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%lld\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",(long long)_length]);
    }
    // Retire the entry before the kernel can reuse this socket number.
    [_lock lock]; [_clients removeObjectForKey:key];
    shutdown(fd,SHUT_RDWR); close(fd); [_lock unlock];
    [source release]; [pool release];
}
- (void)stop {
    [_lock lock]; _stopped=YES;
    if(_listener>=0) { shutdown(_listener,SHUT_RDWR); close(_listener); _listener=-1; }
    for(NSNumber *key in _clients) { [[_clients objectForKey:key] cancel]; shutdown([key intValue],SHUT_RDWR); }
    [_lock unlock];
}
- (void)dealloc { [self stop]; [_upstream release]; [_userAgent release]; [_errorText release]; [_lock release]; [_clients release]; [_sharedSource release]; [super dealloc]; }
@end
