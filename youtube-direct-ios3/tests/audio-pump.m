// Reuse the actual combined-file fixture protocol, not the player UI.
#define main YTCombinedFixtureMain
#include "combined-player.m"
#undef main
#import "YTAudioPump.h"
#include <math.h>

static volatile int LongDelay, LongDelayStarted, LongDelayFinished;
@interface YTSlowMovieProtocol : YTMovieProtocol
@end
@implementation YTSlowMovieProtocol
- (void)startLoading {
    if(__sync_bool_compare_and_swap(&LongDelay,1,0)) {
        LongDelayStarted=1; [NSThread sleepForTimeInterval:5.0]; LongDelayFinished=1;
    }
    if (Requests > 2) [NSThread sleepForTimeInterval:0.15];
    [super startLoading];
}
@end
typedef struct {
    pthread_mutex_t mutex;
    AudioQueueBufferRef buffers[16];
    UInt32 packets[16];
    unsigned count;
    UInt64 consumed, baseConsumed;
    unsigned starts;
    BOOL running;
    BOOL draining;
    BOOL stuck;
    BOOL drifting;
    BOOL compressed;
    UInt32 framesPerPacket;
    double artificialClock;
    unsigned pauses;
} FakeQueue;
static OSStatus YTFakeEnqueue(void *opaque, AudioQueueBufferRef buffer, UInt32 packets,
                        AudioStreamPacketDescription *descriptions) {
    FakeQueue *queue=opaque;
    assert(packets && buffer->mAudioDataByteSize && buffer->mAudioDataByteSize <= YT_AUDIO_BUFFER_BYTES);
    UInt32 frames=packets;
    if(queue->compressed) {
        assert(descriptions!=NULL && queue->framesPerPacket>0);
        frames=packets*queue->framesPerPacket;
    } else assert(descriptions==NULL && buffer->mAudioDataByteSize==packets*4);
    pthread_mutex_lock(&queue->mutex);
    assert(queue->count < 16);
    for (unsigned i=0;i<queue->count;i++) assert(queue->buffers[i] != buffer);
    queue->buffers[queue->count]=buffer; queue->packets[queue->count++]=frames;
    pthread_mutex_unlock(&queue->mutex);
    return noErr;
}
static BOOL YTFakeRunning(void *opaque) {
    FakeQueue *queue=opaque;
    pthread_mutex_lock(&queue->mutex); BOOL value=queue->running; pthread_mutex_unlock(&queue->mutex);
    return value;
}
static OSStatus YTFakeStart(void *opaque) {
    FakeQueue *queue=opaque;
    pthread_mutex_lock(&queue->mutex); queue->running=YES; queue->baseConsumed=queue->consumed; queue->starts++; pthread_mutex_unlock(&queue->mutex);
    return noErr;
}
static OSStatus YTFakePause(void *opaque) {
    FakeQueue *queue=opaque;
    pthread_mutex_lock(&queue->mutex); queue->running=NO; queue->stuck=NO; queue->pauses++; pthread_mutex_unlock(&queue->mutex);
    return noErr;
}
static double YTFakeClock(void *opaque) {
    FakeQueue *queue=opaque;
    pthread_mutex_lock(&queue->mutex); double clock=queue->consumed-queue->baseConsumed;
    if(queue->drifting) { queue->artificialClock+=44100; clock+=queue->artificialClock; } pthread_mutex_unlock(&queue->mutex);
    return clock;
}
static void YTFakeDrain(void *opaque) {
    FakeQueue *queue=opaque;
    pthread_mutex_lock(&queue->mutex); queue->draining=YES; pthread_mutex_unlock(&queue->mutex);
}
static void YTFakeSetUpAtTime(YTAudio *audio, FakeQueue *queue, volatile BOOL *stop, volatile BOOL *paused,double startTime) {
    memset(audio,0,sizeof(*audio)); memset(queue,0,sizeof(*queue));
    pthread_mutex_init(&queue->mutex,NULL);
    audio->startTime=startTime; audio->stop=stop; audio->paused=paused;
    audio->source=[[YTMediaSource alloc] initWithURL:[NSURL URLWithString:@"https://movie.example/combined.mp4"]
        length:[Movie length] userAgent:@"fixture"];
    assert(YTAudioOpen(audio) == noErr);
    audio->sink=(YTAudioSink){queue,YTFakeEnqueue,YTFakeRunning,YTFakeStart,YTFakeDrain,YTFakePause,YTFakeClock};
    for (unsigned i=0;i<YT_AUDIO_BUFFERS;i++) {
        AudioQueueBuffer initial={.mAudioDataBytesCapacity=YT_AUDIO_BUFFER_BYTES,.mAudioData=malloc(YT_AUDIO_BUFFER_BYTES)};
        audio->buffers[i]=malloc(sizeof(initial)); memcpy(audio->buffers[i],&initial,sizeof(initial));
    }
    assert(YTAudioBegin(audio) == noErr && audio->pending>0);
    audio->started=YES; YTFakeStart(queue);
    if(audio->eof) YTFakeDrain(queue);
}
static void YTFakeSetUp(YTAudio *audio,FakeQueue *queue,volatile BOOL *stop,volatile BOOL *paused) {
    YTFakeSetUpAtTime(audio,queue,stop,paused,0);
}
static void YTFakeSetUpDirect(YTAudio *audio,FakeQueue *queue,volatile BOOL *stop,volatile BOOL *paused) {
    memset(audio,0,sizeof(*audio)); memset(queue,0,sizeof(*queue));
    pthread_mutex_init(&queue->mutex,NULL);
    audio->startTime=0; audio->stop=stop; audio->paused=paused;
    audio->source=[[YTMediaSource alloc] initWithURL:[NSURL URLWithString:@"https://movie.example/combined.mp4"]
        length:[Movie length] userAgent:@"fixture"];
    assert(YTAudioOpen(audio)==noErr);
    audio->directAAC=YES; audio->discardFrames=0;
    queue->compressed=YES; queue->framesPerPacket=audio->inputFormat.mFramesPerPacket;
    audio->sink=(YTAudioSink){queue,YTFakeEnqueue,YTFakeRunning,YTFakeStart,YTFakeDrain,YTFakePause,YTFakeClock};
    for(unsigned i=0;i<YT_AUDIO_BUFFERS;i++) {
        AudioQueueBuffer initial={.mAudioDataBytesCapacity=YT_AUDIO_BUFFER_BYTES,.mAudioData=malloc(YT_AUDIO_BUFFER_BYTES)};
        audio->buffers[i]=malloc(sizeof(initial)); memcpy(audio->buffers[i],&initial,sizeof(initial));
    }
    assert(YTAudioBegin(audio)==noErr && audio->pending>0);
    audio->started=YES; YTFakeStart(queue);
    if(audio->eof) YTFakeDrain(queue);
}

