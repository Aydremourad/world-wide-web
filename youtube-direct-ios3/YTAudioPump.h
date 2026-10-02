#ifndef YT_AUDIO_PUMP_H
#define YT_AUDIO_PUMP_H
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
@class YTMediaSource;
#define YT_AUDIO_BUFFERS 12
#define YT_AUDIO_BUFFER_BYTES 65536

typedef struct {
    void *context;
    OSStatus (*enqueue)(void *, AudioQueueBufferRef, UInt32, AudioStreamPacketDescription *);
    BOOL (*running)(void *);
    OSStatus (*start)(void *);
    void (*drain)(void *);
    OSStatus (*pause)(void *);
    double (*clock)(void *);
} YTAudioSink;

typedef struct {
    YTMediaSource *source;
    AudioFileID file;
    AudioConverterRef converter;
    AudioStreamBasicDescription inputFormat;
    void *compressed;
    UInt64 decodedFrames, playedFrames;
    double mediaBase, rawBase, rawPrevious, mediaTime;
    BOOL mediaClockReady;
    AudioQueueRef queue;
    AudioStreamBasicDescription format;
    AudioStreamPacketDescription *descriptions;
    AudioQueueBufferRef buffers[YT_AUDIO_BUFFERS];
    BOOL available[YT_AUDIO_BUFFERS];
    SInt64 packet;
    UInt32 packetsPerBuffer;
    volatile BOOL *stop;
    volatile BOOL *paused;
    volatile BOOL failed;
    volatile BOOL eof;
    volatile BOOL started;
    volatile BOOL starved;
    volatile BOOL localStop;
    OSStatus error;
    pthread_mutex_t mutex;
    pthread_cond_t ready;
    pthread_t worker, monitor;
    BOOL syncReady;
    BOOL workerCreated, monitorCreated;
    unsigned pending;
    unsigned returnedBuffers, lastReturned;
    double lastBufferAdvance;
    YTAudioSink sink;
    double lastClock;
    double lastAdvance;
    unsigned stalledRestarts;
} YTAudio;

OSStatus YTAudioOpen(YTAudio *audio);
OSStatus YTAudioBegin(YTAudio *audio);
OSStatus YTPrepareAudio(YTAudio *audio);
void YTAudioBufferReturned(void *opaque, AudioQueueRef queue, AudioQueueBufferRef buffer);
double YTAudioMediaTime(YTAudio *audio);
BOOL YTAudioIsDrained(YTAudio *audio);
void YTShutdownAudio(YTAudio *audio);
#endif
