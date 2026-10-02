#include "YTVideoDecoder.h"
#include <libavutil/mem.h>
#include <errno.h>
#include <string.h>

static int YTAllowedVideoSize(int width, int height) {
    return width > 0 && height > 0 && width <= 640 && height <= 640 && width * height <= 307200;
}
int YTOpenH264Decoder(AVCodecContext *codec) {
    if (!codec || codec->codec_id != AV_CODEC_ID_H264 || !YTAllowedVideoSize(codec->width, codec->height))
        return AVERROR(EINVAL);
    codec->thread_count = 1;
    codec->flags2 |= AV_CODEC_FLAG2_FAST;
    if (codec->width * codec->height > 38400) {
        // Retain all reference pictures; omit non-reference B pictures to reduce
        // work on ARMv6. The audio clock still determines presentation time.
        codec->skip_frame = AVDISCARD_NONREF;
        codec->skip_loop_filter = AVDISCARD_ALL;
    } else codec->skip_loop_filter = AVDISCARD_NONREF;
    AVCodec *decoder = avcodec_find_decoder(codec->codec_id);
    return decoder ? avcodec_open2(codec, decoder, NULL) : AVERROR_DECODER_NOT_FOUND;
}
int YTConvertVideoFrame(YTVideoImage *image, const AVFrame *frame) {
    if (!YTAllowedVideoSize(frame->width, frame->height)) return AVERROR(EINVAL);
    double scale = 1.0;
    if (frame->width > 256) scale = 256.0 / frame->width;
    if (frame->height * scale > 144) scale = 144.0 / frame->height;
    int width = (int)(frame->width * scale), height = (int)(frame->height * scale);
    if (width < 1 || height < 1) return AVERROR(EINVAL);
    int needed = width * height * 2;
    if (needed != image->pixelBytes) {
        av_free(image->pixels);
        image->pixels = av_malloc(needed);
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
    av_free(image->pixels);
    memset(image, 0, sizeof(*image));
}
