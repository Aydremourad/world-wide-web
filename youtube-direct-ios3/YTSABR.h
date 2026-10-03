#import <Foundation/Foundation.h>
// SABR transport runs on the phone. The output is remuxed, never re-encoded.
NSString *YTDownloadSABRVideo(NSDictionary *options, NSString **errorText);
int YTRemuxPhoneVideo(const char *inputPath,const char *outputPath);