static BOOL YTFakeConsume(YTAudio *audio, FakeQueue *queue, double *slowest) {
    pthread_mutex_lock(&queue->mutex);
    AudioQueueBufferRef buffer=NULL;
    if (queue->running && !queue->stuck && queue->count) {
        buffer=queue->buffers[0]; queue->consumed += queue->packets[0];
        for (unsigned i=1;i<queue->count;i++) {
            queue->buffers[i-1]=queue->buffers[i]; queue->packets[i-1]=queue->packets[i];
        }
        if (!--queue->count) queue->running=NO; // Deliberately force underrun.
    }
    BOOL empty=queue->count == 0;
    pthread_mutex_unlock(&queue->mutex);
    if (buffer) {
        double before=[NSDate timeIntervalSinceReferenceDate];
        YTAudioBufferReturned(audio,NULL,buffer);
        double elapsed=[NSDate timeIntervalSinceReferenceDate]-before;
        if (elapsed > *slowest) *slowest=elapsed;
    }
    return empty;
}
static void YTFakeCleanUp(YTAudio *audio, FakeQueue *queue) {
    YTShutdownAudio(audio);
    for (unsigned i=0;i<YT_AUDIO_BUFFERS;i++) {
        free(audio->buffers[i]->mAudioData); free(audio->buffers[i]);
    }
    [audio->source release]; pthread_mutex_destroy(&queue->mutex);
}
int main(int argc,char **argv) {
    assert(argc == 3);
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] retain];
    assert([Movie length] > 1024*1024);
    [NSURLProtocol registerClass:[YTSlowMovieProtocol class]];
    volatile BOOL stop=NO,paused=NO; YTAudio audio; FakeQueue queue;
    YTFakeSetUp(&audio,&queue,&stop,&paused);
    UInt64 expected=0; UInt32 size=sizeof(expected);
    assert(AudioFileGetProperty(audio.file,kAudioFilePropertyAudioDataPacketCount,&size,&expected) == noErr);
    assert(expected > 1000);
    double slowest=0,deadline=[NSDate timeIntervalSinceReferenceDate]+12;
    BOOL finished=NO;
    while ([NSDate timeIntervalSinceReferenceDate]<deadline && !audio.failed) {
        BOOL empty=YTFakeConsume(&audio,&queue,&slowest);
        if (audio.eof && empty) { finished=YES; break; }
        [NSThread sleepForTimeInterval:0.005];
    }
    if (audio.failed) NSLog(@"Audio producer failed: %ld",(long)audio.error);
    assert(finished && !audio.failed && queue.consumed == audio.decodedFrames && queue.consumed>1500000 && audio.packet==(SInt64)expected);
    assert(queue.starts > 1 && Requests > 8 && slowest < 0.10);
    NSLog(@"Delayed audio test passed: %llu PCM frames consumed across %d network chunks, %u queue starts, longest callback %.4f seconds.",
        (unsigned long long)queue.consumed,Requests,queue.starts,slowest);
    YTFakeCleanUp(&audio,&queue);

    // Direct AAC mode must enqueue compressed packets with packet descriptions
    // while preserving the same frame-based playback clock used for A/V sync.
    Requests=0; YTFakeSetUpDirect(&audio,&queue,&stop,&paused);
    deadline=[NSDate timeIntervalSinceReferenceDate]+12; finished=NO;
    while([NSDate timeIntervalSinceReferenceDate]<deadline && !audio.failed) {
        BOOL empty=YTFakeConsume(&audio,&queue,&slowest);
        if(audio.eof && empty) { finished=YES; break; }
        [NSThread sleepForTimeInterval:0.005];
    }
    assert(finished && !audio.failed && audio.directAAC);
    assert(queue.consumed==audio.decodedFrames && audio.playedFrames==audio.decodedFrames);
    assert(audio.packet==(SInt64)expected && queue.consumed>1000000);
    NSLog(@"Direct AAC queue test passed: %llu decoded audio frames without PCM conversion.",
        (unsigned long long)queue.consumed);
    YTFakeCleanUp(&audio,&queue);
    // A queue may report running while neither callbacks nor its clock advance.
    Requests=0; YTFakeSetUp(&audio,&queue,&stop,&paused);
    pthread_mutex_lock(&queue.mutex); queue.stuck=YES; pthread_mutex_unlock(&queue.mutex);
    deadline=[NSDate timeIntervalSinceReferenceDate]+12; finished=NO;
    while ([NSDate timeIntervalSinceReferenceDate]<deadline && !audio.failed) {
        BOOL empty=YTFakeConsume(&audio,&queue,&slowest);
        if (audio.eof && empty) { finished=YES; break; }
        [NSThread sleepForTimeInterval:0.005];
    }
    assert(finished && !audio.failed && queue.consumed == audio.decodedFrames && queue.consumed>1500000 && audio.packet==(SInt64)expected && queue.pauses > 0 && queue.starts > 1);
    assert(audio.playedFrames==audio.decodedFrames);
    NSLog(@"Running-but-stuck queue recovery passed: decoded audio retained.");
    YTFakeCleanUp(&audio,&queue);
    // A device clock can advance while no PCM is heard. Video must stay at
    // the current audible buffer, rather than skip to future keyframes.
    // Freeze output while the producer is inside a five-second network wait.
    // Recovery must occur before that wait finishes, not after another enqueue.
    Requests=0; YTFakeSetUp(&audio,&queue,&stop,&paused);
    LongDelay=1; LongDelayStarted=LongDelayFinished=0;
    for(unsigned i=0;i<5;i++) YTFakeConsume(&audio,&queue,&slowest);
    deadline=[NSDate timeIntervalSinceReferenceDate]+2;
    while(!LongDelayStarted && [NSDate timeIntervalSinceReferenceDate]<deadline) [NSThread sleepForTimeInterval:0.01];
    assert(LongDelayStarted && !LongDelayFinished);
    pthread_mutex_lock(&queue.mutex); queue.stuck=YES; queue.drifting=YES; pthread_mutex_unlock(&queue.mutex);
    for(int i=0;i<10;i++) {
        double media=YTAudioMediaTime(&audio);
        assert(media <= audio.playedFrames/audio.format.mSampleRate + YT_AUDIO_BUFFER_BYTES/(audio.format.mBytesPerFrame*audio.format.mSampleRate) + 0.01);
    }
    deadline=[NSDate timeIntervalSinceReferenceDate]+3.5;
    BOOL recovered=NO;
    while([NSDate timeIntervalSinceReferenceDate]<deadline && !audio.failed) {
        pthread_mutex_lock(&queue.mutex); recovered=queue.pauses>0; pthread_mutex_unlock(&queue.mutex);
        if(recovered) break;
        [NSThread sleepForTimeInterval:0.02];
    }
    assert(recovered && !LongDelayFinished && !audio.failed);
    pthread_mutex_lock(&queue.mutex); queue.drifting=NO; pthread_mutex_unlock(&queue.mutex);
    deadline=[NSDate timeIntervalSinceReferenceDate]+18; finished=NO;
    while([NSDate timeIntervalSinceReferenceDate]<deadline && !audio.failed) {
        BOOL empty=YTFakeConsume(&audio,&queue,&slowest);
        if(audio.eof && empty) { finished=YES; break; }
        [NSThread sleepForTimeInterval:0.005];
    }
    assert(finished && !audio.failed && queue.consumed==audio.decodedFrames);
    NSLog(@"Audible media clock and independent watchdog passed: stalled output recovered while the audio producer was blocked on HTTPS.");
    YTFakeCleanUp(&audio,&queue);
    // Cancel while the producer is fetching, then join before releasing its file.
    Requests=0; YTFakeSetUp(&audio,&queue,&stop,&paused);
    for (unsigned i=0;i<YT_AUDIO_BUFFERS;i++) YTFakeConsume(&audio,&queue,&slowest);
    [NSThread sleepForTimeInterval:0.03];
    double before=[NSDate timeIntervalSinceReferenceDate];
    YTFakeCleanUp(&audio,&queue);
    assert([NSDate timeIntervalSinceReferenceDate]-before < 1.0);
    NSLog(@"Audio producer cancellation and cleanup passed.");
    Requests=0; YTFakeSetUp(&audio,&queue,&stop,&paused);
    paused=YES; [NSThread sleepForTimeInterval:0.25];
    pthread_mutex_lock(&queue.mutex); BOOL wasPaused=!queue.running; unsigned pauseStarts=queue.starts; pthread_mutex_unlock(&queue.mutex);
    assert(wasPaused);
    [NSThread sleepForTimeInterval:0.3];
    pthread_mutex_lock(&queue.mutex); assert(!queue.running && queue.starts==pauseStarts); pthread_mutex_unlock(&queue.mutex);
    paused=NO; [NSThread sleepForTimeInterval:0.25]; assert(YTFakeRunning(&queue));
    YTFakeCleanUp(&audio,&queue);
    NSLog(@"Single-owner pause and resume passed.");
    [NSThread sleepForTimeInterval:0.3]; // Let cancelled fixture callbacks finish before resetting counters.
    // Open fresh AAC decoders at forwards/backwards targets and drain the
    // real converted PCM. Seeking must not play the prefix again.
    const double targets[]={22.25,4.75,31.15};
    for(unsigned i=0;i<sizeof(targets)/sizeof(targets[0]);i++) {
        Requests=0; YTFakeSetUpAtTime(&audio,&queue,&stop,&paused,targets[i]);
        assert(fabs(YTAudioMediaTime(&audio)-targets[i])<0.01);
        UInt64 totalFrames=expected*audio.inputFormat.mFramesPerPacket;
        UInt64 wanted=totalFrames-(UInt64)llround(targets[i]*audio.format.mSampleRate);
        deadline=[NSDate timeIntervalSinceReferenceDate]+12; finished=NO;
        while([NSDate timeIntervalSinceReferenceDate]<deadline && !audio.failed) {
            BOOL empty=YTFakeConsume(&audio,&queue,&slowest);
            if(audio.eof && empty) { finished=YES; break; }
            [NSThread sleepForTimeInterval:0.005];
        }
        assert(finished && !audio.failed && queue.consumed==audio.decodedFrames);
        assert(llabs((long long)queue.consumed-(long long)wanted)<=2048);
        assert(fabs(YTAudioMediaTime(&audio)-(targets[i]+queue.consumed/audio.format.mSampleRate))<0.01);
        NSLog(@"AAC seek %.2f passed: %llu remaining PCM frames, media clock %.3f.",targets[i],(unsigned long long)queue.consumed,YTAudioMediaTime(&audio));
        YTFakeCleanUp(&audio,&queue);
    }
    // A song shorter than the initial PCM prefill must still drain cleanly.
    [Movie release]; Movie=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]] retain];
    Requests=0; YTFakeSetUp(&audio,&queue,&stop,&paused); assert(audio.eof && !audio.workerCreated && audio.monitorCreated);
    deadline=[NSDate timeIntervalSinceReferenceDate]+3; finished=NO;
    while([NSDate timeIntervalSinceReferenceDate]<deadline && !audio.failed) {
        BOOL empty=YTFakeConsume(&audio,&queue,&slowest);
        if(audio.eof && empty) { finished=YES; break; }
        [NSThread sleepForTimeInterval:0.005];
    }
    assert(finished && !audio.failed && audio.playedFrames==audio.decodedFrames && queue.consumed==audio.decodedFrames);
    assert(YTAudioIsDrained(&audio));
    NSLog(@"Short-track PCM prefill and final drain passed.");
    YTFakeCleanUp(&audio,&queue);
    [NSURLProtocol unregisterClass:[YTSlowMovieProtocol class]];
    [Movie release]; [pool release]; return 0;
}
