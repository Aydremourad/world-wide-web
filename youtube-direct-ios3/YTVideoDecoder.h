#ifndef YT_VIDEO_DECODER_H
#define YT_VIDEO_DECODER_H
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>

typedef struct {
    struct SwsContext *scaler;
    uint8_t *pixels;
    int pixelBytes;
    int width;
    int height;
} YTVideoImage;

int YTOpenH264Decoder(AVCodecContext *codec);
int YTConvertVideoFrame(YTVideoImage *image, const AVFrame *frame);
void YTFreeVideoImage(YTVideoImage *image);
#endif
