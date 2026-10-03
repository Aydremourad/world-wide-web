#import <Foundation/Foundation.h>

// Keep a second copy: legacy system-installed apps do not always have a
// writable temporary directory. The existing Info button can read either.
static inline NSString *YTReadPlaybackLog(void) {
    NSString *saved=[[NSUserDefaults standardUserDefaults] stringForKey:@"YTPlaybackReport"];
    if([saved length]) return saved;
    return [NSString stringWithContentsOfFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTube-playback.txt"] encoding:NSUTF8StringEncoding error:NULL];
}
static inline void YTWritePlaybackLog(NSString *text) {
    [[NSUserDefaults standardUserDefaults] setObject:text forKey:@"YTPlaybackReport"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [text writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTube-playback.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
