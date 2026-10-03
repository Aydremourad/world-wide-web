#include "../YTVideoDecoder.h"
#include "../YTADTS.h"
#include <libavutil/mem.h>
#include <assert.h>
#include <stdio.h>

static int read_fixture(void *opaque,uint8_t *bytes,int count) {
    int got=(int)fread(bytes,1,(size_t)count,(FILE *)opaque);
    return got ? got : AVERROR_EOF;
}

int main(int argc,char **argv) {
    assert(argc==2); av_register_all();
    FILE *file=fopen(argv[1],"rb"); assert(file);
    AVFormatContext *format=avformat_alloc_context(); assert(format);
    AVIOContext *io=avio_alloc_context(av_malloc(32768),32768,0,file,read_fixture,NULL,NULL);
    assert(io); format->pb=io; format->flags|=AVFMT_FLAG_CUSTOM_IO;
    assert(avformat_open_input(&format,NULL,NULL,NULL)>=0);
    assert(YTReadVideoMetadata(format)>=0);
    int video=-1;
    for(unsigned i=0;i<format->nb_streams;i++)
        if(format->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO) video=(int)i;
    assert(video>=0);
    AVCodecContext *codec=format->streams[video]->codec;
    assert(codec->width==256 && codec->height==144 && codec->profile==77);
    assert(YTOpenH264Decoder(codec)>=0 && codec->skip_frame==AVDISCARD_DEFAULT);
    AVFrame *frame=av_frame_alloc(); AVPacket packet;
    int decoded=0,aac=0;
    while(av_read_frame(format,&packet)>=0) {
        if(packet.stream_index==video) {
            int got=0; assert(avcodec_decode_video2(codec,frame,&got,&packet)>=0);
            decoded+=got;
        } else if(format->streams[packet.stream_index]->codec->codec_id==AV_CODEC_ID_AAC) {
            unsigned inside=0;
            while(inside<(unsigned)packet.size) {
                YTADTSFrame h;
                assert(YTReadADTSHeader(packet.data+inside,packet.size-inside,&h)==1);
                assert(h.rate==44100 && h.channels==2); inside+=h.frameBytes; aac++;
            }
        }
        av_free_packet(&packet);
    }
    av_init_packet(&packet); packet.data=NULL; packet.size=0;
    for(int i=0;i<16;i++) {
        int got=0; assert(avcodec_decode_video2(codec,frame,&got,&packet)>=0);
        if(!got) break; decoded++;
    }
    assert(decoded==240 && aac>=340 && aac<=350);
    printf("144p HLS passed: %d/240 Main-profile pictures and %d AAC-LC access units, including B pictures.\n",decoded,aac);
    av_frame_free(&frame); avcodec_close(codec); avformat_close_input(&format);
    av_free(io->buffer); av_free(io); fclose(file);
    return 0;
}
