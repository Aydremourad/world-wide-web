#define main YTCombinedFixtureMain
#include "combined-player.m"
#undef main
#include "YTPlayerTiming.h"
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
    for (unsigned i=0;i<format->nb_streams;i++) if(format->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO) track=i;
    assert(track>=0); AVCodecContext *codec=format->streams[track]->codec;
    assert(YTOpenH264Decoder(codec)==0);
    AVFrame *frame=av_frame_alloc(); YTVideoImage image={0};
    AVPacket packet; int catchUp=0,pictures=0,skipped=0; double lastTime=0;
    while(av_read_frame(format,&packet)>=0) {
        if(packet.stream_index==track) {
            int key=(packet.flags&AV_PKT_FLAG_KEY)!=0;
            double videoTime=packet.pts*av_q2d(format->streams[track]->time_base);
            // Model a decoder two seconds behind audio for the entire video.
            if(YTNeedsVideoCatchUp(videoTime,videoTime+2,1,key)) catchUp=1;
            if(catchUp && !key) { skipped++; av_free_packet(&packet); continue; }
            if(catchUp) { avcodec_flush_buffers(codec); catchUp=0; }
            AVPacket part=packet;
            while(part.size>0) {
                int got=0,used=avcodec_decode_video2(codec,frame,&got,&part); assert(used>=0);
                if(got) {
                    assert(YTConvertVideoFrame(&image,frame)==0);
                    lastTime=av_frame_get_best_effort_timestamp(frame)*av_q2d(format->streams[track]->time_base);
                    pictures++;
                }
                if(!used) break; part.data+=used; part.size-=used;
            }
        }
        av_free_packet(&packet);
    }
    assert(pictures>=12 && skipped>100 && lastTime>30);
    NSLog(@"Video catch-up passed: %d pictures across %.1f seconds, %d stale packets skipped.",pictures,lastTime,skipped);
    YTFreeVideoImage(&image); av_frame_free(&frame); avcodec_close(codec);
    avformat_close_input(&format); av_free(io->buffer); av_free(io); [source release];
    [NSURLProtocol unregisterClass:[YTMovieProtocol class]]; [Movie release]; [pool release]; return 0;
}
