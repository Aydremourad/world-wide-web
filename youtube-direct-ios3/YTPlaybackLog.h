#import <Foundation/Foundation.h>

// Keep a second copy: legacy system-installed apps do not always have a
// writable temporary directory. The existing Info button can read either.
static inline NSString *YTReadPlaybackLog(void) {
    NSString *file=[NSString stringWithContentsOfFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTube-playback.txt"] encoding:NSUTF8StringEncoding error:NULL];
    if([file length]) return file;
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"YTPlaybackReport"];
}
static inline void YTWritePlaybackLog(NSString *text) {
    [[NSUserDefaults standardUserDefaults] setObject:text forKey:@"YTPlaybackReport"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTube-playback.txt"];
    if(![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL])
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}
