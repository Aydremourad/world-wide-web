#import <Foundation/Foundation.h>

@interface YTYouTube : NSObject

+ (NSArray *)search:(NSString *)query error:(NSString **)errorText;
+ (NSURL *)directVideoURLForID:(NSString *)videoID error:(NSString **)errorText;
+ (NSString *)videoIDFromText:(NSString *)text;

@end
