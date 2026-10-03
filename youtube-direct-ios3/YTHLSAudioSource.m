#import "YTHLSAudioSource.h"
#import "YTHLSBridge.h"
#include "YTADTS.h"
#include <libavformat/avformat.h>
#include <libavutil/mem.h>
#include <math.h>
#include <errno.h>
#include <string.h>

@interface YTHLSAudioSource ()
- (int)readInto:(uint8_t *)buffer count:(int)count;
- (BOOL)cancelled;
- (int)nextFrame:(YTADTSFrame *)header;
@end

static int YTHLSAudioRead(void *opaque, uint8_t *buffer, int count) {
    YTHLSAudioSource *source=(YTHLSAudioSource *)opaque;
    if([source cancelled]) return AVERROR_EXIT;
    int result=[source readInto:buffer count:count];
    return result>0 ? result : result==0 ? AVERROR_EOF : AVERROR(EIO);
}
static int YTHLSAudioInterrupt(void *opaque) {
    return [(YTHLSAudioSource *)opaque cancelled];
}

@implementation YTHLSAudioSource
- (id)initWithBridge:(YTHLSBridge *)bridge {
    if((self=[super init])) { _bridge=[bridge retain]; _firstPTS=NAN; }
    return self;
}
- (BOOL)cancelled { return _cancelled; }
- (int)readInto:(uint8_t *)buffer count:(int)count {
    return [(id<YTHLSSequentialReading>)_reader readInto:buffer count:count];
}
- (void)setFailure:(NSString *)message {
    [_errorText release]; _errorText=[message copy];
}
- (NSString *)errorText {
    return [_errorText length] ? _errorText : [(id<YTHLSSequentialReading>)_reader errorText];
}
- (NSData *)magicCookie { return _cookie; }
- (int)nextFrame:(YTADTSFrame *)header {
    AVFormatContext *format=(AVFormatContext *)_formatContext;
    while(!_cancelled) {
        NSUInteger available=[_pending length]-_inside;
        int parsed=available<7 ? 0 :
            YTReadADTSHeader((const uint8_t *)[_pending bytes]+_inside,available,header);
        if(parsed<0) { [self setFailure:@"The HLS audio is not supported AAC-LC."]; return -1; }
        if(parsed>0) {
            if(_rate && (header->rate!=_rate || header->channels!=_channels)) {
                [self setFailure:@"The HLS audio format changed during playback."]; return -1;
            }
            return 1;
        }
        if(_eof) {
            if(available) { [self setFailure:@"The last HLS AAC packet was incomplete."]; return -1; }
            return 0;
        }
        // Discard consumed access units before appending another bounded PES.
        if(_inside) {
            [_pending replaceBytesInRange:NSMakeRange(0,_inside) withBytes:NULL length:0];
            _inside=0;
        }
        AVPacket packet;
        av_init_packet(&packet);
        int read=av_read_frame(format,&packet);
        if(read<0) {
            if(read==AVERROR_EOF) { _eof=YES; continue; }
            if(!_cancelled) [self setFailure:@"The HLS audio stream stopped unexpectedly."];
            return -1;
        }
        // AAC is demuxed only. Discard video before parser/decoder work in this
        // independent reader; its bytes come from the same segment disk cache.
        for(unsigned i=0;i<format->nb_streams;i++)
            if(format->streams[i]->codec->codec_type!=AVMEDIA_TYPE_AUDIO)
                format->streams[i]->discard=AVDISCARD_ALL;
        AVStream *stream=format->streams[packet.stream_index];
        if(!_rate && ++_probePackets>128) {
            av_free_packet(&packet); [self setFailure:@"The HLS movie did not contain AAC audio near its start."]; return -1;
        }
        if(stream->codec->codec_id==AV_CODEC_ID_AAC) {
            if(packet.size<=0 || packet.size>65536 || [_pending length]+packet.size>131072) {
                av_free_packet(&packet); [self setFailure:@"The HLS AAC packet was invalid."]; return -1;
            }
            if(![_pending length]) {
                int64_t stamp=packet.pts!=AV_NOPTS_VALUE ? packet.pts : packet.dts;
                if(stamp!=AV_NOPTS_VALUE) {
                    double pts=stamp*av_q2d(stream->time_base);
                    if(isnan(_firstPTS)) _firstPTS=pts;
                    _nextTime=_segmentStart+pts-_firstPTS;
                }
            }
            [_pending appendBytes:packet.data length:(NSUInteger)packet.size];
        }
        av_free_packet(&packet);
    }
    return -1;
}
- (OSStatus)openAtTime:(double)time format:(AudioStreamBasicDescription *)description
    actualStart:(double *)actualStart discardFrames:(UInt32 *)discardFrames {
    av_register_all();
    _reader=[[_bridge newSequentialReaderAtTime:time actualStart:&_segmentStart] retain];
    _pending=[[NSMutableData alloc] init]; _nextTime=_segmentStart;
    AVFormatContext *format=avformat_alloc_context();
    uint8_t *buffer=av_malloc(32768);
    if(!format || !buffer) { avformat_free_context(format); av_free(buffer); return kAudioFileUnspecifiedError; }
    AVIOContext *io=avio_alloc_context(buffer,32768,0,self,YTHLSAudioRead,NULL,NULL);
    if(!io) { avformat_free_context(format); av_free(buffer); return kAudioFileUnspecifiedError; }
    _ioContext=io; format->pb=io; format->flags|=AVFMT_FLAG_CUSTOM_IO;
    format->probesize=32768; format->max_analyze_duration2=0;
    format->interrupt_callback.callback=YTHLSAudioInterrupt; format->interrupt_callback.opaque=self;
    if(avformat_open_input(&format,NULL,av_find_input_format("mpegts"),NULL)<0) {
        _formatContext=format; [self setFailure:@"Could not open the HLS AAC stream."];
        return kAudioFileUnsupportedDataFormatError;
    }
    _formatContext=format;
    YTADTSFrame header;
    int got;
    while((got=[self nextFrame:&header])>0) {
        _rate=header.rate; _channels=header.channels;
        if(_nextTime+1024.0/_rate>time+0.000001) break;
        _inside+=header.frameBytes; _nextTime+=1024.0/_rate;
    }
    if(got<=0) return kAudioFileUnsupportedDataFormatError;
    _cookie=[[NSData alloc] initWithBytes:header.cookie length:2];
    memset(description,0,sizeof(*description));
    description->mFormatID=kAudioFormatMPEG4AAC;
    description->mSampleRate=_rate; description->mChannelsPerFrame=_channels;
    description->mFramesPerPacket=1024;
    if(actualStart) *actualStart=_nextTime;
    if(discardFrames) *discardFrames=(UInt32)llround(fmax(0,time-_nextTime)*_rate);
    return noErr;
}
- (OSStatus)readPackets:(UInt32 *)packets into:(void *)buffer capacity:(UInt32)capacity
    descriptions:(AudioStreamPacketDescription *)descriptions bytes:(UInt32 *)bytes {
    UInt32 wanted=*packets; *packets=0; *bytes=0;
    while(*packets<wanted && !_cancelled) {
        YTADTSFrame header; int got=[self nextFrame:&header];
        if(got<0) return kAudioFileUnspecifiedError;
        if(!got) break;
        UInt32 size=header.frameBytes-header.headerBytes;
        if(size>capacity-*bytes) break;
        memcpy((uint8_t *)buffer+*bytes,(const uint8_t *)[_pending bytes]+_inside+header.headerBytes,size);
        descriptions[*packets].mStartOffset=*bytes;
        descriptions[*packets].mDataByteSize=size;
        descriptions[*packets].mVariableFramesInPacket=1024;
        *bytes+=size; (*packets)++; _inside+=header.frameBytes;
        _nextTime+=1024.0/_rate;
    }
    return noErr;
}
- (void)cancel { _cancelled=YES; [(id<YTHLSSequentialReading>)_reader cancel]; }
- (void)close {
    AVFormatContext *format=(AVFormatContext *)_formatContext;
    if(format) avformat_close_input(&format); _formatContext=NULL;
    AVIOContext *io=(AVIOContext *)_ioContext;
    if(io) { av_free(io->buffer); av_free(io); } _ioContext=NULL;
}
- (void)dealloc {
    [self cancel]; [self close];
    [_bridge release]; [_reader release]; [_pending release]; [_cookie release]; [_errorText release];
    [super dealloc];
}
@end
