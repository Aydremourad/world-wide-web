#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
#include "YTVideoDecoder.h"
#include "libavutil/cpu.h"
#include "libavutil/mem.h"
#include "config.h"
#include "libavcodec/h264qpel.h"
#include "libavcodec/h264chroma.h"
#include "libavcodec/h264dsp.h"
#define MAX_PICTURES 1024
typedef struct { FILE *file; long length; } Fixture;
static int fixture_read(void *opaque,uint8_t *bytes,int length) {
    Fixture *f=opaque; int n=(int)fread(bytes,1,length,f->file); return n>0 ? n : AVERROR_EOF;
}
static int64_t fixture_seek(void *opaque,int64_t offset,int whence) {
    Fixture *f=opaque;
    if(whence==AVSEEK_SIZE) return f->length;
    whence&=~AVSEEK_FORCE;
    if(fseek(f->file,(long)offset,whence)) return -1;
    return ftell(f->file);
}
static AVFormatContext *fixture_open(const char *file,Fixture *f,AVIOContext **io) {
    f->file=fopen(file,"rb"); assert(f->file);
    assert(!fseek(f->file,0,SEEK_END)); f->length=ftell(f->file); rewind(f->file);
    *io=avio_alloc_context(av_malloc(32768),32768,0,f,fixture_read,NULL,fixture_seek); assert(*io);
    AVFormatContext *format=avformat_alloc_context(); assert(format);
    format->pb=*io; format->flags|=AVFMT_FLAG_CUSTOM_IO;
    assert(avformat_open_input(&format,NULL,NULL,NULL)==0); return format;
}
static void fixture_close(AVFormatContext **format,Fixture *f,AVIOContext *io) {
    avformat_close_input(format); av_free(io->buffer); av_free(io); fclose(f->file);
}
typedef struct { uint64_t hashes[MAX_PICTURES]; int64_t times[MAX_PICTURES]; int count,nonkeys; double decode; } Pictures;
static void picture(Pictures *p,AVFrame *frame) {
    assert(p->count<MAX_PICTURES); uint64_t hash=1469598103934665603ULL;
    for(int plane=0;plane<3;plane++) {
        int width=plane ? (frame->width+1)/2 : frame->width;
        int height=plane ? (frame->height+1)/2 : frame->height;
        for(int y=0;y<height;y++) for(int x=0;x<width;x++) {
            hash^=frame->data[plane][y*frame->linesize[plane]+x]; hash*=1099511628211ULL;
        }
    }
    p->hashes[p->count]=hash; p->times[p->count]=av_frame_get_best_effort_timestamp(frame);
    p->count++; if(!frame->key_frame) p->nonkeys++;
}
static void decode(const char *file,int cpu,int skip, Pictures *pictures) {
    memset(pictures,0,sizeof(*pictures)); av_force_cpu_flags(cpu);
    Fixture fixture; AVIOContext *io;
    AVFormatContext *format=fixture_open(file,&fixture,&io);
    int track=av_find_best_stream(format,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0); assert(track>=0);
    AVCodecContext *codec=format->streams[track]->codec; assert(YTOpenH264Decoder(codec)==0);
    codec->skip_frame=skip ? AVDISCARD_NONREF : AVDISCARD_DEFAULT;
    AVFrame *frame=av_frame_alloc(); assert(frame);
    AVPacket packet;
    while(av_read_frame(format,&packet)>=0) {
        if(packet.stream_index==track) {
            AVPacket part=packet;
            while(part.size>0) {
                int got=0; clock_t start=clock();
                int used=avcodec_decode_video2(codec,frame,&got,&part); assert(used>=0);
                pictures->decode+=(double)(clock()-start)/CLOCKS_PER_SEC;
                if(got) picture(pictures,frame);
                if(!used) break; part.data+=used; part.size-=used;
            }
        }
        av_free_packet(&packet);
    }
    av_init_packet(&packet); packet.data=NULL; packet.size=0;
    for(int i=0;i<16;i++) { int got=0; assert(avcodec_decode_video2(codec,frame,&got,&packet)>=0); if(!got) break; picture(pictures,frame); }
    av_frame_free(&frame); avcodec_close(codec); fixture_close(&format,&fixture,io);
}
static void forward_seeks(const char *file) {
    Fixture fixture; AVIOContext *io;
    AVFormatContext *format=fixture_open(file,&fixture,&io);
    int track=av_find_best_stream(format,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0); assert(track>=0);
    AVCodecContext *codec=format->streams[track]->codec; assert(YTOpenH264Decoder(codec)==0);
    AVFrame *frame=av_frame_alloc(); AVPacket packet;
    const double origin=YTVideoTimeOrigin(format->streams[track]);
    const double targets[]={0.15,1.25,3.15,5.10};
    for(unsigned i=0;i<sizeof(targets)/sizeof(targets[0]);i++) {
        double target=targets[i]; assert(YTAdvanceVideoToTime(format,track,codec,target,origin)==0);
        int found=0;
        while(!found && av_read_frame(format,&packet)>=0) {
            if(packet.stream_index==track) {
                int got=0; assert(avcodec_decode_video2(codec,frame,&got,&packet)>=0);
                if(got) {
                    double time=av_frame_get_best_effort_timestamp(frame)*av_q2d(format->streams[track]->time_base)-origin;
                    if(!frame->key_frame || time<target || time>=target+2.0)
                        fprintf(stderr,"Forward seek failed: target %.3f, got %.3f, key=%d, origin %.3f\n",target,time,frame->key_frame,YTVideoTimeOrigin(format->streams[track]));
                    assert(frame->key_frame && time>=target && time<target+2.0); found=1;
                    printf("Forward catch-up %.2f -> keyframe %.3f (no backward GOP).\n",target,time);
                }
            }
            av_free_packet(&packet);
        }
        assert(found);
    }
    assert(YTAdvanceVideoToTime(format,track,codec,9999,origin)<0);
    av_frame_free(&frame); avcodec_close(codec); fixture_close(&format,&fixture,io);
}
int main(int argc,char **argv) {
    assert(argc==2); av_register_all(); av_log_set_level(AV_LOG_ERROR);
#if ARCH_ARM
    H264QpelContext genericQpel={0},armQpel={0};
    H264ChromaContext genericChroma={0},armChroma={0};
    H264DSPContext genericDsp={0},armDsp={0};
    av_force_cpu_flags(0);
    ff_h264qpel_init(&genericQpel,8); ff_h264chroma_init(&genericChroma,8); ff_h264dsp_init(&genericDsp,8,1);
    av_force_cpu_flags(AV_CPU_FLAG_ARMV6);
    ff_h264qpel_init(&armQpel,8); ff_h264chroma_init(&armChroma,8); ff_h264dsp_init(&armDsp,8,1);
    assert(genericQpel.put_h264_qpel_pixels_tab[0][2]!=armQpel.put_h264_qpel_pixels_tab[0][2]);
    assert(genericChroma.put_h264_chroma_pixels_tab[0]!=armChroma.put_h264_chroma_pixels_tab[0]);
    assert(genericDsp.h264_idct_add16!=armDsp.h264_idct_add16);
    puts("Production decoder selects the ARM11 motion, chroma, and IDCT callbacks.");
#endif
    Pictures original,optimized,referenceOnly;
    decode(argv[1],0,0,&original); decode(argv[1],AV_CPU_FLAG_ARMV6,0,&optimized);
    assert(original.count==optimized.count && original.count>=180);
    for(int i=0;i<original.count;i++) {
        assert(original.times[i]==optimized.times[i]); assert(original.hashes[i]==optimized.hashes[i]);
    }
    decode(argv[1],AV_CPU_FLAG_ARMV6,1,&referenceOnly);
    assert(referenceOnly.count<original.count && referenceOnly.nonkeys>=24);
    for(int i=0;i<referenceOnly.count;i++) {
        int found=0;
        for(int j=0;j<original.count;j++) if(referenceOnly.times[i]==original.times[j]) {
            assert(referenceOnly.hashes[i]==original.hashes[j]); found=1; break;
        }
        assert(found);
    }
    printf("30 fps H.264: %d identical decoded pictures; reference policy preserves %d pictures, %d non-key.\n",
        original.count,referenceOnly.count,referenceOnly.nonkeys);
    printf("Decoder CPU seconds: generic %.3f, ARM11 %.3f, ARM11 non-reference discard %.3f.\n",
        original.decode,optimized.decode,referenceOnly.decode);
    forward_seeks(argv[1]); return 0;
}
