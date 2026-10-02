// Reuse the actual combined-file fixture protocol, not the player UI.
#define main YTCombinedFixtureMain
#include "combined-player.m"
#undef main
#import "YTAudioPump.h"

@interface YTSlowMovieProtocol : YTMovieProtocol
@end
@implementation YTSlowMovieProtocol
- (void)startLoading {
    if (Requests > 2) [NSThread sleepForTimeInterval:0.15];
    [super startLoading];
}
@end
typedef struct {
    pthread_mutex_t mutex;
    AudioQueueBufferRef buffers[16];
    UInt32 packets[16];
    unsigned count;
    UInt64 consumed;
    unsigned starts;
    BOOL running;
    BOOL draining;
} FakeQueue;
static OSStatus YTFakeEnqueue(void *opaque, AudioQueueBufferRef buffer, UInt32 packets,
                        AudioStreamPacketDescription *descriptions) {
    FakeQueue *queue=opaque;
    assert(packets && buffer->mAudioDataByteSize && buffer->mAudioDataByteSize <= 32768);
    for (unsigned i=0;i<packets;i++)
        assert(descriptions[i].mStartOffset >= 0 && descriptions[i].mDataByteSize > 0 &&
               descriptions[i].mStartOffset + descriptions[i].mDataByteSize <= buffer->mAudioDataByteSize);
    pthread_mutex_lock(&queue->mutex);
    assert(queue->count < 16);
    for (unsigned i=0;i<queue->count;i++) assert(queue->buffers[i] != buffer);
    queue->buffers[queue->count]=buffer; queue->packets[queue->count++]=packets;
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
    pthread_mutex_lock(&queue->mutex); queue->running=YES; queue->starts++; pthread_mutex_unlock(&queue->mutex);
    return noErr;
}
static void YTFakeDrain(void *opaque) {
    FakeQueue *queue=opaque;
    pthread_mutex_lock(&queue->mutex); queue->draining=YES; pthread_mutex_unlock(&queue->mutex);
}
static void YTFakeSetUp(YTAudio *audio, FakeQueue *queue, volatile BOOL *stop, volatile BOOL *paused) {
    memset(audio,0,sizeof(*audio)); memset(queue,0,sizeof(*queue));
    pthread_mutex_init(&queue->mutex,NULL);
    audio->stop=stop; audio->paused=paused;
    audio->source=[[YTMediaSource alloc] initWithURL:[NSURL URLWithString:@"https://movie.example/combined.mp4"]
        length:[Movie length] userAgent:@"fixture"];
    assert(YTAudioOpen(audio) == noErr);
    audio->sink=(YTAudioSink){queue,YTFakeEnqueue,YTFakeRunning,YTFakeStart,YTFakeDrain};
    for (unsigned i=0;i<YT_AUDIO_BUFFERS;i++) {
        AudioQueueBuffer initial={.mAudioDataBytesCapacity=32768,.mAudioData=malloc(32768)};
        audio->buffers[i]=malloc(sizeof(initial)); memcpy(audio->buffers[i],&initial,sizeof(initial));
    }
    assert(YTAudioBegin(audio) == noErr && !audio->eof);
    audio->started=YES; YTFakeStart(queue);
}
static BOOL YTFakeConsume(YTAudio *audio, FakeQueue *queue, double *slowest) {
    pthread_mutex_lock(&queue->mutex);
    AudioQueueBufferRef buffer=NULL;
    if (queue->running && queue->count) {
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
    assert(argc == 2);
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
    assert(finished && !audio.failed && queue.consumed == expected);
    assert(queue.starts > 1 && Requests > 8 && slowest < 0.10);
    NSLog(@"Delayed audio test passed: %llu packets consumed across %d network chunks, %u queue starts, longest callback %.4f seconds.",
        (unsigned long long)queue.consumed,Requests,queue.starts,slowest);
    YTFakeCleanUp(&audio,&queue);
    // Cancel while the producer is fetching, then join before releasing its file.
    Requests=0; YTFakeSetUp(&audio,&queue,&stop,&paused);
    for (unsigned i=0;i<YT_AUDIO_BUFFERS;i++) YTFakeConsume(&audio,&queue,&slowest);
    [NSThread sleepForTimeInterval:0.03];
    double before=[NSDate timeIntervalSinceReferenceDate];
    YTFakeCleanUp(&audio,&queue);
    assert([NSDate timeIntervalSinceReferenceDate]-before < 1.0);
    NSLog(@"Audio producer cancellation and cleanup passed.");
    [NSURLProtocol unregisterClass:[YTSlowMovieProtocol class]];
    [Movie release]; [pool release]; return 0;
}
