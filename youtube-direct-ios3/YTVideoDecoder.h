#ifndef YT_VIDEO_DECODER_H
#define YT_VIDEO_DECODER_H
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>

#define YT_VIDEO_IMAGE_BUFFERS 5
typedef struct {
    struct SwsContext *scaler;
    uint8_t *pixels;
    uint8_t *buffers[YT_VIDEO_IMAGE_BUFFERS];
    int pixelBytes;
    unsigned bufferIndex;
    int width;
    int height;
} YTVideoImage;

int YTOpenH264Decoder(AVCodecContext *codec);
int YTReadVideoMetadata(AVFormatContext *format);
double YTVideoTimeOrigin(AVStream *stream);
int YTSeekVideoToTime(AVFormatContext *format,int track,AVCodecContext *codec,double seconds);
int YTAdvanceVideoToTime(AVFormatContext *format,int track,AVCodecContext *codec,double seconds,double origin);
int YTConvertVideoFrame(YTVideoImage *image, const AVFrame *frame);
void YTFreeVideoImage(YTVideoImage *image);
#endif
