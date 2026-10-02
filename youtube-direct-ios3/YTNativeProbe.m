#import "YTNativeProbe.h"
#import "YTMediaSource.h"
#include "YTVideoDecoder.h"
#include <libavformat/avformat.h>
#include <libavutil/mem.h>
#include <errno.h>
typedef struct { YTMediaSource *source; int64_t position; } YTProbeReader;
static int YTProbeRead(void *opaque,uint8_t *bytes,int count) {
    YTProbeReader *reader=opaque;
    int result=[reader->source readAtOffset:reader->position into:bytes count:count];
    if(result<=0) return result<0 ? AVERROR(EIO) : AVERROR_EOF;
    reader->position+=result; return result;
}
static int64_t YTProbeSeek(void *opaque,int64_t offset,int whence) {
    YTProbeReader *reader=opaque;
    if(whence==AVSEEK_SIZE) return [reader->source length];
    whence &= ~AVSEEK_FORCE;
    if(whence==SEEK_CUR) offset+=reader->position;
    else if(whence==SEEK_END) offset+=[reader->source length];
    else if(whence!=SEEK_SET) return AVERROR(EINVAL);
    if(offset<0 || offset>[reader->source length]) return AVERROR(EINVAL);
    reader->position=offset; return offset;
}
NSDictionary *YTNativeStreamInfo(NSDictionary *streams) {
    if(![[streams objectForKey:@"combined"] boolValue]) return nil;
    YTMediaSource *source=[streams objectForKey:@"videoSource"];
    if(!source) source=[[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"videoURL"] length:[[streams objectForKey:@"videoLength"] longLongValue] userAgent:[streams objectForKey:@"userAgent"]] autorelease];
    YTProbeReader reader={source,0}; av_register_all();
    AVFormatContext *format=avformat_alloc_context();
    uint8_t *bytes=av_malloc(32768);
    AVIOContext *io=bytes ? avio_alloc_context(bytes,32768,0,&reader,YTProbeRead,NULL,YTProbeSeek) : NULL;
    if(!format || !io) { if(format) avformat_free_context(format); if(io) { av_free(io->buffer); av_free(io); } else av_free(bytes); return nil; }
    format->pb=io; format->flags|=AVFMT_FLAG_CUSTOM_IO; format->probesize=65536;
    NSDictionary *result=nil;
    if(avformat_open_input(&format,NULL,NULL,NULL)==0 && YTReadVideoMetadata(format)>=0) {
        AVStream *video=NULL; AVCodecContext *audio=NULL;
        for(unsigned i=0;i<format->nb_streams;i++) {
            if(format->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO) video=format->streams[i];
            if(format->streams[i]->codec->codec_type==AVMEDIA_TYPE_AUDIO) audio=format->streams[i]->codec;
        }
        if(video && audio) {
            AVCodecContext *codec=video->codec;
            int profile=codec->profile,level=codec->level;
            if(codec->extradata_size>=4 && codec->extradata[0]==1) { profile=codec->extradata[1]; level=codec->extradata[3]; }
            BOOL supportedVideo=codec->codec_id==AV_CODEC_ID_H264 && profile==66 && level>0 && level<=30;
            if(codec->codec_id==AV_CODEC_ID_MPEG4) {
                // MPEG-4 Visual Object Sequence: Simple Profile levels 1-6.
                // Reject Advanced Simple rather than assuming every mp4v is supported.
                for(int i=0;i+4<codec->extradata_size;i++) {
                    if(!codec->extradata[i] && !codec->extradata[i+1] && codec->extradata[i+2]==1 && codec->extradata[i+3]==0xb0) {
                        level=codec->extradata[i+4]; profile=level>>4;
                        supportedVideo=level>=1 && level<=6; break;
                    }
                }
            }
            int aacObject=audio->extradata_size>=2 ? audio->extradata[0]>>3 : 0;
            double fps=video->avg_frame_rate.den ? av_q2d(video->avg_frame_rate) : 0;
            BOOL eligible=supportedVideo &&
                codec->width>0 && codec->height>0 && codec->width<=640 && codec->height<=480 && fps<=30.1 &&
                audio->codec_id==AV_CODEC_ID_AAC && aacObject==2 && audio->channels>0 && audio->channels<=2 &&
                audio->sample_rate>0 && audio->sample_rate<=48000 && audio->bit_rate<=160000 &&
                (format->bit_rate<=0 || format->bit_rate<=1700000);
            result=[NSDictionary dictionaryWithObjectsAndKeys:
                [NSNumber numberWithBool:eligible],@"eligible",[NSNumber numberWithInt:profile],@"profile",
                [NSNumber numberWithInt:level],@"level",
                [NSNumber numberWithDouble:fps],@"fps",
                [NSNumber numberWithInt:codec->width],@"width",[NSNumber numberWithInt:codec->height],@"height",[NSNumber numberWithLongLong:[source length]],@"length",nil];
        }
    }
    if(format) avformat_close_input(&format);
    av_free(io->buffer); av_free(io);
    return result;
}
