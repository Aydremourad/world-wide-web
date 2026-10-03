#include <limits.h>
#import "YTYouTube.h"
#import "YTMediaSource.h"
#import "YTSABR.h"
#import "YTNativeProbe.h"
#include <stdlib.h>
#include <unistd.h>


static int YTHex(unichar c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static NSString *YTJSONUnescape(NSString *value) {
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0, n = [value length];
    while (i < n) {
        unichar c = [value characterAtIndex:i++];
        if (c != '\\' || i >= n) {
            [out appendFormat:@"%C", c];
            continue;
        }
        unichar e = [value characterAtIndex:i++];
        if (e == '"' || e == '\\' || e == '/') [out appendFormat:@"%C", e];
        else if (e == 'n') [out appendString:@"\n"];
        else if (e == 'r') [out appendString:@"\r"];
        else if (e == 't') [out appendString:@"\t"];
        else if (e == 'b') [out appendString:@"\b"];
        else if (e == 'f') [out appendString:@"\f"];
        else if (e == 'u' && i + 4 <= n) {
            int h0 = YTHex([value characterAtIndex:i]);
            int h1 = YTHex([value characterAtIndex:i + 1]);
            int h2 = YTHex([value characterAtIndex:i + 2]);
            int h3 = YTHex([value characterAtIndex:i + 3]);
            if (h0 >= 0 && h1 >= 0 && h2 >= 0 && h3 >= 0) {
                unichar u = (unichar)((h0 << 12) | (h1 << 8) | (h2 << 4) | h3);
                [out appendFormat:@"%C", u];
                i += 4;
            }
        } else {
            [out appendFormat:@"%C", e];
        }
    }
    return out;
}

static NSString *YTJSONStringForKey(NSString *text, NSString *key, NSUInteger start) {
    if (!text || start >= [text length]) return nil;
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange r = [text rangeOfString:needle options:0
                              range:NSMakeRange(start, [text length] - start)];
    if (r.location == NSNotFound) return nil;

    NSUInteger i = r.location + r.length;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (i < [text length] && [ws characterIsMember:[text characterAtIndex:i]]) i++;
    if (i >= [text length] || [text characterAtIndex:i] != ':') return nil;
    i++;
    while (i < [text length] && [ws characterIsMember:[text characterAtIndex:i]]) i++;
    if (i >= [text length] || [text characterAtIndex:i] != '"') return nil;
    i++;

    NSMutableString *raw = [NSMutableString string];
    BOOL escaped = NO;
    while (i < [text length]) {
        unichar ch = [text characterAtIndex:i++];
        if (!escaped && ch == '"') break;
        [raw appendFormat:@"%C", ch];
        if (escaped) escaped = NO;
        else if (ch == '\\') escaped = YES;
    }
    return YTJSONUnescape(raw);
}

static NSInteger YTJSONIntForKey(NSString *text, NSString *key) {
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange r = [text rangeOfString:needle];
    if (r.location == NSNotFound) return -1;

    NSUInteger i = r.location + r.length;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (i < [text length] && [ws characterIsMember:[text characterAtIndex:i]]) i++;
    if (i >= [text length] || [text characterAtIndex:i] != ':') return -1;
    i++;
    while (i < [text length] && [ws characterIsMember:[text characterAtIndex:i]]) i++;

    NSInteger value = 0;
    BOOL found = NO;
    while (i < [text length]) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9') break;
        found = YES;
        value = (value * 10) + (c - '0');
        i++;
    }
    return found ? value : -1;
}

static NSString *YTBalancedObject(NSString *text, NSUInteger openIndex) {
    if (!text || openIndex >= [text length] || [text characterAtIndex:openIndex] != '{') return nil;
    NSInteger depth = 0;
    BOOL inString = NO, escaped = NO;
    NSUInteger i;
    for (i = openIndex; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        if (inString) {
            if (escaped) escaped = NO;
            else if (c == '\\') escaped = YES;
            else if (c == '"') inString = NO;
            continue;
        }
        if (c == '"') inString = YES;
        else if (c == '{') depth++;
        else if (c == '}') {
            depth--;
            if (depth == 0)
                return [text substringWithRange:NSMakeRange(openIndex, i - openIndex + 1)];
        }
    }
    return nil;
}

static NSArray *YTJSONObjectStringsInArray(NSString *text, NSString *arrayKey) {
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", arrayKey];
    NSRange r = [text rangeOfString:needle];
    if (r.location == NSNotFound) return [NSArray array];

    NSUInteger i = r.location + r.length;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (i < [text length] && [ws characterIsMember:[text characterAtIndex:i]]) i++;
    if (i >= [text length] || [text characterAtIndex:i] != ':') return [NSArray array];
    i++;
    while (i < [text length] && [ws characterIsMember:[text characterAtIndex:i]]) i++;
    if (i >= [text length] || [text characterAtIndex:i] != '[') return [NSArray array];
    i++;

    NSMutableArray *objects = [NSMutableArray array];
    NSInteger arrayDepth = 1;
    BOOL inString = NO, escaped = NO;
    while (i < [text length] && arrayDepth > 0) {
        unichar ch = [text characterAtIndex:i];
        if (inString) {
            if (escaped) escaped = NO;
            else if (ch == '\\') escaped = YES;
            else if (ch == '"') inString = NO;
            i++;
            continue;
        }
        if (ch == '"') { inString = YES; i++; continue; }
        if (ch == '[') { arrayDepth++; i++; continue; }
        if (ch == ']') { arrayDepth--; i++; continue; }
        if (arrayDepth == 1 && ch == '{') {
            NSString *obj = YTBalancedObject(text, i);
            if (obj) {
                [objects addObject:obj];
                i += [obj length];
                continue;
            }
        }
        i++;
    }
    return objects;
}

static NSString *YTQueryEscape(NSString *value) {
    NSString *escaped = [value stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"#" withString:@"%23"];
    return escaped;
}

