#include "YTVideoDecoder.h"
#include <libavutil/mem.h>
#include <errno.h>
#include <string.h>
#include <math.h>

static int YTAllowedVideoSize(int width, int height) {
    return width > 0 && height > 0 && width <= 640 && height <= 640 && width * height <= 307200;
}
int YTReadVideoMetadata(AVFormatContext *format) {
    if(!format) return AVERROR(EINVAL);
    for(unsigned i=0;i<format->nb_streams;i++) {
        AVCodecContext *codec=format->streams[i]->codec;
        if(codec->codec_type==AVMEDIA_TYPE_VIDEO && (codec->width<=0 || codec->height<=0)) {
            // The old MOV demuxer leaves mp4v dimensions unset until its VOL
            // header is parsed. Probe bounded samples before choosing a player.
            format->probesize=65536; format->max_analyze_duration=AV_TIME_BASE;
            return avformat_find_stream_info(format,NULL);
        }
    }
    return 0;
}
int YTOpenH264Decoder(AVCodecContext *codec) {
    if (!codec || (codec->codec_id != AV_CODEC_ID_H264 && codec->codec_id != AV_CODEC_ID_MPEG4) || !YTAllowedVideoSize(codec->width, codec->height))
        return AVERROR(EINVAL);
    codec->thread_count = 1;
    codec->flags2 |= AV_CODEC_FLAG2_FAST;
    int mainProfile=codec->codec_id==AV_CODEC_ID_H264 && codec->extradata_size>=4 &&
        codec->extradata[0]==1 && codec->extradata[1]!=66;
    if (codec->codec_id == AV_CODEC_ID_H264) {
        if (codec->width * codec->height > 38400) codec->skip_frame = AVDISCARD_NONREF;
        else codec->skip_frame = AVDISCARD_DEFAULT;
        // Deblocking is one of the most expensive H.264 post-decode steps on
        // ARM11. At 144p, disabling it is a better trade than dropping frames.
        codec->skip_loop_filter = AVDISCARD_ALL;
    } else codec->skip_loop_filter = AVDISCARD_NONREF;
    AVCodec *decoder = avcodec_find_decoder(codec->codec_id);
    return decoder ? avcodec_open2(codec, decoder, NULL) : AVERROR_DECODER_NOT_FOUND;
}
double YTVideoTimeOrigin(AVStream *stream) {
    return stream->start_time==AV_NOPTS_VALUE ? 0 : stream->start_time*av_q2d(stream->time_base);
}
int YTSeekVideoToTime(AVFormatContext *format,int track,AVCodecContext *codec,double seconds) {
    if(!format || !codec || track<0 || track>=(int)format->nb_streams || !isfinite(seconds) || seconds<0)
        return AVERROR(EINVAL);
    AVStream *stream=format->streams[track];
    int64_t stamp=(int64_t)llround((seconds+YTVideoTimeOrigin(stream))/av_q2d(stream->time_base));
    int result=av_seek_frame(format,track,stamp,AVSEEK_FLAG_BACKWARD);
    if(result>=0) avcodec_flush_buffers(codec);
    return result;
}
static int YTScaledClip8(int value) {
#if defined(__arm__) && (defined(__ARM_ARCH_6__) || defined(__ARM_ARCH_6J__) || defined(__ARM_ARCH_6K__) || defined(__ARM_ARCH_6ZK__) || defined(__ARM_ARCH_6Z__))
    unsigned clipped;
    // ARM11 performs the signed shift and unsigned saturation in one instruction.
    __asm__("usat %0, #8, %1, asr #8" : "=r"(clipped) : "r"(value));
    return clipped;
#else
    value >>= 8;
    if (value < 0) return 0;
    if (value > 255) return 255;
    return value;
#endif
}
static uint16_t YTPackRGB565(int yTerm,int rAdd,int gAdd,int bAdd) {
    int r=YTScaledClip8(yTerm+rAdd+128);
    int g=YTScaledClip8(yTerm+gAdd+128);
    int b=YTScaledClip8(yTerm+bAdd+128);
    return (uint16_t)(((r&0xf8)<<8)|((g&0xfc)<<3)|(b>>3));
}
static int YTConvert420ToRGB565(YTVideoImage *image,const AVFrame *frame) {
    static int ready=0,yTable[256],rTable[256],guTable[256],gvTable[256],bTable[256];
    if(!ready) {
        for(int i=0;i<256;i++) {
            yTable[i]=298*(i-16); rTable[i]=409*(i-128);
            guTable[i]=-100*(i-128); gvTable[i]=-208*(i-128); bTable[i]=516*(i-128);
        }
        ready=1;
    }
    int width=frame->width,height=frame->height,needed=width*height*2;
    if(needed!=image->pixelBytes) {
        free(image->pixels); image->pixels=malloc(needed); image->pixelBytes=needed;
    }
    if(!image->pixels) return AVERROR(ENOMEM);
    uint16_t *out=(uint16_t *)image->pixels;
    for(int row=0;row<height;row+=2) {
        const uint8_t *y0=frame->data[0]+row*frame->linesize[0];
        const uint8_t *y1=row+1<height ? frame->data[0]+(row+1)*frame->linesize[0] : y0;
        const uint8_t *u=frame->data[1]+(row/2)*frame->linesize[1];
        const uint8_t *v=frame->data[2]+(row/2)*frame->linesize[2];
        uint16_t *o0=out+row*width;
        uint16_t *o1=row+1<height ? out+(row+1)*width : o0;
        for(int col=0;col<width;col+=2) {
            int chroma=col/2,uu=u[chroma],vv=v[chroma];
            int ra=rTable[vv],ga=guTable[uu]+gvTable[vv],ba=bTable[uu];
            o0[col]=YTPackRGB565(yTable[y0[col]],ra,ga,ba);
            if(col+1<width) o0[col+1]=YTPackRGB565(yTable[y0[col+1]],ra,ga,ba);
            if(row+1<height) {
                o1[col]=YTPackRGB565(yTable[y1[col]],ra,ga,ba);
                if(col+1<width) o1[col+1]=YTPackRGB565(yTable[y1[col+1]],ra,ga,ba);
            }
        }
    }
    image->width=width; image->height=height;
    return 0;
}
int YTConvertVideoFrame(YTVideoImage *image, const AVFrame *frame) {
    if (!YTAllowedVideoSize(frame->width, frame->height)) return AVERROR(EINVAL);
    if(frame->format==AV_PIX_FMT_YUV420P && frame->width<=256 && frame->height<=144)
        return YTConvert420ToRGB565(image,frame);
    double scale = 1.0;
    if (frame->width > 256) scale = 256.0 / frame->width;
    if (frame->height * scale > 144) scale = 144.0 / frame->height;
    int width = (int)(frame->width * scale), height = (int)(frame->height * scale);
    if (width < 1 || height < 1) return AVERROR(EINVAL);
    int needed = width * height * 2;
    if (needed != image->pixelBytes) {
        free(image->pixels);
        image->pixels = malloc(needed);
        image->pixelBytes = needed;
    }
    if (!image->pixels) return AVERROR(ENOMEM);
    image->scaler = sws_getCachedContext(image->scaler, frame->width, frame->height,
        (enum AVPixelFormat)frame->format, width, height, AV_PIX_FMT_RGB565LE,
        SWS_FAST_BILINEAR, NULL, NULL, NULL);
    if (!image->scaler) return AVERROR(ENOMEM);
    uint8_t *destination[4] = {image->pixels, NULL, NULL, NULL};
    int strides[4] = {width * 2, 0, 0, 0};
    int result = sws_scale(image->scaler, (const uint8_t * const *)frame->data, frame->linesize,
        0, frame->height, destination, strides);
    if (result <= 0) return AVERROR(EINVAL);
    image->width = width; image->height = height;
    return 0;
}
void YTFreeVideoImage(YTVideoImage *image) {
    if (image->scaler) sws_freeContext(image->scaler);
    free(image->pixels);
    memset(image, 0, sizeof(*image));
}
