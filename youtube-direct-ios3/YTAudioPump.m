#import "YTAudioPump.h"
#import "YTAudioFile.h"
#import "YTMediaSource.h"
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static BOOL YTAudioStopped(YTAudio *audio) {
    return audio->localStop || (audio->stop && *audio->stop);
}
void YTAudioBufferReturned(void *opaque, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    YTAudio *audio = opaque;
    if (YTAudioStopped(audio)) return;
    // No file access, network requests or AudioQueue calls on this callback.
    pthread_mutex_lock(&audio->mutex);
    for (unsigned i = 0; i < YT_AUDIO_BUFFERS; i++) {
        if (audio->buffers[i] == buffer && !audio->available[i]) {
            audio->available[i] = YES;
            if (audio->pending) audio->pending--;
            if (!audio->pending && audio->started && !audio->eof) audio->starved = YES;
            pthread_cond_signal(&audio->ready);
            break;
        }
    }
    pthread_mutex_unlock(&audio->mutex);
}
static double YTAudioWallTime(void) {
    struct timeval now; gettimeofday(&now, NULL);
    return now.tv_sec + now.tv_usec / 1000000.0;
}
static void YTAudioRecover(YTAudio *audio) {
    if (!audio->started || YTAudioStopped(audio)) return;
    double now = YTAudioWallTime();
    if (audio->paused && *audio->paused) { audio->lastAdvance = now; return; }
    double clock = audio->sink.clock ? audio->sink.clock(audio->sink.context) : -1;
    if (!audio->lastAdvance || clock > audio->lastClock + 0.005) {
        audio->lastClock = clock; audio->lastAdvance = now; audio->stalledRestarts = 0;
    }
    pthread_mutex_lock(&audio->mutex);
    unsigned pending = audio->pending;
    pthread_mutex_unlock(&audio->mutex);
    if (!pending || (pending < 3 && !audio->eof)) return;
    BOOL stuck = clock >= 0 && now - audio->lastAdvance > 2.0;
    if (audio->starved || !audio->sink.running(audio->sink.context) || stuck) {
        // Start alone can be a no-op on an old queue that still reports running.
        // Pause preserves queued packets; Reset would discard them.
        OSStatus status = audio->sink.pause ? audio->sink.pause(audio->sink.context) : noErr;
        if (status == noErr) status = audio->sink.start(audio->sink.context);
        if (status != noErr || (stuck && ++audio->stalledRestarts > 3)) {
            audio->error = status != noErr ? status : kAudioFileUnspecifiedError;
            audio->failed = YES;
        } else {
            audio->starved = NO; audio->lastAdvance = now; audio->lastClock = clock;
            if (audio->eof) audio->sink.drain(audio->sink.context);
        }
    }
}
static OSStatus YTProduceAudio(YTAudio *audio, unsigned slot) {
    AudioQueueBufferRef buffer = audio->buffers[slot];
    UInt32 bytes = buffer->mAudioDataBytesCapacity;
    UInt32 packets = audio->packetsPerBuffer;
    OSStatus status = AudioFileReadPackets(audio->file, false, &bytes,
        audio->descriptions, audio->packet, &packets, buffer->mAudioData);
    if (YTAudioStopped(audio)) return noErr;
    if (status != noErr && status != (OSStatus)-39) return status;
    if (!packets) {
        audio->eof = YES;
        if (audio->started) {
            YTAudioRecover(audio);
            audio->sink.drain(audio->sink.context);
        }
        return noErr;
    }
    buffer->mAudioDataByteSize = bytes;
    audio->packet += packets;
    pthread_mutex_lock(&audio->mutex);
    audio->pending++;
    pthread_mutex_unlock(&audio->mutex);
    status = audio->sink.enqueue(audio->sink.context, buffer, packets, audio->descriptions);
    if (status == noErr) YTAudioRecover(audio);
    return status;
}
static void *YTAudioProducer(void *opaque) {
    YTAudio *audio = opaque;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.75];
    while (!YTAudioStopped(audio) && !audio->failed) {
        pthread_mutex_lock(&audio->mutex);
        if (audio->eof && !audio->pending) { pthread_mutex_unlock(&audio->mutex); break; }
        int slot = -1;
        for (unsigned i = 0; !audio->eof && i < YT_AUDIO_BUFFERS; i++)
            if (audio->available[i]) { slot = (int)i; audio->available[i] = NO; break; }
        if (slot < 0) {
            struct timeval now; gettimeofday(&now, NULL);
            struct timespec deadline = {now.tv_sec, now.tv_usec * 1000 + 100000000};
            if (deadline.tv_nsec >= 1000000000) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000; }
            pthread_cond_timedwait(&audio->ready, &audio->mutex, &deadline);
        }
        pthread_mutex_unlock(&audio->mutex);
        if (slot < 0) { YTAudioRecover(audio); continue; }
        NSAutoreleasePool *chunkPool = [[NSAutoreleasePool alloc] init];
        OSStatus status = YTProduceAudio(audio, (unsigned)slot);
        if (status != noErr && !YTAudioStopped(audio)) { audio->error = status; audio->failed = YES; }
        [chunkPool release];
    }
    [pool release];
    return NULL;
}
OSStatus YTAudioOpen(YTAudio *audio) {
    if (pthread_mutex_init(&audio->mutex, NULL)) return kAudioFileUnspecifiedError;
    if (pthread_cond_init(&audio->ready, NULL)) {
        pthread_mutex_destroy(&audio->mutex); return kAudioFileUnspecifiedError;
    }
    audio->syncReady = YES;
    OSStatus result = YTOpenAudioFile(audio->source, &audio->file);
    if (result != noErr) return result;
    UInt32 size = sizeof(audio->format);
    result = AudioFileGetProperty(audio->file, kAudioFilePropertyDataFormat, &size, &audio->format);
    if (result != noErr) return result;
    if (audio->format.mFormatID != kAudioFormatMPEG4AAC || audio->format.mSampleRate <= 0)
        return kAudioFileUnsupportedDataFormatError;
    UInt32 maximum = 0; size = sizeof(maximum);
    result = AudioFileGetProperty(audio->file, kAudioFilePropertyPacketSizeUpperBound, &size, &maximum);
    if (result != noErr || !maximum || maximum > YT_AUDIO_BUFFER_BYTES) return kAudioFileUnspecifiedError;
    audio->packetsPerBuffer = YT_AUDIO_BUFFER_BYTES / maximum;
    if (audio->packetsPerBuffer > 64) audio->packetsPerBuffer = 64;
    audio->descriptions = calloc(audio->packetsPerBuffer, sizeof(AudioStreamPacketDescription));
    return audio->descriptions ? noErr : kAudioFileUnspecifiedError;
}
OSStatus YTAudioBegin(YTAudio *audio) {
    for (unsigned i = 0; i < YT_AUDIO_BUFFERS && !YTAudioStopped(audio) && !audio->eof; i++) {
        audio->available[i] = NO;
        OSStatus status = YTProduceAudio(audio, i);
        if (status != noErr) return status;
    }
    if (!audio->eof && !YTAudioStopped(audio)) {
        if (pthread_create(&audio->worker, NULL, YTAudioProducer, audio)) return kAudioFileUnspecifiedError;
        audio->workerCreated = YES;
    }
    return noErr;
}
static OSStatus YTEnqueue(void *context, AudioQueueBufferRef buffer, UInt32 packets, AudioStreamPacketDescription *descriptions) {
    return AudioQueueEnqueueBuffer((AudioQueueRef)context, buffer, packets, descriptions);
}
static BOOL YTRunning(void *context) {
    UInt32 running = 0, size = sizeof(running);
    return AudioQueueGetProperty((AudioQueueRef)context, kAudioQueueProperty_IsRunning, &running, &size) == noErr && running;
}
static OSStatus YTStart(void *context) { return AudioQueueStart((AudioQueueRef)context, NULL); }
static void YTDrain(void *context) { AudioQueueStop((AudioQueueRef)context, false); }
static OSStatus YTPause(void *context) { return AudioQueuePause((AudioQueueRef)context); }
static double YTClock(void *context) {
    AudioTimeStamp time; memset(&time, 0, sizeof(time));
    Boolean changed = false;
    if (AudioQueueGetCurrentTime((AudioQueueRef)context, NULL, &time, &changed) != noErr ||
        !(time.mFlags & kAudioTimeStampSampleTimeValid)) return -1;
    // Sample units suffice for detecting progress; sample rate is constant.
    return time.mSampleTime;
}
OSStatus YTPrepareAudio(YTAudio *audio) {
    OSStatus result = YTAudioOpen(audio);
    if (result != noErr) return result;
    result = AudioQueueNewOutput(&audio->format, YTAudioBufferReturned, audio, NULL, NULL, 0, &audio->queue);
    if (result != noErr) return result;
    audio->sink.context = audio->queue;
    audio->sink.enqueue = YTEnqueue; audio->sink.running = YTRunning;
    audio->sink.start = YTStart; audio->sink.drain = YTDrain;
    audio->sink.pause = YTPause; audio->sink.clock = YTClock;
    UInt32 size = 0;
    if (AudioFileGetPropertyInfo(audio->file, kAudioFilePropertyMagicCookieData, &size, NULL) == noErr && size) {
        void *cookie = malloc(size);
        if (!cookie) return kAudioFileUnspecifiedError;
        result = AudioFileGetProperty(audio->file, kAudioFilePropertyMagicCookieData, &size, cookie);
        if (result == noErr) result = AudioQueueSetProperty(audio->queue, kAudioQueueProperty_MagicCookie, cookie, size);
        free(cookie);
        if (result != noErr) return result;
    }
    for (unsigned i = 0; i < YT_AUDIO_BUFFERS; i++) {
        result = AudioQueueAllocateBuffer(audio->queue, YT_AUDIO_BUFFER_BYTES, &audio->buffers[i]);
        if (result != noErr) return result;
    }
    return YTAudioBegin(audio);
}
void YTShutdownAudio(YTAudio *audio) {
    audio->localStop = YES;
    if (audio->workerCreated) {
        [audio->source cancel];
        pthread_mutex_lock(&audio->mutex); pthread_cond_signal(&audio->ready); pthread_mutex_unlock(&audio->mutex);
        pthread_join(audio->worker, NULL); audio->workerCreated = NO;
    }
    if (audio->queue) { AudioQueueStop(audio->queue, true); AudioQueueDispose(audio->queue, true); audio->queue = NULL; }
    if (audio->file) { AudioFileClose(audio->file); audio->file = NULL; }
    free(audio->descriptions); audio->descriptions = NULL;
    if (audio->syncReady) {
        pthread_cond_destroy(&audio->ready); pthread_mutex_destroy(&audio->mutex); audio->syncReady = NO;
    }
}
