#import <Foundation/Foundation.h>
#import "YTMediaSource.h"
#import "YTAudioFile.h"
#include "YTVideoDecoder.h"
#include <libavformat/avformat.h>
#include <assert.h>
#include <string.h>
#include <errno.h>

static NSData *Movie;
static int Requests;
@interface YTMovieProtocol : NSURLProtocol { NSData *_fixture; }
@end
@implementation YTMovieProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [[[request URL] host] isEqualToString:@"movie.example"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (id)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)response client:(id<NSURLProtocolClient>)client {
    if((self=[super initWithRequest:request cachedResponse:response client:client])) _fixture=[Movie retain];
    return self;
}
- (void)dealloc { [_fixture release]; [super dealloc]; }
- (void)startLoading {
    assert([[[self request] URL] query] == nil);
    long long start = 0, end = 0;
    NSScanner *scan = [NSScanner scannerWithString:[[self request] valueForHTTPHeaderField:@"Range"]];
    assert([scan scanString:@"bytes=" intoString:NULL] && [scan scanLongLong:&start] &&
           [scan scanString:@"-" intoString:NULL] && [scan scanLongLong:&end]);
    assert(start >= 0 && end >= start && end < (long long)[_fixture length] && end - start + 1 <= 262144);
    __sync_add_and_fetch(&Requests,1);
    NSData *bytes = [_fixture subdataWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end-start+1))];
    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:@"video/mp4", @"Content-Type",
        [NSString stringWithFormat:@"%lld", end-start+1], @"Content-Length",
        [NSString stringWithFormat:@"bytes %lld-%lld/%lu", start, end, (unsigned long)[_fixture length]], @"Content-Range", nil];
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[[self request] URL] statusCode:206
        HTTPVersion:@"HTTP/1.1" headerFields:headers] autorelease];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:bytes];
    [[self client] URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
typedef struct { YTMediaSource *source; int64_t position; } Reader;
static int ReadVideo(void *opaque, uint8_t *bytes, int count) {
    Reader *reader=opaque;
    int result=[reader->source readAtOffset:reader->position into:bytes count:count];
    if (result <= 0) return result < 0 ? AVERROR(EIO) : AVERROR_EOF;
    reader->position += result;
    return result;
}
static int64_t SeekVideo(void *opaque, int64_t offset, int whence) {
    Reader *reader=opaque;
    if (whence == AVSEEK_SIZE) return [reader->source length];
    whence &= ~AVSEEK_FORCE;
    if (whence == SEEK_CUR) offset += reader->position;
    else if (whence == SEEK_END) offset += [reader->source length];
    assert(offset >= 0 && offset <= [reader->source length]);
    reader->position=offset;
    return offset;
}
int main(int argc, char **argv) {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    assert(argc == 2);
    Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] retain];
    assert([Movie length] > 65536);
    [NSURLProtocol registerClass:[YTMovieProtocol class]];
    NSURL *url=[NSURL URLWithString:@"https://movie.example/combined.mp4"];
    YTMediaSource *audio=[[YTMediaSource alloc] initWithURL:url length:[Movie length] userAgent:@"fixture"];
    YTMediaSource *sibling=[[YTMediaSource alloc] initWithURL:url length:[Movie length] userAgent:@"fixture"];
    [sibling shareCacheWithSource:audio];
    unsigned char peek[12];
    assert([audio readAtOffset:0 into:peek count:12]==12); int before=Requests;
    assert([sibling readAtOffset:0 into:peek count:12]==12 && Requests==before);
    [sibling release];
    AudioFileID file=NULL;
    OSStatus status=YTOpenAudioFile(audio, &file);
    if (status) NSLog(@"Native combined MP4 audio open failed: %ld", (long)status);
    assert(status == noErr);
    AudioStreamBasicDescription format; UInt32 size=sizeof(format);
    assert(AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr);
    assert(format.mFormatID == kAudioFormatMPEG4AAC && format.mSampleRate == 44100 && format.mChannelsPerFrame == 2);
    UInt32 cookieSize=0;
    assert(AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &cookieSize, NULL) == noErr && cookieSize > 0);
    UInt32 totalPackets=0; SInt64 packet=0;
    for (;;) {
        uint8_t bytes[32768]; AudioStreamPacketDescription descriptions[16];
        UInt32 byteCount=sizeof(bytes), packets=16;
        status=AudioFileReadPackets(file, false, &byteCount, descriptions, packet, &packets, bytes);
        assert(status == noErr || status == (OSStatus)-39);
        if (!packets) break;
        assert(byteCount > 0); totalPackets += packets; packet += packets;
    }
    assert(totalPackets > 100);
    AudioFileClose(file);
    YTMediaSource *video=[[YTMediaSource alloc] initWithURL:url length:[Movie length] userAgent:@"fixture"];
    [video shareCacheWithSource:audio]; [audio release];
    Reader reader={video,0};
    av_register_all();
    AVFormatContext *container=avformat_alloc_context();
    AVIOContext *io=avio_alloc_context(av_malloc(32768),32768,0,&reader,ReadVideo,NULL,SeekVideo);
    container->pb=io; container->flags |= AVFMT_FLAG_CUSTOM_IO;
    assert(avformat_open_input(&container,NULL,NULL,NULL) == 0);
    int track=-1;
    for (unsigned i=0;i<container->nb_streams;i++)
        if (container->streams[i]->codec->codec_type == AVMEDIA_TYPE_VIDEO) track=i;
    assert(track >= 0);
    AVCodecContext *codec=container->streams[track]->codec;
    assert(codec->width == 640 && codec->height == 360);
    assert(YTOpenH264Decoder(codec) == 0 && codec->skip_frame == AVDISCARD_NONREF);
    AVFrame *frame=av_frame_alloc(); YTVideoImage image; memset(&image,0,sizeof(image));
    AVPacket encoded; int pictures=0;
    while (av_read_frame(container,&encoded) >= 0) {
        if (encoded.stream_index == track) {
            AVPacket part=encoded;
            while (part.size > 0) {
                int got=0, used=avcodec_decode_video2(codec,frame,&got,&part);
                assert(used >= 0);
                if (got) {
                    assert(YTConvertVideoFrame(&image,frame) == 0);
                    assert(image.width == 256 && image.height == 144 && image.pixelBytes == 256*144*2);
                    pictures++;
                }
                if (!used) break;
                part.data += used; part.size -= used;
            }
        }
        av_free_packet(&encoded);
    }
    assert(pictures >= 20);
    assert(Requests == 2); // Audio and video download each 64 KiB chunk once.
    assert(codec->profile == FF_PROFILE_H264_MAIN);
    YTFreeVideoImage(&image); av_frame_free(&frame); avcodec_close(codec);
    avformat_close_input(&container); av_free(io->buffer); av_free(io); [video release];
    [NSURLProtocol unregisterClass:[YTMovieProtocol class]];
    NSLog(@"Combined MP4 test passed: %d Main-profile frames decoded/scaled, %u AAC packets read natively, %d bounded range requests.",pictures,(unsigned)totalPackets,Requests);
    [Movie release]; [pool release]; return 0;
}