static NSData *YTGETWithUserAgent(NSString *urlString, NSString *userAgent, NSTimeInterval timeout, NSString **errorText) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:timeout];
    [req setHTTPMethod:@"GET"];
    if([userAgent length]) [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [req setValue:@"text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"
forHTTPHeaderField:@"Accept"];

    NSURLResponse *response = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&response error:&err];
    NSInteger status = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]])
        status = [(NSHTTPURLResponse *)response statusCode];

    if (data && status >= 200 && status < 300) return data;

    if (errorText) {
        if (err) *errorText = [err localizedDescription];
        else *errorText = [NSString stringWithFormat:@"YouTube HTTP %d", (int)status];
    }
    return nil;
}

static NSData *YTGET(NSString *urlString, NSString **errorText) {
    return YTGETWithUserAgent(urlString,
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        25.0,errorText);
}


static NSArray *YTPlayerClients(void) {
    return [NSArray arrayWithObjects:
        // Current 2026 mweb/web clients can still expose legacy progressive
        // format 18 as avc1.42001E + AAC-LC. Probe these first because a true
        // Baseline format 18 lets iPhone OS 3 use hardware/native playback.
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"MWeb", @"label", @"MWEB", @"name", @"2.20260708.05.00", @"version", @"2", @"number",
            @"Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)", @"ua",
            @"", @"extra", [NSNumber numberWithDouble:3.5], @"timeout", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"Web embedded", @"label", @"WEB_EMBEDDED_PLAYER", @"name", @"2.20260708.00.00", @"version", @"56", @"number",
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)", @"ua",
            @"", @"extra", [NSNumber numberWithDouble:3.5], @"timeout", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"Web", @"label", @"WEB", @"name", @"2.20260708.00.00", @"version", @"1", @"number",
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36", @"ua",
            @"", @"extra", [NSNumber numberWithDouble:3.5], @"timeout", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"Android", @"label", @"ANDROID", @"name", @"21.26.364", @"version", @"3", @"number",
            @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip", @"ua",
            @",\"androidSdkVersion\":30,\"osName\":\"Android\",\"osVersion\":\"11\"", @"extra", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"TV", @"label", @"TVHTML5", @"name", @"7.20260707.07.00", @"version", @"7", @"number",
            @"Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)", @"ua", @"", @"extra", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"TV old", @"label", @"TVHTML5", @"name", @"5.20260707", @"version", @"7", @"number",
            @"Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version", @"ua", @"", @"extra", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"VisionOS", @"label", @"VISIONOS", @"name", @"1.02", @"version", @"101", @"number",
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", @"ua",
            @",\"deviceMake\":\"Apple\",\"deviceModel\":\"RealityDevice17,1\",\"osName\":\"visionOS\",\"osVersion\":\"26.5.23O471\"", @"extra", nil], nil];
}

static NSString *YTPlayerResponse(NSString *videoID, NSDictionary *client, NSString **errorText) {
    NSString *body = [NSString stringWithFormat:
        @"{\"context\":{\"client\":{\"clientName\":\"%@\",\"clientVersion\":\"%@\","
        @"\"userAgent\":\"%@\",\"hl\":\"en\",\"gl\":\"US\"%@}},"
        @"\"videoId\":\"%@\",\"contentCheckOk\":true,\"racyCheckOk\":true}",
        [client objectForKey:@"name"], [client objectForKey:@"version"],
        [client objectForKey:@"ua"], [client objectForKey:@"extra"], videoID];
    NSNumber *timeout=[client objectForKey:@"timeout"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout ? [timeout doubleValue] : 8.0];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[client objectForKey:@"number"] forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:[client objectForKey:@"version"] forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [request setValue:[client objectForKey:@"ua"] forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    NSURLResponse *response = nil;
    NSError *failure = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&failure];
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (!data || status < 200 || status >= 300) {
        if (errorText) *errorText = failure ? [failure localizedDescription] :
            [NSString stringWithFormat:@"player HTTP %d", (int)status];
        return nil;
    }
    NSString *json = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    NSString *trimmed = [json stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"{"]) {
        if (errorText) *errorText = @"YouTube returned a page instead of a player response.";
        return nil;
    }
    return json;
}

static NSDictionary *YTSafariHLSClient(void) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
        @"Web Safari HLS",@"label",@"WEB",@"name",@"2.20260708.00.00",@"version",@"1",@"number",
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",@"ua",
        @"",@"extra",[NSNumber numberWithDouble:3.0],@"timeout",nil];
}

static NSDictionary *YTHLSStreamsForID(NSString *videoID) {
    NSDictionary *client=YTSafariHLSClient();
    NSString *ua=[client objectForKey:@"ua"];
    NSString *watchURL=[NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@&hl=en&gl=US",videoID];
    NSData *watchData=YTGETWithUserAgent(watchURL,ua,3.0,NULL);
    NSString *watch=watchData ? [[[NSString alloc] initWithData:watchData encoding:NSUTF8StringEncoding] autorelease] : nil;
    // A normal Safari page establishes the short-lived logged-out session
    // YouTube currently expects before exposing its Apple HLS ladder.
    NSString *hls=YTJSONStringForKey(watch,@"hlsManifestUrl",0);
    if(![hls length]) {
        NSString *player=YTPlayerResponse(videoID,client,NULL);
        hls=YTJSONStringForKey(player,@"hlsManifestUrl",0);
    }
    if(![hls hasPrefix:@"https://"]) return nil;
    NSDictionary *info=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES],@"eligible",
        [NSNumber numberWithInt:0],@"profile",[NSNumber numberWithInt:0],@"level",
        [NSNumber numberWithDouble:0],@"fps",[NSNumber numberWithInt:256],@"width",
        [NSNumber numberWithInt:144],@"height",[NSNumber numberWithLongLong:0],@"length",nil];
    return [NSDictionary dictionaryWithObjectsAndKeys:
        [NSURL URLWithString:hls],@"hlsURL",
        [NSNumber numberWithBool:YES],@"nativeHLS",
        [NSNumber numberWithBool:YES],@"nativeCandidate",
        [NSNumber numberWithBool:YES],@"combined",
        info,@"nativeInfo",
        [NSNumber numberWithInteger:144],@"height",
        [NSNumber numberWithInteger:91],@"videoItag",
        [NSNumber numberWithInteger:0],@"fps",
        ua,@"userAgent",
        @"Web Safari HLS",@"clientLabel",
        @"Safari HLS: 144p-only legacy bridge, 3-segment prebuffer",@"nativeSearch",nil];
}

