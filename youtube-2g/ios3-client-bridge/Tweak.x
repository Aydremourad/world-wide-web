#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#include <stdio.h>
#include <stdarg.h>

static NSString *TRBEndpoint = nil;
static BOOL TRBInsideURLBuild = NO;

static void TRBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);

    FILE *fp = fopen("/tmp/TubeRepairIOS3Bridge.log", "a");
    if (fp) {
        fprintf(fp, "%s\n", [message UTF8String]);
        fclose(fp);
    }
}

static NSString *TRBLoadEndpoint(void) {
    NSString *settingsPath = @"/var/mobile/Library/Preferences/bag.xml.tuberepairpreference.plist";
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
    NSString *endpoint = [prefs objectForKey:@"URLEndpoint"];

    if (![endpoint length]) {
        endpoint = @"https://aydreyoutube2g.duckdns.org";
    }

    if (![endpoint hasPrefix:@"http://"] && ![endpoint hasPrefix:@"https://"]) {
        endpoint = [@"https://" stringByAppendingString:endpoint];
    }

    while ([endpoint hasSuffix:@"/"] && [endpoint length] > 8) {
        endpoint = [endpoint substringToIndex:[endpoint length] - 1];
    }

    return endpoint;
}

static NSString *TRBQueryValue(NSString *query, NSString *wantedKey) {
    if (![query length]) return nil;

    NSArray *parts = [query componentsSeparatedByString:@"&"];
    for (NSString *part in parts) {
        NSRange equals = [part rangeOfString:@"="];
        NSString *key = nil;
        NSString *value = nil;

        if (equals.location == NSNotFound) {
            key = part;
            value = @"";
        } else {
            key = [part substringToIndex:equals.location];
            value = [part substringFromIndex:equals.location + 1];
        }

        if ([key isEqualToString:wantedKey]) {
            return [value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        }
    }

    return nil;
}

static NSString *TRBVideoIDFromURL(NSURL *url) {
    if (!url) return nil;

    NSString *host = [[url host] lowercaseString];
    NSString *path = [url path];
    NSString *query = [url query];

    BOOL youtubeHost =
        [host isEqualToString:@"www.youtube.com"] ||
        [host isEqualToString:@"youtube.com"] ||
        [host isEqualToString:@"m.youtube.com"];

    if (!youtubeHost) return nil;

    if ([path isEqualToString:@"/watch"] ||
        [path isEqualToString:@"/details"] ||
        [path isEqualToString:@"/get_video"]) {
        NSString *videoID = TRBQueryValue(query, @"v");
        if (![videoID length]) videoID = TRBQueryValue(query, @"video_id");
        return videoID;
    }

    if ([path hasPrefix:@"/v/"]) {
        NSString *videoID = [path substringFromIndex:3];
        NSRange slash = [videoID rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            videoID = [videoID substringToIndex:slash.location];
        }
        return videoID;
    }

    return nil;
}

static NSURL *TRBURLWithStringNoRewrite(NSString *string) {
    BOOL old = TRBInsideURLBuild;
    TRBInsideURLBuild = YES;
    NSURL *url = TRBURLWithStringNoRewrite(string);
    TRBInsideURLBuild = old;
    return url;
}

static NSURL *TRBRewriteURL(NSURL *url, NSString *source) {
    if (!url || ![TRBEndpoint length]) return url;

    NSString *absolute = [url absoluteString];
    if ([absolute rangeOfString:@"youtube"].location != NSNotFound ||
        [absolute hasPrefix:TRBEndpoint]) {
        TRBLog(@"OBSERVED %@ %@", source, absolute);
    }
    if ([absolute hasPrefix:TRBEndpoint]) return url;

    NSString *videoID = TRBVideoIDFromURL(url);
    if (![videoID length]) return url;

    NSString *targetString = [NSString stringWithFormat:@"%@/getvideo/%@", TRBEndpoint, videoID];
    NSURL *target = TRBURLWithStringNoRewrite(targetString);

    if (target) {
        TRBLog(@"REWRITE %@ %@ -> %@", source, absolute, targetString);
        return target;
    }

    TRBLog(@"REWRITE FAILED %@ %@", source, absolute);
    return url;
}

static NSString *TRBRewriteString(NSString *string, NSString *source) {
    if (![string length]) return string;
    if ([string rangeOfString:@"youtube.com"].location == NSNotFound) return string;

    NSURL *url = [[[NSURL alloc] initWithString:string] autorelease];
    NSURL *rewritten = TRBRewriteURL(url, source);
    if (rewritten != url) return [rewritten absoluteString];
    return string;
}


static NSURLRequest *TRBRewriteRequest(NSURLRequest *request, NSString *source) {
    if (!request) return request;

    NSURL *oldURL = [request URL];
    NSURL *newURL = TRBRewriteURL(oldURL, source);
    if (newURL == oldURL || [[newURL absoluteString] isEqualToString:[oldURL absoluteString]]) {
        return request;
    }

    NSMutableURLRequest *copy = [[request mutableCopy] autorelease];
    [copy setURL:newURL];
    TRBLog(@"REQUEST REWRITE %@ -> %@", [oldURL absoluteString], [newURL absoluteString]);
    return copy;
}

%hook NSURL

+ (id)URLWithString:(NSString *)URLString {
    if (TRBInsideURLBuild) return %orig(URLString);
    NSString *rewritten = TRBRewriteString(URLString, @"+URLWithString:");
    return %orig(rewritten);
}

- (id)initWithString:(NSString *)URLString {
    if (TRBInsideURLBuild) return %orig(URLString);
    NSString *rewritten = TRBRewriteString(URLString, @"-initWithString:");
    return %orig(rewritten);
}

%end

%hook NSURLRequest

+ (id)requestWithURL:(NSURL *)URL {
    return %orig(TRBRewriteURL(URL, @"+requestWithURL:"));
}

+ (id)requestWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeoutInterval {
    return %orig(TRBRewriteURL(URL, @"+requestWithURL:cachePolicy:timeoutInterval:"), cachePolicy, timeoutInterval);
}

- (id)initWithURL:(NSURL *)URL {
    return %orig(TRBRewriteURL(URL, @"-initWithURL:"));
}

- (id)initWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeoutInterval {
    return %orig(TRBRewriteURL(URL, @"-initWithURL:cachePolicy:timeoutInterval:"), cachePolicy, timeoutInterval);
}

%end

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL {
    %orig(TRBRewriteURL(URL, @"NSMutableURLRequest setURL:"));
}

%end


%hook NSURLConnection

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
    return %orig(TRBRewriteRequest(request, @"NSURLConnection sendSynchronousRequest:"), response, error);
}

+ (id)connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    return %orig(TRBRewriteRequest(request, @"NSURLConnection connectionWithRequest:"), delegate);
}

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    return %orig(TRBRewriteRequest(request, @"NSURLConnection initWithRequest:"), delegate);
}

%end

%hook MPMoviePlayerController

- (id)initWithContentURL:(NSURL *)URL {
    NSURL *rewritten = TRBRewriteURL(URL, @"MPMoviePlayerController initWithContentURL:");
    TRBLog(@"PLAYER init %@", [rewritten absoluteString]);
    return %orig(rewritten);
}

- (void)setContentURL:(NSURL *)URL {
    NSURL *rewritten = TRBRewriteURL(URL, @"MPMoviePlayerController setContentURL:");
    TRBLog(@"PLAYER set %@", [rewritten absoluteString]);
    %orig(rewritten);
}

%end

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TRBEndpoint = [TRBLoadEndpoint() copy];

    FILE *fp = fopen("/tmp/TubeRepairIOS3Bridge.log", "w");
    if (fp) fclose(fp);

    TRBLog(@"TubeRepairIOS3Bridge 1.0.0 loaded endpoint=%@", TRBEndpoint);
    [pool drain];
}
