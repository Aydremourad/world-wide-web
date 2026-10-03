#import "YTAACPacketSource.h"
@class YTHLSBridge;

/* Supplies AAC access units to the existing AudioQueue pump; never decodes AAC. */
@interface YTHLSAudioSource : NSObject <YTAACPacketReading> {
    YTHLSBridge *_bridge;
    id _reader;
    void *_formatContext, *_ioContext;
    NSMutableData *_pending;
    NSUInteger _inside;
    NSData *_cookie;
    NSString *_errorText;
    double _segmentStart, _firstPTS, _nextTime;
    unsigned _rate, _channels;
    unsigned _probePackets;
    BOOL _eof;
    volatile BOOL _cancelled;
}
- (id)initWithBridge:(YTHLSBridge *)bridge;
@end