static NSString *YTHTML(NSString *url, NSString **errorText) {
    NSData *data = YTGET(url, errorText);
    if (!data) return nil;
    NSString *html = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!html && errorText) *errorText = @"YouTube returned a page that was not UTF-8.";
    return html;
}

static NSString *YTObjectForKey(NSString *text, NSString *key) {
    NSRange location = [text rangeOfString:[NSString stringWithFormat:@"\"%@\"", key]];
    if (!text || location.location == NSNotFound) return nil;
    NSUInteger index = location.location + location.length;
    while (index < [text length] && [text characterAtIndex:index] != '{') index++;
    return YTBalancedObject(text, index);
}
static NSString *YTQueryValue(NSString *address, NSString *wanted) {
    NSRange question = [address rangeOfString:@"?"];
    if (!address || question.location == NSNotFound) return nil;
    for (NSString *part in [[address substringFromIndex:question.location + 1] componentsSeparatedByString:@"&"]) {
        NSRange equals = [part rangeOfString:@"="];
        if (equals.location != NSNotFound && [[part substringToIndex:equals.location] isEqualToString:wanted])
            return [[part substringFromIndex:equals.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    }
    return nil;
}
static NSURL *YTFormatURL(NSString *format) {
    NSString *address = YTJSONStringForKey(format, @"url", 0);
    if (![address length]) {
        NSString *cipher = YTJSONStringForKey(format, @"signatureCipher", 0);
        if (!cipher) cipher = YTJSONStringForKey(format, @"cipher", 0);
        NSString *encrypted = YTQueryValue([@"?" stringByAppendingString:(cipher ? cipher : @"")], @"s");
        if (![encrypted length]) {
            address = YTQueryValue([@"?" stringByAppendingString:(cipher ? cipher : @"")], @"url");
            NSString *signature = YTQueryValue([@"?" stringByAppendingString:(cipher ? cipher : @"")], @"sig");
            if ([signature length]) {
                NSString *parameter = YTQueryValue([@"?" stringByAppendingString:cipher], @"sp");
                if (![parameter length]) parameter = @"signature";
                address = [address stringByAppendingFormat:@"&%@=%@", parameter, YTQueryEscape(signature)];
            }
        }
    }
    return [address hasPrefix:@"https://"] ? [NSURL URLWithString:address] : nil;
}
static long long YTFormatLength(NSString *format) {
    NSString *value = YTJSONStringForKey(format, @"contentLength", 0);
    if ([value longLongValue] > 0) return [value longLongValue];
    if (format) {
        NSRange key = [format rangeOfString:@"\"contentLength\""];
        if (key.location != NSNotFound) {
            NSScanner *scan = [NSScanner scannerWithString:[format substringFromIndex:key.location + key.length]];
            long long length = 0;
            if ([scan scanString:@":" intoString:NULL] && [scan scanLongLong:&length] && length > 0) return length;
        }
    }
    return [YTQueryValue([YTFormatURL(format) absoluteString], @"clen") longLongValue];
}
static NSInteger YTFormatRank(NSString *format, BOOL video) {
    NSInteger itag = YTJSONIntForKey(format, @"itag");
    NSString *mime = YTJSONStringForKey(format, @"mimeType", 0);
    if (video) {
        if ([mime length] && ([mime rangeOfString:@"video/mp4"].location == NSNotFound ||
                             [mime rangeOfString:@"avc1"].location == NSNotFound)) return -1;
        NSInteger width = YTJSONIntForKey(format, @"width"), height = YTJSONIntForKey(format, @"height");
        if (width > 0 && height > 0) {
            if (width > 384 || height > 384 || width * height > 38400) return -1;
        } else if (itag != 597 && itag != 160) return -1;
        NSInteger fps=YTJSONIntForKey(format, @"fps");
        // The original iPhone cannot sustain 30 fps Main-profile software
        // decode. Prefer YouTube's lower-bitrate 15 fps 144p representation.
        NSInteger rank=itag == 597 ? 0 : itag == 160 ? 10 : 5;
        if(fps>=24) rank+=5;
        return rank;
    }
    if ([mime length] && ([mime rangeOfString:@"audio/mp4"].location == NSNotFound ||
                         [mime rangeOfString:@"mp4a.40.2"].location == NSNotFound)) return -1;
    if (![mime length] && itag != 140) return -1;
    return itag == 140 ? 0 : 1;
}
static NSString *YTChooseFormat(NSArray *formats, BOOL video) {
    NSString *best = nil;
    NSInteger bestRank = 999;
    for (NSString *format in formats) {
        NSInteger rank = YTFormatRank(format, video);
        if (rank >= 0 && YTFormatLength(format) <= 0) rank += 20;
        if (rank >= 0 && rank < bestRank && YTFormatURL(format)) { best = format; bestRank = rank; }
    }
    return best;
}
static NSDictionary *YTLowResolutionClient(void) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
        @"ANDROID_VR",@"name",@"1.65.10",@"version",@"28",@"number",
        @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",@"ua",
        @",\"deviceMake\":\"Oculus\",\"deviceModel\":\"Quest 3\",\"androidSdkVersion\":32,\"osName\":\"Android\",\"osVersion\":\"12L\"",@"extra",
        [NSNumber numberWithDouble:4.0],@"timeout",nil];
}
static NSDictionary *YTLighterVideoForID(NSString *videoID) {
    // A successful first client can expose only 30 fps. Check the existing
    // lightweight client once; do not resolve or replace the working audio.
    NSDictionary *client=YTLowResolutionClient();
    NSString *player=YTPlayerResponse(videoID,client,NULL);
    NSString *streaming=YTObjectForKey(player,@"streamingData");
    if(!streaming) return nil;
    NSString *format=YTChooseFormat(YTJSONObjectStringsInArray(streaming,@"adaptiveFormats"),YES);
    if(!format) return nil;
    NSInteger fps=YTJSONIntForKey(format,@"fps"),itag=YTJSONIntForKey(format,@"itag");
    if(fps<=0 && itag==597) fps=15;
    long long length=YTFormatLength(format);
    if(fps<=0 || fps>18 || length<=0) return nil;
    NSURL *url=YTFormatURL(format);
    YTMediaSource *video=[[[YTMediaSource alloc] initWithURL:url length:length userAgent:[client objectForKey:@"ua"]] autorelease];
    [video setRequestTimeout:3];
    unsigned char bytes[12];
    if([video readAtOffset:0 into:bytes count:12]!=12) return nil;
    [video setRequestTimeout:12];
    return [NSDictionary dictionaryWithObjectsAndKeys:url,@"videoURL",video,@"videoSource",
        [NSNumber numberWithLongLong:length],@"videoLength",[NSNumber numberWithInteger:fps],@"fps",
        [NSNumber numberWithInteger:itag],@"videoItag",
        [NSNumber numberWithInteger:YTJSONIntForKey(format,@"height")],@"height",nil];
}
static BOOL YTMimeNativeCandidate(NSString *mime) {
    return [mime length] && ([mime rangeOfString:@"avc1.42" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
        [mime rangeOfString:@"mp4v.20.3" options:NSCaseInsensitiveSearch].location!=NSNotFound);
}
static NSString *YTChooseLegacy3GP(NSArray *formats) {
    // YouTube's Android itag 17 is a combined 176x144 3GP movie using
    // MPEG-4 Visual Simple Profile plus AAC-LC. This is dramatically cheaper
    // for the original iPhone than modern Main-profile H.264.
    for(NSString *format in formats) {
        if(YTJSONIntForKey(format,@"itag")!=17 || !YTFormatURL(format)) continue;
        NSString *mime=YTJSONStringForKey(format,@"mimeType",0);
        if([mime length] &&
           ([mime rangeOfString:@"video/3gpp" options:NSCaseInsensitiveSearch].location==NSNotFound ||
            [mime rangeOfString:@"mp4v.20.3" options:NSCaseInsensitiveSearch].location==NSNotFound ||
            [mime rangeOfString:@"mp4a.40.2" options:NSCaseInsensitiveSearch].location==NSNotFound))
            continue;
        return format;
    }
    return nil;
}
static NSString *YTChooseCombinedMP4(NSArray *formats) {
    NSString *best=nil; long long bestRank=LLONG_MAX;
    for (NSString *format in formats) {
        if (!YTFormatURL(format)) continue;
        NSString *mime = YTJSONStringForKey(format, @"mimeType", 0);
        if (![mime length] && YTJSONIntForKey(format,@"itag")!=18) continue;
        if ([mime length] && (([mime rangeOfString:@"video/mp4"].location == NSNotFound &&
                              [mime rangeOfString:@"video/3gpp"].location == NSNotFound) ||
                             ([mime rangeOfString:@"avc1"].location == NSNotFound &&
                              [mime rangeOfString:@"mp4v.20"].location == NSNotFound) ||
                             [mime rangeOfString:@"mp4a.40.2"].location == NSNotFound)) continue;
        NSInteger width = YTJSONIntForKey(format, @"width"), height = YTJSONIntForKey(format, @"height");
        if (width > 640 || height > 640 || (width > 0 && height > 0 && width * height > 307200)) continue;
        long long pixels=width>0 && height>0 ? width*height : 307200;
        long long rank=pixels+(YTMimeNativeCandidate(mime) ? 0 : 1000000000LL);
        if(rank<bestRank) { best=format; bestRank=rank; }
    }
    return best;
}
static NSString *YTFormatAccess(NSString *format) {
    if (YTFormatURL(format)) return @"URL";
    NSString *cipher = YTJSONStringForKey(format, @"signatureCipher", 0);
    if (!cipher) cipher = YTJSONStringForKey(format, @"cipher", 0);
    if ([YTQueryValue([@"?" stringByAppendingString:(cipher ? cipher : @"")], @"s") length]) return @"ciphered";
    return @"no-URL";
}
static NSString *YTPlayerDiagnostic(NSString *player, NSArray *formats) {
    NSString *playability = YTObjectForKey(player, @"playabilityStatus");
    NSString *status = YTJSONStringForKey(playability, @"status", 0);
    NSString *reason = YTJSONStringForKey(playability, @"reason", 0);
    if (![reason length]) reason = YTJSONStringForKey(playability, @"simpleText", 0);
    if ([reason length]) return [NSString stringWithFormat:@"%@: %@", status ? status : @"YouTube", reason];
    NSMutableArray *available = [NSMutableArray array];
    for (NSString *format in formats) {
        NSInteger itag = YTJSONIntForKey(format, @"itag");
        NSString *access = YTFormatAccess(format);
        [available addObject:[NSString stringWithFormat:@"%d/%@", (int)itag, access]];
        if ([available count] >= 24) break;
    }
    return [NSString stringWithFormat:@"status %@; formats %@", status ? status : @"missing",
            [available count] ? [available componentsJoinedByString:@","] : @"none"];
}

@interface YTLengthRequest : NSObject {
@public
    long long length;
    BOOL done;
    NSURLConnection *connection;
}
@end
@implementation YTLengthRequest
- (void)connection:(NSURLConnection *)sender didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *mime = [response MIMEType];
        if (([http statusCode] == 200 || [http statusCode] == 206) &&
            ([mime hasPrefix:@"video/"] || [mime hasPrefix:@"audio/"] || [mime isEqualToString:@"application/octet-stream"])) {
            for (NSString *key in [http allHeaderFields]) {
                if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
                    NSString *value = [[http allHeaderFields] objectForKey:key];
                    NSRange slash = [value rangeOfString:@"/" options:NSBackwardsSearch];
                    if (slash.location != NSNotFound) length = [[value substringFromIndex:slash.location + 1] longLongValue];
                }
            }
            if (length <= 0 && [http statusCode] == 200) length = [response expectedContentLength];
        }
    }
    done = YES;
    [sender cancel];
}
- (void)connection:(NSURLConnection *)sender didFailWithError:(NSError *)error { done = YES; }
- (void)connectionDidFinishLoading:(NSURLConnection *)sender { done = YES; }
- (void)dealloc { [connection cancel]; [connection release]; [super dealloc]; }
@end
static long long YTRemoteLength(NSURL *url, NSString *userAgent) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [request setHTTPMethod:@"HEAD"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    YTLengthRequest *probe = [[YTLengthRequest alloc] init];
    probe->connection = [[NSURLConnection alloc] initWithRequest:request delegate:probe];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6.5];
    while (probe->connection && !probe->done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    long long length = probe->length;
    [probe->connection cancel];
    [probe release];
    return length;
}


