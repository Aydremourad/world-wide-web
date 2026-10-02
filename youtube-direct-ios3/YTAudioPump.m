#import "YTAudioPump.h"
#import "YTAudioFile.h"
#import "YTMediaSource.h"
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <math.h>

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
            audio->returnedBuffers++;
            audio->playedFrames+=buffer->mAudioDataByteSize/audio->format.mBytesPerFrame;
            if (!audio->pending && audio->started && !audio->eof) audio->starved = YES;
            pthread_cond_signal(&audio->ready);
            break;
        }
    }
    pthread_mutex_unlock(&audio->mutex);
}
double YTAudioMediaTime(YTAudio *audio) {
    if(!audio || !audio->syncReady || audio->format.mSampleRate<=0) return 0;
    double raw=audio->sink.clock ? audio->sink.clock(audio->sink.context) : -1;
    pthread_mutex_lock(&audio->mutex);
    double rate=audio->format.mSampleRate;
    double played=audio->playedFrames/rate, decoded=audio->decodedFrames/rate;
    double media=audio->mediaTime;
    if(!audio->pending) {
        // Some old queues keep their device clock moving through silence.
        // Media time must stop at the audio actually consumed, not that clock.
        media=played; audio->mediaClockReady=NO;
    } else if(!(audio->paused && *audio->paused) && raw>=0) {
        if(!audio->mediaClockReady || raw<audio->rawPrevious-1) {
            audio->rawBase=raw; audio->mediaBase=media>played ? media : played;
            audio->mediaClockReady=YES;
        }
        media=audio->mediaBase+(raw-audio->rawBase)/rate;
        // A clock running without callbacks cannot run video past unheard audio.
        double limit=played+YT_AUDIO_BUFFER_BYTES/(audio->format.mBytesPerFrame*rate);
        if(limit>decoded) limit=decoded;
        if(media>limit) media=limit;
        if(media<played) media=played;
        audio->rawPrevious=raw;
    } else if(!(audio->paused && *audio->paused)) media=played;
    if(media<audio->mediaTime) media=audio->mediaTime;
    audio->mediaTime=media;
    pthread_mutex_unlock(&audio->mutex);
    return audio->startTime + media;
}
BOOL YTAudioIsDrained(YTAudio *audio) {
    pthread_mutex_lock(&audio->mutex); BOOL drained=audio->eof && !audio->pending; pthread_mutex_unlock(&audio->mutex);
    return drained;
}
static double YTAudioWallTime(void) {
    struct timeval now; gettimeofday(&now, NULL);
    return now.tv_sec + now.tv_usec / 1000000.0;
}
static void YTAudioRecover(YTAudio *audio) {
    if (!audio->started || YTAudioStopped(audio)) return;
    YTAudioMediaTime(audio);
    double now = YTAudioWallTime();
    if (audio->paused && *audio->paused) {
        if(!audio->heldForPause) {
            OSStatus status=audio->sink.pause ? audio->sink.pause(audio->sink.context) : noErr;
            if(status!=noErr) { audio->error=status; audio->failed=YES; }
            audio->heldForPause=YES;
        }
        audio->lastAdvance=audio->lastBufferAdvance=now; return;
    }
    if(audio->heldForPause) {
        OSStatus status=audio->sink.start(audio->sink.context);
        if(status!=noErr) { audio->error=status; audio->failed=YES; return; }
        audio->heldForPause=NO;
        pthread_mutex_lock(&audio->mutex); audio->mediaClockReady=NO; pthread_mutex_unlock(&audio->mutex);
        audio->lastAdvance=audio->lastBufferAdvance=now;
        if(audio->eof) audio->sink.drain(audio->sink.context);
    }
    double clock = audio->sink.clock ? audio->sink.clock(audio->sink.context) : -1;
    if (clock >= 0 && clock < audio->lastClock - 1.0) { audio->lastClock=clock; audio->lastAdvance=now; }
    if (!audio->lastAdvance || clock > audio->lastClock + 0.005) {
        audio->lastClock = clock; audio->lastAdvance = now; audio->stalledRestarts = 0;
    }
    pthread_mutex_lock(&audio->mutex);
    unsigned pending = audio->pending;
    unsigned returned=audio->returnedBuffers;
    pthread_mutex_unlock(&audio->mutex);
    if (!audio->lastBufferAdvance || returned!=audio->lastReturned) {
        audio->lastReturned=returned; audio->lastBufferAdvance=now;
    }
    if (!pending || (pending < 3 && !audio->eof)) return;
    double bufferDuration=YT_AUDIO_BUFFER_BYTES / (audio->format.mBytesPerFrame * audio->format.mSampleRate);
    double callbackLimit=bufferDuration*2+1; if(callbackLimit<2) callbackLimit=2;
    BOOL stuck = (clock >= 0 && now - audio->lastAdvance > 2.0) || now-audio->lastBufferAdvance>callbackLimit;
    BOOL running=audio->sink.running(audio->sink.context);
    if (audio->starved || !running || stuck) {
        // Start alone can be a no-op on an old queue that still reports running.
        // Pause preserves queued packets; Reset would discard them.
        OSStatus status = running && audio->sink.pause ? audio->sink.pause(audio->sink.context) : noErr;
        if (status == noErr) status = audio->sink.start(audio->sink.context);
        pthread_mutex_lock(&audio->mutex); audio->mediaClockReady=NO; pthread_mutex_unlock(&audio->mutex);
        if (status != noErr || (stuck && ++audio->stalledRestarts > 3)) {
            audio->error = status != noErr ? status : kAudioFileUnspecifiedError;
            audio->failed = YES;
        } else {
            audio->starved = NO; audio->lastAdvance = audio->lastBufferAdvance = now; audio->lastClock = clock;
            if (audio->eof) audio->sink.drain(audio->sink.context);
        }
    }
}
static OSStatus YTConverterInput(AudioConverterRef converter, UInt32 *packets,
    AudioBufferList *data, AudioStreamPacketDescription **descriptions, void *opaque) {
    YTAudio *audio=opaque;
    if(YTAudioStopped(audio)) { *packets=0; return noErr; }
    if(*packets>audio->packetsPerBuffer) *packets=audio->packetsPerBuffer;
    UInt32 bytes=YT_AUDIO_BUFFER_BYTES;
    OSStatus status=AudioFileReadPackets(audio->file,false,&bytes,audio->descriptions,audio->packet,packets,audio->compressed);
    if(status!=noErr && status!=(OSStatus)-39) return status;
    audio->packet+=*packets;
    data->mNumberBuffers=1; data->mBuffers[0].mNumberChannels=audio->inputFormat.mChannelsPerFrame;
    data->mBuffers[0].mData=audio->compressed; data->mBuffers[0].mDataByteSize=bytes;
    if(descriptions) *descriptions=audio->descriptions;
    return noErr;
}
static OSStatus YTProduceAudio(YTAudio *audio, unsigned slot) {
    AudioQueueBufferRef buffer=audio->buffers[slot];
    AudioBufferList data; memset(&data,0,sizeof(data)); data.mNumberBuffers=1;
    data.mBuffers[0].mNumberChannels=audio->format.mChannelsPerFrame;
    data.mBuffers[0].mData=buffer->mAudioData; data.mBuffers[0].mDataByteSize=buffer->mAudioDataBytesCapacity;
    UInt32 frames=buffer->mAudioDataBytesCapacity/audio->format.mBytesPerFrame;
    OSStatus status=AudioConverterFillComplexBuffer(audio->converter,YTConverterInput,audio,&frames,&data,NULL);
    if(YTAudioStopped(audio)) return noErr;
    if(status!=noErr && status!=(OSStatus)-39) return status;
    if(!frames) {
        audio->eof=YES;
        if(audio->started) audio->sink.drain(audio->sink.context);
        return noErr;
    }
    // Seek to an independently decodable AAC packet, then remove the PCM
    // before the requested sample. Never enqueue audio from before the seek.
    if(audio->discardFrames) {
        UInt32 discard=audio->discardFrames < frames ? audio->discardFrames : frames;
        frames-=discard; audio->discardFrames-=discard;
        data.mBuffers[0].mDataByteSize=frames*audio->format.mBytesPerFrame;
        memmove(buffer->mAudioData,(char *)buffer->mAudioData+discard*audio->format.mBytesPerFrame,
            data.mBuffers[0].mDataByteSize);
        if(!frames) return YTProduceAudio(audio,slot);
    }
    buffer->mAudioDataByteSize=data.mBuffers[0].mDataByteSize;
    pthread_mutex_lock(&audio->mutex); audio->decodedFrames+=frames; audio->pending++; pthread_mutex_unlock(&audio->mutex);
    status=audio->sink.enqueue(audio->sink.context,buffer,frames,NULL);
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
        if (slot < 0) continue;
        NSAutoreleasePool *chunkPool = [[NSAutoreleasePool alloc] init];
        OSStatus status = YTProduceAudio(audio, (unsigned)slot);
        if (status != noErr && !YTAudioStopped(audio)) { audio->error = status; audio->failed = YES; }
        [chunkPool release];
    }
    [pool release];
    return NULL;
}
static void *YTAudioMonitor(void *opaque) {
    YTAudio *audio=opaque;
    // Recovery must remain active even while the producer is awaiting HTTPS.
    while(!YTAudioStopped(audio) && !audio->failed) {
        YTAudioRecover(audio);
        struct timespec delay={0,100000000}; nanosleep(&delay,NULL);
    }
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
    UInt32 size=sizeof(audio->inputFormat);
    result=AudioFileGetProperty(audio->file,kAudioFilePropertyDataFormat,&size,&audio->inputFormat);
    if(result!=noErr) return result;
    if(audio->inputFormat.mFormatID!=kAudioFormatMPEG4AAC || audio->inputFormat.mSampleRate<=0 ||
       audio->inputFormat.mChannelsPerFrame<1 || audio->inputFormat.mChannelsPerFrame>2)
        return kAudioFileUnsupportedDataFormatError;
    if(!isfinite(audio->startTime) || audio->startTime<0) audio->startTime=0;
    UInt32 packetFrames=audio->inputFormat.mFramesPerPacket;
    if(!packetFrames) return kAudioFileUnsupportedDataFormatError;
    UInt64 target=(UInt64)llround(audio->startTime*audio->inputFormat.mSampleRate);
    audio->packet=(SInt64)(target/packetFrames);
    audio->discardFrames=(UInt32)(target%packetFrames);
    UInt32 maximum=0; size=sizeof(maximum);
    result=AudioFileGetProperty(audio->file,kAudioFilePropertyPacketSizeUpperBound,&size,&maximum);
    if(result!=noErr || !maximum || maximum>YT_AUDIO_BUFFER_BYTES) return kAudioFileUnspecifiedError;
    audio->packetsPerBuffer=YT_AUDIO_BUFFER_BYTES/maximum;
    if(audio->packetsPerBuffer>64) audio->packetsPerBuffer=64;
    audio->descriptions=calloc(audio->packetsPerBuffer,sizeof(AudioStreamPacketDescription));
    audio->compressed=malloc(YT_AUDIO_BUFFER_BYTES);
    if(!audio->descriptions || !audio->compressed) return kAudioFileUnspecifiedError;
    memset(&audio->format,0,sizeof(audio->format));
    audio->format.mSampleRate=audio->inputFormat.mSampleRate;
    audio->format.mFormatID=kAudioFormatLinearPCM;
    audio->format.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    audio->format.mChannelsPerFrame=audio->inputFormat.mChannelsPerFrame;
    audio->format.mBitsPerChannel=16; audio->format.mFramesPerPacket=1;
    audio->format.mBytesPerPacket=audio->format.mBytesPerFrame=2*audio->format.mChannelsPerFrame;
    result=AudioConverterNew(&audio->inputFormat,&audio->format,&audio->converter);
    if(result!=noErr) return result;
    UInt32 cookieSize=0;
    if(AudioFileGetPropertyInfo(audio->file,kAudioFilePropertyMagicCookieData,&cookieSize,NULL)==noErr && cookieSize) {
        void *cookie=malloc(cookieSize); if(!cookie) return kAudioFileUnspecifiedError;
        result=AudioFileGetProperty(audio->file,kAudioFilePropertyMagicCookieData,&cookieSize,cookie);
        if(result==noErr) result=AudioConverterSetProperty(audio->converter,kAudioConverterDecompressionMagicCookie,cookieSize,cookie);
        free(cookie); if(result!=noErr) return result;
    }
    return noErr;
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
    if(!YTAudioStopped(audio)) {
        if(pthread_create(&audio->monitor,NULL,YTAudioMonitor,audio)) return kAudioFileUnspecifiedError;
        audio->monitorCreated=YES;
    }
    return noErr;
}
static OSStatus YTEnqueue(void *context, AudioQueueBufferRef buffer, UInt32 packets, AudioStreamPacketDescription *descriptions) {
    return AudioQueueEnqueueBuffer((AudioQueueRef)context, buffer, 0, NULL);
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
    if(audio->monitorCreated) { pthread_join(audio->monitor,NULL); audio->monitorCreated=NO; }
    if (audio->queue) { AudioQueueStop(audio->queue, true); AudioQueueDispose(audio->queue, true); audio->queue = NULL; }
    if (audio->converter) { AudioConverterDispose(audio->converter); audio->converter=NULL; }
    free(audio->compressed); audio->compressed=NULL;
    if (audio->file) { AudioFileClose(audio->file); audio->file = NULL; }
    free(audio->descriptions); audio->descriptions = NULL;
    if (audio->syncReady) {
        pthread_cond_destroy(&audio->ready); pthread_mutex_destroy(&audio->mutex); audio->syncReady = NO;
    }
}
