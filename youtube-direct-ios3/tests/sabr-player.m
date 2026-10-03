#import <Foundation/Foundation.h>
#import "YTMediaSource.h"
#import "../YTSABR.m"
#include "YTVideoDecoder.h"
#include <assert.h>
static NSString *Root; static int Requests,Mode;
@interface SABRProtocol : NSURLProtocol
@end
@implementation SABRProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [[[request URL] host] hasSuffix:@".googlevideo.com"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    NSURLRequest *r=[self request]; assert([[r HTTPMethod] isEqualToString:@"POST"]);
    assert([[r valueForHTTPHeaderField:@"Accept"] isEqualToString:@"application/vnd.yt-ump"]);
    NSDictionary *body=Proto([r HTTPBody]),*abr=Proto(Field(body,1)),*streamer=Proto(Field(body,19));
    assert(Number(abr,21)==144 && Number(abr,40)==2); // Cannot request video+audio or 360p.
    assert(Number(Proto(Field(body,17)),1)==160 && Number(Proto(Field(body,16)),1)==140);
    assert([Field(body,5) isEqual:[NSData dataWithBytes:"\0\0\1\0" length:4]]);
    if(Requests) { assert(Field(body,2)); assert([Field(streamer,3) isEqual:[NSData dataWithBytes:"\x08\x01" length:2]]);
        assert(Number(Proto(Field(streamer,5)),1)==7); }
    int index=(int)(Number(abr,28)/1000); Requests++;
    NSMutableData *data=[[NSData dataWithContentsOfFile:[Root stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.ump",index]]] mutableCopy]; assert(data);
    NSInteger status=200; NSString *mime=@"application/vnd.yt-ump";
    if(Mode==1) [data setLength:[data length]-1];
    if(Mode==2) { status=403; [data setLength:0]; }
    if(Mode==3) mime=@"text/html";
    if(Mode==4) { NSMutableData *s=[NSMutableData data]; Int(s,1,3); [data setLength:0]; uint8_t hdr[2]={58,(uint8_t)[s length]}; [data appendBytes:hdr length:2]; [data appendData:s]; }
    NSHTTPURLResponse *response=[[[NSHTTPURLResponse alloc] initWithURL:[r URL] statusCode:status HTTPVersion:@"HTTP/1.1"
        headerFields:[NSDictionary dictionaryWithObjectsAndKeys:mime,@"Content-Type",[NSString stringWithFormat:@"%lu",(unsigned long)[data length]],@"Content-Length",nil]] autorelease];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:data]; [[self client] URLProtocolDidFinishLoading:self]; [data release];
}
- (void)stopLoading {}
@end
static uint64_t Decode(const char *path,int *count) {
    AVFormatContext *f=NULL; av_register_all(); assert(avformat_open_input(&f,path,NULL,NULL)==0); assert(avformat_find_stream_info(f,NULL)>=0);
    AVCodecContext *c=f->streams[0]->codec; assert(c->width==256 && c->height==144 && c->profile==77);
    assert(YTOpenH264Decoder(c)==0); c->skip_frame=AVDISCARD_DEFAULT;
    AVFrame *frame=av_frame_alloc(); uint64_t hash=1469598103934665603ULL; *count=0;
    AVPacket p; while(av_read_frame(f,&p)>=0) {
        int got=0; assert(avcodec_decode_video2(c,frame,&got,&p)>=0); av_packet_unref(&p);
        if(got) { (*count)++; for(int plane=0;plane<3;plane++) for(int y=0;y<(plane?72:144);y++) for(int x=0;x<(plane?128:256);x++) { hash^=frame->data[plane][y*frame->linesize[plane]+x]; hash*=1099511628211ULL; } }
    }
    // Exercise seeks after rebuilding a normal MP4 sample table.
    assert(YTSeekVideoToTime(f,0,c,4.25)==0); assert(YTSeekVideoToTime(f,0,c,1.25)==0);
    av_frame_free(&frame); avcodec_close(c); avformat_close_input(&f); return hash;
}
int main(int argc,char **argv) {
    assert(argc==4); NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init]; Root=[NSString stringWithUTF8String:argv[1]];
    // Golden UMP varints were encoded independently by the Python fixture generator.
    NSData *varints=[NSData dataWithContentsOfFile:[Root stringByAppendingPathComponent:@"varints"]]; NSUInteger pos=0;
    uint32_t expected[]={127,128,16383,16384,2097151,2097152,268435455,268435456,4294967295};
    for(unsigned i=0;i<9;i++) { uint32_t n=0; assert(UMPInteger([varints bytes],[varints length],&pos,&n) && n==expected[i]); }
    NSDictionary *video=[NSDictionary dictionaryWithObjectsAndKeys:@160,@"itag",@256,@"width",@144,@"height",@8000,@"duration",@1000000,@"length",@"1700000000000000",@"lastModified",nil];
    NSMutableDictionary *options=[NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSURL URLWithString:@"https://media.googlevideo.com/videoplayback?test=1"],@"url",@"AAABAA==",@"config",
        video,@"video",[NSDictionary dictionaryWithObjectsAndKeys:@140,@"itag",@"1700000000000000",@"lastModified",nil],@"audio",
        @"jNQXAC9IVRw",@"videoID",@3,@"clientNumber",@"21.26.364",@"clientVersion",@"fixture",@"userAgent",nil];
    [[NSFileManager defaultManager] removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"YTPhoneVideo"] error:NULL];
    [NSURLProtocol registerClass:[SABRProtocol class]]; NSString *error=nil;
    NSString *output=YTDownloadSABRVideo(options,&error); assert(output && !error && Requests>=2);
    int before=0,after=0; uint64_t a=Decode(argv[2],&before),b=Decode([output fileSystemRepresentation],&after);
    assert(before==after && before>100 && a==b);
    YTMediaSource *local=[[YTMediaSource alloc] initWithURL:[NSURL fileURLWithPath:output] length:0 userAgent:nil];
    YTMediaSource *reader=[local newReader]; uint8_t bytes[8]; assert([reader length]>512 && [reader readAtOffset:0 into:bytes count:8]==8 && !memcmp(bytes+4,"ftyp",4));
    [reader cancel]; assert([reader readAtOffset:0 into:bytes count:8]<0); assert([local readAtOffset:0 into:bytes count:8]==8); [reader release]; [local release];
    int calls=Requests; assert([YTDownloadSABRVideo(options,&error) isEqual:output] && Requests==calls); // Second play reuses the verified cache.
    for(Mode=1;Mode<=4;Mode++) {
        [[NSFileManager defaultManager] removeItemAtPath:output error:NULL]; Requests=0; error=nil;
        assert(!YTDownloadSABRVideo(options,&error) && [error length]);
        assert(![[NSFileManager defaultManager] fileExistsAtPath:output]);
    }
    // Codec gate at remux time rejects a server that supplies 360p despite requesting 144p.
    NSString *bad=[Root stringByAppendingPathComponent:@"bad.mp4"];
    assert(YTRemuxPhoneVideo(argv[3],[bad fileSystemRepresentation])<0 && ![[NSFileManager defaultManager] fileExistsAtPath:bad]);
    [NSURLProtocol unregisterClass:[SABRProtocol class]];
    NSLog(@"Phone-only SABR passed: genuine fragmented Main 144p media, complete byte-preserving remux, identical decoded frames, forward/backward seeking, cached replay, local reader cancellation, token/HTTP/truncation failures, and rejection of 360p.");
    [pool release]; return 0;
}