static NSMutableDictionary *YTCombinedCandidateFromPlayer(NSString *player, NSString *userAgent) {
    NSString *streaming=YTObjectForKey(player,@"streamingData");
    if(!streaming) return nil;
    NSMutableArray *formats=[NSMutableArray array];
    [formats addObjectsFromArray:YTJSONObjectStringsInArray(streaming,@"formats")];
    [formats addObjectsFromArray:YTJSONObjectStringsInArray(streaming,@"adaptiveFormats")];
    NSString *format=YTChooseLegacy3GP(formats);
    if(!format) format=YTChooseCombinedMP4(formats);
    if(!format) return nil;
    NSURL *url=YTFormatURL(format);
    if(!url) return nil;
    NSInteger itag=YTJSONIntForKey(format,@"itag");
    NSInteger fps=YTJSONIntForKey(format,@"fps");
    if(fps<=0 && itag==17) fps=10;
    NSMutableDictionary *streams=[NSMutableDictionary dictionaryWithObjectsAndKeys:
        url,@"videoURL",url,@"audioURL",
        [NSNumber numberWithLongLong:YTFormatLength(format)],@"videoLength",
        [NSNumber numberWithLongLong:YTFormatLength(format)],@"audioLength",
        [NSNumber numberWithBool:YES],@"combined",
        [NSNumber numberWithBool:YES],@"nativeCandidate",
        [NSNumber numberWithInteger:YTJSONIntForKey(format,@"height")],@"height",
        [NSNumber numberWithInteger:fps],@"fps",
        [NSNumber numberWithInteger:itag],@"videoItag",
        userAgent,@"userAgent",nil];
    return streams;
}

