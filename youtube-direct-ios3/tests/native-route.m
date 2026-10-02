#define main YTCombinedFixtureMain
#include "combined-player.m"
#undef main
#import "YTNativeProbe.h"
#import "YTLoopbackServer.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <pthread.h>
static NSDictionary *Streams(void) {
    return [NSDictionary dictionaryWithObjectsAndKeys:[NSURL URLWithString:@"https://movie.example/combined.mp4"],@"videoURL",[NSNumber numberWithLongLong:[Movie length]],@"videoLength",@"fixture",@"userAgent",[NSNumber numberWithBool:YES],@"combined",nil];
}
static NSData *Fetch(NSURL *url,NSString *method,NSString *range,int expected) {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
    [request setHTTPMethod:method]; if(range) [request setValue:range forHTTPHeaderField:@"Range"];
    NSURLResponse *response=nil; NSError *error=nil;
    NSData *data=[NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    assert(!error && [(NSHTTPURLResponse *)response statusCode]==expected);
    if([method isEqualToString:@"HEAD"]) assert([response expectedContentLength]==(long long)[Movie length]);
    return data;
}
typedef struct { NSURL *url; NSData *bytes; } ParallelFetch;
static void *FetchThread(void *opaque) {
    ParallelFetch *fetch=opaque; NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    fetch->bytes=[Fetch(fetch->url,@"GET",@"bytes=300000-500000",206) retain];
    [pool release]; return NULL;
}
int main(int argc,char **argv) {
    assert(argc==5); NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    [NSURLProtocol registerClass:[YTMovieProtocol class]];
    Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] retain];
    NSDictionary *info=YTNativeStreamInfo(Streams());
    assert(info && ![[info objectForKey:@"eligible"] boolValue] && [[info objectForKey:@"profile"] intValue]==77);
    [Movie release]; Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]] retain];
    info=YTNativeStreamInfo(Streams());
    assert(info && [[info objectForKey:@"eligible"] boolValue] && [[info objectForKey:@"profile"] intValue]==66);
    [Movie release]; Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[4]]] retain];
    info=YTNativeStreamInfo(Streams());
    NSLog(@"Simple Profile probe: %@",info);
    assert(info && [[info objectForKey:@"eligible"] boolValue] && [[info objectForKey:@"profile"] intValue]==0);
    NSLog(@"Native MPEG-4 Simple Profile route passed.");
    NSMutableData *advanced=[Movie mutableCopy]; unsigned char *headers=[advanced mutableBytes]; BOOL changed=NO;
    for(NSUInteger i=0;i+4<[advanced length];i++) {
        if(!headers[i] && !headers[i+1] && headers[i+2]==1 && headers[i+3]==0xb0) { headers[i+4]=0xf1; changed=YES; break; }
    }
    assert(changed); [Movie release]; Movie=advanced;
    info=YTNativeStreamInfo(Streams());
    assert(info && ![[info objectForKey:@"eligible"] boolValue]);
    [Movie release]; Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[3]]] retain];
    YTLoopbackServer *server=[[YTLoopbackServer alloc] initWithURL:[Streams() objectForKey:@"videoURL"] length:[Movie length] userAgent:@"fixture"];
    assert([server start]); NSURL *url=[server movieURL];
    assert([Fetch(url,@"HEAD",nil,200) length]==0);
    assert([Fetch(url,@"GET",@"bytes=0-1",206) isEqualToData:[Movie subdataWithRange:NSMakeRange(0,2)]]);
    int beforeRequests=Requests;
    assert([Fetch(url,@"GET",@"bytes=0-1",206) isEqualToData:[Movie subdataWithRange:NSMakeRange(0,2)]]);
    assert(Requests==beforeRequests); // Apple's repeated probes reuse downloaded bytes.
    assert([Fetch(url,@"GET",@"bytes=65530-131100",206) isEqualToData:[Movie subdataWithRange:NSMakeRange(65530,65571)]]);
    assert([Fetch(url,@"GET",@"bytes=-25",206) isEqualToData:[Movie subdataWithRange:NSMakeRange([Movie length]-25,25)]]);
    ParallelFetch first={url,nil},second={url,nil}; pthread_t a,b;
    beforeRequests=Requests;
    assert(pthread_create(&a,NULL,FetchThread,&first)==0 && pthread_create(&b,NULL,FetchThread,&second)==0);
    pthread_join(a,NULL); pthread_join(b,NULL);
    NSData *wanted=[Movie subdataWithRange:NSMakeRange(300000,200001)];
    assert([first.bytes isEqualToData:wanted] && [second.bytes isEqualToData:wanted]);
    assert(Requests-beforeRequests==1); // Concurrent ranges do not duplicate upstream requests.
    [first.bytes release]; [second.bytes release];
    assert([Fetch(url,@"GET",nil,200) isEqualToData:Movie]);
    NSString *eof=[NSString stringWithFormat:@"bytes=%lu-",(unsigned long)[Movie length]];
    assert([Fetch(url,@"GET",eof,416) length]==0);
    assert([Fetch(url,@"GET",@"bytes=0-2,4-6",416) length]==0);
    assert([Fetch(url,@"GET",@"bytes=40-20",416) length]==0);
    double before=[NSDate timeIntervalSinceReferenceDate]; [server stop];
    assert([NSDate timeIntervalSinceReferenceDate]-before<0.5);
    [NSThread sleepForTimeInterval:0.25];
    assert(![[server errorText] length]); [server release];
    NSLog(@"Native route passed: Baseline accepted, Main rejected, complete 36-second MP4 bridged byte-for-byte, HEAD/ranges/suffix/EOF, concurrent shared cache and stop.");
    [NSURLProtocol unregisterClass:[YTMovieProtocol class]]; [Movie release]; [pool release]; return 0;
}
