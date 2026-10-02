#import <Foundation/Foundation.h>

@interface YTYouTube : NSObject

+ (NSDictionary *)streamsFromPlayerResponse:(NSString *)player userAgent:(NSString *)userAgent error:(NSString **)errorText;
+ (NSArray *)search:(NSString *)query error:(NSString **)errorText;
+ (NSDictionary *)playbackStreamsForID:(NSString *)videoID error:(NSString **)errorText;
+ (NSString *)videoIDFromText:(NSString *)text;

@end