static NSMutableDictionary *YTAdaptiveCandidateFromPlayer(NSString *player, NSString *userAgent) {
    NSString *streaming=YTObjectForKey(player,@"streamingData");
    if(!streaming) return nil;
    NSArray *formats=YTJSONObjectStringsInArray(streaming,@"adaptiveFormats");
    NSString *video=YTChooseFormat(formats,YES),*audio=YTChooseFormat(formats,NO);
    if(!video || !audio) return nil;
    NSInteger itag=YTJSONIntForKey(video,@"itag");
    NSInteger fps=YTJSONIntForKey(video,@"fps");
    if(fps<=0) {
        if(itag==597) fps=15;
        else if(itag==160) fps=30;
    }
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:
        YTFormatURL(video),@"videoURL",YTFormatURL(audio),@"audioURL",
        [NSNumber numberWithLongLong:YTFormatLength(video)],@"videoLength",
        [NSNumber numberWithLongLong:YTFormatLength(audio)],@"audioLength",
        [NSNumber numberWithBool:NO],@"combined",
        [NSNumber numberWithBool:NO],@"nativeCandidate",
        [NSNumber numberWithInteger:YTJSONIntForKey(video,@"height")],@"height",
        [NSNumber numberWithInteger:fps],@"fps",
        [NSNumber numberWithInteger:itag],@"videoItag",
        userAgent,@"userAgent",nil];
}

static NSMutableDictionary *YTPrepareStreams(NSMutableDictionary *streams, NSString **failure) {
    long long videoLength=[[streams objectForKey:@"videoLength"] longLongValue];
    long long audioLength=[[streams objectForKey:@"audioLength"] longLongValue];
    NSString *ua=[streams objectForKey:@"userAgent"];
    if(videoLength<=0) videoLength=YTRemoteLength([streams objectForKey:@"videoURL"],ua);
    if([[streams objectForKey:@"combined"] boolValue]) audioLength=videoLength;
    if(audioLength<=0) audioLength=YTRemoteLength([streams objectForKey:@"audioURL"],ua);
    [streams setObject:[NSNumber numberWithLongLong:videoLength] forKey:@"videoLength"];
    [streams setObject:[NSNumber numberWithLongLong:audioLength] forKey:@"audioLength"];
    if(videoLength<=0 || audioLength<=0) {
        if(failure) *failure=[NSString stringWithFormat:@"URLs found but byte lengths missing (video %lld, audio %lld).",videoLength,audioLength];
        return nil;
    }
    YTMediaSource *video=[[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"videoURL"] length:videoLength userAgent:ua] autorelease];
    YTMediaSource *audio=[[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"audioURL"] length:audioLength userAgent:ua] autorelease];
    if([[streams objectForKey:@"combined"] boolValue]) [audio shareCacheWithSource:video];
    unsigned char header[12];
    if([video readAtOffset:0 into:header count:12]!=12) {
        if(failure) *failure=[video errorText]; return nil;
    }
    if([audio readAtOffset:0 into:header count:12]!=12) {
        if(failure) *failure=[audio errorText]; return nil;
    }
    [streams setObject:video forKey:@"videoSource"];
    [streams setObject:audio forKey:@"audioSource"];
    return streams;
}

@implementation YTYouTube

