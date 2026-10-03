#ifndef YT_ADTS_H
#define YT_ADTS_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    unsigned rate, channels, headerBytes, frameBytes;
    uint8_t cookie[2];
} YTADTSFrame;

/* 1 = complete AAC-LC frame, 0 = need more bytes, -1 = unsupported/header error. */
static int YTReadADTSHeader(const uint8_t *bytes, size_t count, YTADTSFrame *frame) {
    static const unsigned rates[13] = {96000,88200,64000,48000,44100,32000,
        24000,22050,16000,12000,11025,8000,7350};
    if(count < 7) return 0;
    if(bytes[0] != 0xff || (bytes[1] & 0xf6) != 0xf0) return -1;
    unsigned object = (bytes[2] >> 6) + 1;
    unsigned frequency = (bytes[2] >> 2) & 15;
    unsigned channels = ((bytes[2] & 1) << 2) | (bytes[3] >> 6);
    unsigned header = (bytes[1] & 1) ? 7 : 9;
    unsigned size = ((bytes[3] & 3) << 11) | (bytes[4] << 3) | (bytes[5] >> 5);
    if(object != 2 || frequency >= 13 || channels < 1 || channels > 2 ||
       (bytes[6] & 3) || size <= header) return -1;
    frame->rate = rates[frequency]; frame->channels = channels;
    frame->headerBytes = header; frame->frameBytes = size;
    frame->cookie[0] = (uint8_t)((object << 3) | (frequency >> 1));
    frame->cookie[1] = (uint8_t)(((frequency & 1) << 7) | (channels << 3));
    return count < size ? 0 : 1;
}
#endif
