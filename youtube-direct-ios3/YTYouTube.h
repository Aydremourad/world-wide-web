#import <Foundation/Foundation.h>

@interface YTYouTube : NSObject

+ (NSArray *)search:(NSString *)query error:(NSString **)errorText;
+ (NSDictionary *)playbackStreamsForID:(NSString *)videoID error:(NSString **)errorText;
+ (NSString *)videoIDFromText:(NSString *)text;

@end