+ (NSArray *)search:(NSString *)query error:(NSString **)errorText {
    NSString *url = [NSString stringWithFormat:
        @"https://www.youtube.com/results?search_query=%@&hl=en&gl=US",
        YTQueryEscape(query)];

    NSString *requestError = nil;
    NSString *html = YTHTML(url, &requestError);
    if (!html) {
        if (errorText) *errorText = requestError;
        return nil;
    }

    NSMutableArray *results = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *marker = @"\"videoRenderer\":";
    NSUInteger pos = 0;

    while (pos < [html length] && [results count] < 20) {
        NSRange r = [html rangeOfString:marker options:0
                                  range:NSMakeRange(pos, [html length] - pos)];
        if (r.location == NSNotFound) break;

        NSUInteger brace = r.location + r.length;
        while (brace < [html length] && [html characterAtIndex:brace] != '{') brace++;
        NSString *obj = YTBalancedObject(html, brace);
        if (!obj) {
            pos = r.location + r.length;
            continue;
        }

        NSString *videoID = YTJSONStringForKey(obj, @"videoId", 0);
        if (videoID && [videoID length] == 11 && ![seen containsObject:videoID]) {
            NSString *title = nil;
            NSString *author = nil;

            NSRange titleRange = [obj rangeOfString:@"\"title\""];
            if (titleRange.location != NSNotFound)
                title = YTJSONStringForKey(obj, @"text", titleRange.location);

            NSRange ownerRange = [obj rangeOfString:@"\"ownerText\""];
            if (ownerRange.location == NSNotFound)
                ownerRange = [obj rangeOfString:@"\"longBylineText\""];
            if (ownerRange.location != NSNotFound)
                author = YTJSONStringForKey(obj, @"text", ownerRange.location);

            if (!title) title = videoID;
            if (!author) author = @"YouTube";

            [results addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                videoID, @"id", title, @"title", author, @"author", nil]];
            [seen addObject:videoID];
        }
        pos = brace + [obj length];
    }

    if (![results count]) {
        if (errorText) {
            if ([html rangeOfString:@"consent.youtube.com"].location != NSNotFound)
                *errorText = @"YouTube sent a consent page instead of search results.";
            else
                *errorText = @"YouTube search page loaded, but no video results were found.";
        }
        return nil;
    }
    return results;
}

+ (NSDictionary *)streamsFromPlayerResponse:(NSString *)player userAgent:(NSString *)userAgent error:(NSString **)errorText {
    NSString *streaming = YTObjectForKey(player, @"streamingData");
    NSMutableArray *formats = [NSMutableArray array];
    if (streaming) {
        [formats addObjectsFromArray:YTJSONObjectStringsInArray(streaming, @"formats")];
        [formats addObjectsFromArray:YTJSONObjectStringsInArray(streaming, @"adaptiveFormats")];
    }
    NSString *legacy=YTChooseLegacy3GP(formats);
    NSString *video = YTChooseFormat(formats, YES), *audio = YTChooseFormat(formats, NO);
    BOOL combined = legacy != nil;
    NSString *mp4 = legacy ? legacy : YTChooseCombinedMP4(formats);
    NSString *combinedMime=YTJSONStringForKey(mp4,@"mimeType",0);
    // Always take Android itag 17 when it is exposed. Otherwise preserve the
    // existing native Baseline/MPEG-4 candidate preference.
    BOOL nativeCandidate=legacy != nil || (mp4 && YTMimeNativeCandidate(combinedMime));
    if(legacy) {
        video=audio=legacy;
    } else if (nativeCandidate || !video || !audio) {
        if (mp4) { video = audio = mp4; combined = YES; }
    }
    if (!video || !audio) {
        if (errorText) *errorText = [NSString stringWithFormat:@"%@ missing; %@",
            !video && !audio ? @"144p H.264 and AAC-LC" : !video ? @"144p H.264" : @"AAC-LC",
            YTPlayerDiagnostic(player, formats)];
        return nil;
    }
    NSInteger sourceFPS=YTJSONIntForKey(video,@"fps"); if(sourceFPS<0) sourceFPS=0;
    NSInteger videoItag=YTJSONIntForKey(video,@"itag"); if(videoItag<0) videoItag=0;
    if(sourceFPS<=0) {
        if(videoItag==17) sourceFPS=10;
        else if(videoItag==597) sourceFPS=15;
        else if(videoItag==160) sourceFPS=30;
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
        YTFormatURL(video), @"videoURL", YTFormatURL(audio), @"audioURL",
        [NSNumber numberWithLongLong:YTFormatLength(video)], @"videoLength",
        [NSNumber numberWithLongLong:YTFormatLength(audio)], @"audioLength",
        [NSNumber numberWithBool:combined], @"combined",
        [NSNumber numberWithBool:combined && nativeCandidate], @"nativeCandidate",
        [NSNumber numberWithInteger:YTJSONIntForKey(video,@"height")], @"height",
        [NSNumber numberWithInteger:sourceFPS], @"fps",
        [NSNumber numberWithInteger:videoItag], @"videoItag",
        userAgent, @"userAgent", nil];
}

