#import <Foundation/Foundation.h>
// Reads the MP4 headers; does not decode or convert the movie.
NSDictionary *YTNativeStreamInfo(NSDictionary *streams);

// A concrete probe result overrides an unverified codec label from YouTube.
static inline BOOL YTShouldUseNativePlayer(NSDictionary *streams) {
    NSDictionary *info=[streams objectForKey:@"nativeInfo"];
    if([info objectForKey:@"eligible"]) return [[info objectForKey:@"eligible"] boolValue];
    return NO;
}
