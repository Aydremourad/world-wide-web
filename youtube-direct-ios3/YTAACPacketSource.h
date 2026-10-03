#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@protocol YTAACPacketReading <NSObject>
- (OSStatus)openAtTime:(double)time format:(AudioStreamBasicDescription *)format
    actualStart:(double *)actualStart discardFrames:(UInt32 *)discardFrames;
- (NSData *)magicCookie;
- (OSStatus)readPackets:(UInt32 *)packets into:(void *)buffer capacity:(UInt32)capacity
    descriptions:(AudioStreamPacketDescription *)descriptions bytes:(UInt32 *)bytes;
- (void)cancel;
- (void)close;
- (NSString *)errorText;
@end