+ (NSDictionary *)playbackStreamsForID:(NSString *)videoID error:(NSString **)errorText {
    // Version 2.0 first recreates the original iPhone-era delivery model:
    // Safari HLS, a single tiny rendition, local HTTP, and real prebuffering.
    NSDictionary *hls=YTHLSStreamsForID(videoID);
    if(hls) return hls;
    NSArray *clients=YTPlayerClients();
    NSMutableArray *errors=[NSMutableArray array];
    NSMutableArray *fallbacks=[NSMutableArray array];
    NSMutableArray *nativeNotes=[NSMutableArray array];
    NSMutableSet *nativeFingerprints=[NSMutableSet set];

    // Phase 1: search every client for a genuinely hardware-compatible
    // pre-muxed movie. Do not trust MIME/profile hints; probe the bytes.
    for(NSDictionary *client in clients) {
        NSString *failure=nil;
        NSString *player=YTPlayerResponse(videoID,client,&failure);
        if(!player) {
            [errors addObject:[NSString stringWithFormat:@"%@: %@",[client objectForKey:@"label"],failure ? failure : @"No player response."]];
            continue;
        }

        // Once a native movie has not yet been proven, keep the software
        // fallback at the true adaptive 144p representation. Never fall back
        // to the same 360p itag 18 that just failed the native profile probe.
        NSMutableDictionary *normal=YTAdaptiveCandidateFromPlayer(player,[client objectForKey:@"ua"]);
        if(normal) {
            [normal setObject:[client objectForKey:@"label"] forKey:@"clientLabel"];
            // Preserve Android as the proven software/audio fallback. The web
            // clients are queried only to find a hardware-decodable format 18.
            if([[client objectForKey:@"label"] isEqualToString:@"Android"])
                [fallbacks insertObject:normal atIndex:0];
            else
                [fallbacks addObject:normal];
        }

        NSMutableDictionary *candidate=YTCombinedCandidateFromPlayer(player,[client objectForKey:@"ua"]);
        if(!candidate) {
            [nativeNotes addObject:[NSString stringWithFormat:@"%@: no combined movie",[client objectForKey:@"label"]]];
            continue;
        }
        [candidate setObject:[client objectForKey:@"label"] forKey:@"clientLabel"];
        long long declaredLength=[[candidate objectForKey:@"videoLength"] longLongValue];
        NSString *fingerprint=declaredLength>0 ?
            [NSString stringWithFormat:@"%@:%lld",[candidate objectForKey:@"videoItag"],declaredLength] :
            [[candidate objectForKey:@"videoURL"] absoluteString];
        if([fingerprint length] && [nativeFingerprints containsObject:fingerprint]) {
            [nativeNotes addObject:[NSString stringWithFormat:@"%@: same combined rendition",[client objectForKey:@"label"]]];
            continue;
        }
        if([fingerprint length]) [nativeFingerprints addObject:fingerprint];
        NSString *candidateFailure=nil;
        if(!YTPrepareStreams(candidate,&candidateFailure)) {
            [nativeNotes addObject:[NSString stringWithFormat:@"%@: combined unavailable",[client objectForKey:@"label"]]];
            continue;
        }
        NSDictionary *info=YTNativeStreamInfo(candidate);
        if(info) [candidate setObject:info forKey:@"nativeInfo"];
        [nativeNotes addObject:[NSString stringWithFormat:@"%@: itag %@ p%@ L%@ %@x%@ %@",
            [client objectForKey:@"label"],
            [candidate objectForKey:@"videoItag"] ? [candidate objectForKey:@"videoItag"] : @"?",
            info ? [info objectForKey:@"profile"] : @"?",
            info ? [info objectForKey:@"level"] : @"?",
            info ? [info objectForKey:@"width"] : @"?",
            info ? [info objectForKey:@"height"] : @"?",
            (info && [[info objectForKey:@"eligible"] boolValue]) ? @"native" : @"rejected"]];
        if(info && [[info objectForKey:@"eligible"] boolValue]) {
            [candidate setObject:[nativeNotes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
            [[NSUserDefaults standardUserDefaults] setObject:[client objectForKey:@"label"] forKey:@"YTWorkingClient"];
            return candidate;
        }
    }

    // Phase 2: no hardware-compatible movie exists. Prepare the first working
    // software fallback only now, avoiding the old extra 144p/VR detours.
    for(NSMutableDictionary *fallback in fallbacks) {
        NSString *failure=nil;
        if(YTPrepareStreams(fallback,&failure)) {
            if([nativeNotes count]) [fallback setObject:[nativeNotes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
            [[NSUserDefaults standardUserDefaults] setObject:[fallback objectForKey:@"clientLabel"] forKey:@"YTWorkingClient"];
            return fallback;
        }
        [errors addObject:[NSString stringWithFormat:@"%@: %@",[fallback objectForKey:@"clientLabel"],failure ? failure : @"Media URL failed."]];
    }

    if(errorText) *errorText=[errors componentsJoinedByString:@"\n\n"];
    return nil;
}

static NSDictionary *YTSABRFormat(NSString *format) {
    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInteger:YTJSONIntForKey(format,@"itag")],@"itag",
        [NSNumber numberWithInteger:YTJSONIntForKey(format,@"width")],@"width",
        [NSNumber numberWithInteger:YTJSONIntForKey(format,@"height")],@"height",
        [NSNumber numberWithLongLong:YTFormatLength(format)],@"length",nil];
    for(NSString *key in [NSArray arrayWithObjects:@"lastModified",@"xtags",@"approxDurationMs",nil]) {
        NSString *value=YTJSONStringForKey(format,key,0);
        if(value) [result setObject:value forKey:[key isEqualToString:@"approxDurationMs"] ? @"duration" : key];
    }
    return result;
}
+ (NSDictionary *)phoneOnlyStreamsForID:(NSString *)videoID original:(NSDictionary *)original error:(NSString **)errorText {
    NSString *player=[original objectForKey:@"playerResponse"],*failure=nil;
    NSDictionary *client=[YTPlayerClients() objectAtIndex:0];
    if(!player || ![[original objectForKey:@"clientLabel"] isEqualToString:@"Android"])
        player=YTPlayerResponse(videoID,client,&failure);
    NSString *streaming=YTObjectForKey(player,@"streamingData");
    NSArray *formats=YTJSONObjectStringsInArray(streaming,@"adaptiveFormats");
    NSString *video=nil,*audio=nil; NSInteger rank=NSIntegerMax;
    for(NSString *format in formats) {
        NSInteger r=YTFormatRank(format,YES);
        if(r>=0 && r<rank && YTFormatLength(format)>0) { video=format; rank=r; }
        if(!audio && YTFormatRank(format,NO)>=0) audio=format;
    }
    NSString *config=YTJSONStringForKey(YTObjectForKey(YTObjectForKey(YTObjectForKey(player,@"playerConfig"),@"mediaCommonConfig"),@"mediaUstreamerRequestConfig"),@"videoPlaybackUstreamerConfig",0);
    NSURL *url=[NSURL URLWithString:YTJSONStringForKey(streaming,@"serverAbrStreamingUrl",0)];
    if(!video || !audio || !config || !url || ![original objectForKey:@"audioSource"]) {
        if(errorText) *errorText=failure ? failure : @"YouTube did not supply a usable phone-only 144p stream.";
        return nil;
    }
    NSDictionary *options=[NSDictionary dictionaryWithObjectsAndKeys:url,@"url",config,@"config",
        YTSABRFormat(video),@"video",YTSABRFormat(audio),@"audio",videoID,@"videoID",
        [client objectForKey:@"number"],@"clientNumber",[client objectForKey:@"version"],@"clientVersion",
        [client objectForKey:@"ua"],@"userAgent",nil];
    NSString *path=YTDownloadSABRVideo(options,&failure);
    if(!path) { if(errorText) *errorText=failure; return nil; }
    NSURL *local=[NSURL fileURLWithPath:path];
    YTMediaSource *source=[[[YTMediaSource alloc] initWithURL:local length:0 userAgent:nil] autorelease];
    NSMutableDictionary *chosen=[[original mutableCopy] autorelease];
    [chosen setObject:local forKey:@"videoURL"]; [chosen setObject:source forKey:@"videoSource"];
    [chosen setObject:[NSNumber numberWithLongLong:[source length]] forKey:@"videoLength"];
    [chosen setObject:[NSNumber numberWithBool:NO] forKey:@"combined"];
    [chosen setObject:[NSNumber numberWithBool:NO] forKey:@"nativeCandidate"];
    [chosen removeObjectForKey:@"nativeInfo"]; [chosen removeObjectForKey:@"playerResponse"];
    [chosen setObject:[NSNumber numberWithInteger:YTJSONIntForKey(video,@"height")] forKey:@"height"];
    [chosen setObject:[NSNumber numberWithInteger:YTJSONIntForKey(video,@"fps")] forKey:@"fps"];
    [chosen setObject:[NSNumber numberWithInteger:YTJSONIntForKey(video,@"itag")] forKey:@"videoItag"];
    [chosen setObject:@"Android SABR, prepared on phone" forKey:@"clientLabel"];
    [chosen setObject:[NSNumber numberWithBool:YES] forKey:@"phonePrepared"];
    return chosen;
}

+ (NSDictionary *)softwareFallbackForID:(NSString *)videoID error:(NSString **)errorText {
    NSMutableArray *errors=[NSMutableArray array];
    for(NSDictionary *client in YTPlayerClients()) {
        NSString *failure=nil;
        NSString *player=YTPlayerResponse(videoID,client,&failure);
        if(!player) {
            if(failure) [errors addObject:[NSString stringWithFormat:@"%@: %@",[client objectForKey:@"label"],failure]];
            continue;
        }
        NSMutableDictionary *streams=YTAdaptiveCandidateFromPlayer(player,[client objectForKey:@"ua"]);
        if(!streams) continue;
        [streams setObject:[client objectForKey:@"label"] forKey:@"clientLabel"];
        if(YTPrepareStreams(streams,&failure)) return streams;
        if(failure) [errors addObject:[NSString stringWithFormat:@"%@: %@",[client objectForKey:@"label"],failure]];
    }
    if(errorText) *errorText=[errors count] ? [errors componentsJoinedByString:@"\n\n"] :
        @"YouTube did not expose a direct 144p H.264 + AAC fallback.";
    return nil;
}

// Try one additional client only when the current combined stream needs
// expensive software decoding. Keep the already working stream on failure.
+ (NSDictionary *)lowResolutionStreamsForID:(NSString *)videoID {
    NSDictionary *client=YTLowResolutionClient();
    NSString *player=YTPlayerResponse(videoID,client,NULL);
    NSMutableDictionary *streams=player ? [[[self streamsFromPlayerResponse:player userAgent:[client objectForKey:@"ua"] error:NULL] mutableCopy] autorelease] : nil;
    if(!streams || [[streams objectForKey:@"combined"] boolValue]) return nil;
    long long videoLength=[[streams objectForKey:@"videoLength"] longLongValue],audioLength=[[streams objectForKey:@"audioLength"] longLongValue];
    if(videoLength<=0 || audioLength<=0) return nil; // No extra HEAD delays on this optional route.
    YTMediaSource *video=[[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"videoURL"] length:videoLength userAgent:[client objectForKey:@"ua"]] autorelease];
    YTMediaSource *audio=[[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"audioURL"] length:audioLength userAgent:[client objectForKey:@"ua"]] autorelease];
    [video setRequestTimeout:3]; [audio setRequestTimeout:3];
    unsigned char bytes[12];
    if([video readAtOffset:0 into:bytes count:12]!=12 || [audio readAtOffset:0 into:bytes count:12]!=12) return nil;
    [video setRequestTimeout:12]; [audio setRequestTimeout:12];
    [streams setObject:video forKey:@"videoSource"]; [streams setObject:audio forKey:@"audioSource"];
    return streams;
}

+ (NSString *)videoIDFromText:(NSString *)text {
    if (!text) return nil;
    NSString *s = [text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    NSCharacterSet *bad = [allowed invertedSet];

    if ([s length] == 11 && [s rangeOfCharacterFromSet:bad].location == NSNotFound)
        return s;

    NSArray *needles = [NSArray arrayWithObjects:
        @"v=", @"youtu.be/", @"/shorts/", @"/embed/", nil];

    NSUInteger i;
    for (i = 0; i < [needles count]; i++) {
        NSString *needle = [needles objectAtIndex:i];
        NSRange r = [s rangeOfString:needle];
        if (r.location == NSNotFound) continue;
        NSUInteger start = r.location + r.length;
        if (start + 11 <= [s length]) {
            NSString *candidate = [s substringWithRange:NSMakeRange(start, 11)];
            if ([candidate rangeOfCharacterFromSet:bad].location == NSNotFound)
                return candidate;
        }
    }
    return nil;
}

@end
