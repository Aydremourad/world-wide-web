#import <Foundation/Foundation.h>

@interface YTYouTube : NSObject

+ (NSDictionary *)streamsFromPlayerResponse:(NSString *)player userAgent:(NSString *)userAgent error:(NSString **)errorText;
+ (NSArray *)search:(NSString *)query error:(NSString **)errorText;
+ (NSDictionary *)playbackStreamsForID:(NSString *)videoID error:(NSString **)errorText;
+ (NSDictionary *)softwareFallbackForID:(NSString *)videoID error:(NSString **)errorText;
+ (NSDictionary *)lowResolutionStreamsForID:(NSString *)videoID;
+ (NSDictionary *)phoneOnlyStreamsForID:(NSString *)videoID original:(NSDictionary *)original error:(NSString **)errorText;
+ (NSString *)videoIDFromText:(NSString *)text;

@end

