#define main YTCombinedFixtureMain
#include "combined-player.m"
#undef main
#include "YTPlayerTiming.h"
static double FirstPictureAfterSeek(AVFormatContext *format,int track,AVCodecContext *codec,AVFrame *frame,double target) {
    assert(YTSeekVideoToTime(format,track,codec,target)==0);
    AVPacket packet; int decoded=0;
    while(av_read_frame(format,&packet)>=0) {
        if(packet.stream_index==track) {
            AVPacket part=packet;
            while(part.size>0) {
                int got=0,used=avcodec_decode_video2(codec,frame,&got,&part); assert(used>=0);
                if(got) {
                    decoded++;
                    double seconds=av_frame_get_best_effort_timestamp(frame)*av_q2d(format->streams[track]->time_base)-YTVideoTimeOrigin(format->streams[track]);
                    if(seconds>=target-0.025) { av_free_packet(&packet); assert(decoded<120); return seconds; }
                }
                if(!used) break; part.data+=used; part.size-=used;
            }
        }
        av_free_packet(&packet);
    }
    assert(0); return -1;
}
int main(int argc,char **argv) {
    assert(argc==2); NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] retain];
    [NSURLProtocol registerClass:[YTMovieProtocol class]];
    YTMediaSource *source=[[YTMediaSource alloc] initWithURL:[NSURL URLWithString:@"https://movie.example/combined.mp4"] length:[Movie length] userAgent:@"fixture"];
    Reader reader={source,0}; av_register_all();
    AVFormatContext *format=avformat_alloc_context();
    AVIOContext *io=avio_alloc_context(av_malloc(32768),32768,0,&reader,ReadVideo,NULL,SeekVideo);
    format->pb=io; format->flags|=AVFMT_FLAG_CUSTOM_IO;
    assert(avformat_open_input(&format,NULL,NULL,NULL)==0);
    int track=-1;
    for(unsigned i=0;i<format->nb_streams;i++) if(format->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO) track=i;
    assert(track>=0); AVCodecContext *codec=format->streams[track]->codec;
    assert(YTOpenH264Decoder(codec)==0);
    AVFrame *frame=av_frame_alloc(); YTVideoImage image={0};
    AVPacket packet; int pictures=0,nonkeys=0,presented=0; double lastTime=0,lastDisplay=0;
    // Every reference-bearing packet reaches the decoder even when audio is
    // ahead. Non-reference B pictures may be dropped by FFmpeg; whole GOPs may not.
    while(av_read_frame(format,&packet)>=0) {
        if(packet.stream_index==track) {
            AVPacket part=packet;
            while(part.size>0) {
                int got=0,used=avcodec_decode_video2(codec,frame,&got,&part); assert(used>=0);
                if(got) {
                    assert(YTConvertVideoFrame(&image,frame)==0);
                    lastTime=av_frame_get_best_effort_timestamp(frame)*av_q2d(format->streams[track]->time_base);
                    pictures++; if(!frame->key_frame) nonkeys++;
                    double now=pictures*0.05;
                    if(YTShouldPresentFrame(-2,now,lastDisplay)) { presented++; lastDisplay=now; }
                }
                if(!used) break; part.data+=used; part.size-=used;
            }
        }
        av_free_packet(&packet);
    }
    assert(pictures>180 && nonkeys>100 && lastTime>35 && presented>80);
    NSLog(@"Video continuity passed: %d pictures (%d non-key), %.1f seconds, %d late presentations; no GOP slideshow.",pictures,nonkeys,lastTime,presented);
    const double targets[]={22.25,4.75,31.15,0,15.5};
    for(unsigned i=0;i<sizeof(targets)/sizeof(targets[0]);i++) {
        double actual=FirstPictureAfterSeek(format,track,codec,frame,targets[i]);
        assert(actual>=targets[i]-0.025 && actual<targets[i]+0.2);
        NSLog(@"Video seek %.2f -> first picture %.3f",targets[i],actual);
    }
    YTFreeVideoImage(&image); av_frame_free(&frame); avcodec_close(codec);
    avformat_close_input(&format); av_free(io->buffer); av_free(io); [source release];
    [NSURLProtocol unregisterClass:[YTMovieProtocol class]]; [Movie release]; [pool release]; return 0;
}
