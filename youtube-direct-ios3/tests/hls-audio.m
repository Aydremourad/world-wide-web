#import "YTHLSAudioSource.h"
#import "YTHLSBridge.h"
#import "YTAudioPump.h"
#include "YTADTS.h"
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

@interface YTFragmentReader : NSObject <YTHLSSequentialReading> {
    NSData *_data;
    NSUInteger _position;
    BOOL _cancelled;
}
- (id)initWithData:(NSData *)data;
@end
@implementation YTFragmentReader
- (id)initWithData:(NSData *)data { if((self=[super init])) _data=[data retain]; return self; }
- (int)readInto:(void *)buffer count:(int)count {
    if(_cancelled) return -1;
    NSUInteger take=[_data length]-_position;
    if(take>(NSUInteger)count) take=(NSUInteger)count;
    if(take>173) take=173; // Cross TS packet boundaries in every AVIO read.
    memcpy(buffer,(const char *)[_data bytes]+_position,take); _position+=take;
    return (int)take;
}
- (void)cancel { _cancelled=YES; }
- (NSString *)errorText { return nil; }
- (void)dealloc { [_data release]; [super dealloc]; }
@end
@interface YTAudioFixtureBridge : YTHLSBridge { NSData *_fixture; }
- (id)initWithData:(NSData *)data;
@end
@implementation YTAudioFixtureBridge
- (id)initWithData:(NSData *)data {
    if((self=[super initWithURL:nil userAgent:nil])) _fixture=[data retain]; return self;
}
- (id<YTHLSSequentialReading>)newSequentialReaderAtTime:(double)time actualStart:(double *)start {
    *start=0; return [[[YTFragmentReader alloc] initWithData:_fixture] autorelease];
}
- (void)dealloc { [_fixture release]; [super dealloc]; }
@end

typedef struct {
    id<YTAACPacketReading> source;
    uint8_t bytes[65536];
    AudioStreamPacketDescription descriptions[64];
} YTInput;
static OSStatus ReadAAC(AudioConverterRef converter,UInt32 *packets,AudioBufferList *data,
    AudioStreamPacketDescription **descriptions,void *opaque) {
    YTInput *input=opaque;
    if(*packets>64) *packets=64;
    UInt32 bytes=0;
    OSStatus status=[input->source readPackets:packets into:input->bytes capacity:sizeof(input->bytes)
        descriptions:input->descriptions bytes:&bytes];
    data->mNumberBuffers=1;
    data->mBuffers[0]=(AudioBuffer){2,bytes,input->bytes};
    *descriptions=input->descriptions; return status;
}
static UInt64 DecodeFixture(YTHLSBridge *bridge,double start) {
    YTHLSAudioSource *source=[[YTHLSAudioSource alloc] initWithBridge:bridge];
    YTAudio audio; memset(&audio,0,sizeof(audio)); audio.packetSource=source; audio.startTime=start;
    OSStatus opened=YTAudioOpen(&audio);
    if(opened!=noErr) NSLog(@"HLS AAC open failed: %d %@",(int)opened,[source errorText]);
    assert(opened==noErr && audio.inputFormat.mSampleRate==44100 && audio.inputFormat.mChannelsPerFrame==2);
    assert(audio.startTime<=start+0.000001 && start-audio.startTime<1024.0/44100);
    assert([[source magicCookie] length]==YT_AAC_MAGIC_COOKIE_BYTES);
    YTInput input; memset(&input,0,sizeof(input)); input.source=source;
    UInt64 total=0; double energy=0;
    while(1) {
        short pcm[8192]; UInt32 frames=4096;
        AudioBufferList output={1,{{2,sizeof(pcm),pcm}}};
        OSStatus result=AudioConverterFillComplexBuffer(audio.converter,ReadAAC,&input,&frames,&output,NULL);
        if(result!=noErr) NSLog(@"HLS AAC decode failed: %d %@",(int)result,[source errorText]);
        assert(result==noErr);
        if(!frames) break;
        for(UInt32 i=0;i<frames*2;i++) energy+=(double)pcm[i]*pcm[i];
        total+=frames;
        assert(total<400000);
    }
    assert(energy>1e6 && ![[source errorText] length]);
    NSLog(@"HLS AAC start %.3f: %llu PCM frames, native decoder, fragmented TS reads.",start,total);
    YTShutdownAudio(&audio); [source release]; return total;
}
int main(int argc,char **argv) {
    assert(argc==2);
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    NSData *fixture=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
    assert([fixture length]>0);
    YTHLSBridge *bridge=[[YTAudioFixtureBridge alloc] initWithData:fixture];
    UInt64 all=DecodeFixture(bridge,0),seek=DecodeFixture(bridge,1.137);
    assert(all>340000 && all<360000);
    assert(all>seek && llabs((long long)(all-seek)-(long long)llround(1.137*44100))<=2048);
    [bridge release]; [pool release]; return 0;
}
