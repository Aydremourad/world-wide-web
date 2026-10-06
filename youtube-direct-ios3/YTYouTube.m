#include <limits.h>
#import "YTYouTube.h"
#import "YTMediaSource.h"
#import "YTSABR.h"
#import "YTHLSBridge.h"
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

static NSString *YTJSONQuote(NSString *value) {
    NSMutableString *out=[NSMutableString stringWithString:@"\""];
    for(NSUInteger i=0;i<[value length];i++) {
        unichar c=[value characterAtIndex:i];
        if(c=='"' || c=='\\') [out appendFormat:@"\\%C",c];
        else if(c<32) [out appendFormat:@"\\u%04x",(unsigned)c];
        else [out appendFormat:@"%C",c];
    }
    [out appendString:@"\""]; return out;
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
    NSString *contextExtra=[client objectForKey:@"contextExtra"];
    if(!contextExtra) contextExtra=@"";
    NSString *requestExtra=[client objectForKey:@"requestExtra"];
    if(!requestExtra) requestExtra=@"";
    NSString *body = [NSString stringWithFormat:
        @"{\"context\":{\"client\":{\"clientName\":\"%@\",\"clientVersion\":\"%@\","
        @"\"userAgent\":\"%@\",\"hl\":\"en\",\"gl\":\"US\"%@}%@},"
        @"\"videoId\":\"%@\",\"contentCheckOk\":true,\"racyCheckOk\":true%@}",
        [client objectForKey:@"name"], [client objectForKey:@"version"],
        [client objectForKey:@"ua"], [client objectForKey:@"extra"], contextExtra, videoID, requestExtra];
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
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    if([client objectForKey:@"visitorData"])
        [request setValue:[client objectForKey:@"visitorData"] forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    if([client objectForKey:@"referer"])
        [request setValue:[client objectForKey:@"referer"] forHTTPHeaderField:@"Referer"];
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

static NSDictionary *YTEmbeddedHLSClient(void) {
    // WEB_EMBEDDED_PLAYER currently has no GVS PO-token requirement and can
    // expose the pre-muxed HLS ladder. The thirdParty context is required by
    // YouTube's embedded player contract.
    return [NSDictionary dictionaryWithObjectsAndKeys:
        @"Web embedded HLS",@"label",@"WEB_EMBEDDED_PLAYER",@"name",@"2.20260708.00.00",@"version",@"56",@"number",
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",@"ua",
        @"",@"extra",@",\"thirdParty\":{\"embedUrl\":\"https://aydremourad.github.io/world-wide-web/\"}",@"contextExtra",
        [NSNumber numberWithDouble:4.0],@"timeout",nil];
}

static NSDictionary *YTSafariHLSClient(void) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
        @"Web Safari HLS",@"label",@"WEB",@"name",@"2.20260708.00.00",@"version",@"1",@"number",
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",@"ua",
        @"",@"extra",[NSNumber numberWithDouble:4.0],@"timeout",nil];
}

static NSArray *YTPreparedWebClients(NSString *videoID) {
    // Prepare WEB_EMBEDDED with the context YouTube expects, but DO NOT touch
    // an HLS manifest yet. This lets 1.2.2 test progressive itag 18 first.
    NSMutableDictionary *embedded=[[YTEmbeddedHLSClient() mutableCopy] autorelease];
    NSString *embedPage=[NSString stringWithFormat:@"https://www.youtube.com/embed/%@?hl=en",videoID];
    NSData *pageData=YTGETWithUserAgent(embedPage,[embedded objectForKey:@"ua"],3.0,NULL);
    NSString *page=pageData ? [[[NSString alloc] initWithData:pageData encoding:NSUTF8StringEncoding] autorelease] : nil;
    NSString *visitor=YTJSONStringForKey(page,@"VISITOR_DATA",0);
    if(![visitor length]) visitor=YTJSONStringForKey(page,@"visitorData",0);
    if([visitor length]) {
        [embedded setObject:visitor forKey:@"visitorData"];
        [embedded setObject:[NSString stringWithFormat:@",\"visitorData\":%@",YTJSONQuote(visitor)] forKey:@"extra"];
    }
    NSString *flags=YTJSONStringForKey(page,@"encryptedHostFlags",0);
    if([flags length]) [embedded setObject:[NSString stringWithFormat:
        @",\"playbackContext\":{\"contentPlaybackContext\":{\"html5Preference\":\"HTML5_PREF_WANTS\",\"encryptedHostFlags\":%@}}",
        YTJSONQuote(flags)] forKey:@"requestExtra"];
    [embedded setObject:embedPage forKey:@"referer"];
    return [NSArray arrayWithObjects:embedded,YTSafariHLSClient(),nil];
}

static NSDictionary *YTHLSStreamsFromResponses(NSArray *responses,NSMutableArray *notes) {
    // This is deliberately called only AFTER every progressive combined movie
    // has been probed. No HLS segment is downloaded on the successful itag-18
    // path.
    for(NSDictionary *response in responses) {
        NSDictionary *client=[response objectForKey:@"client"];
        NSString *player=[response objectForKey:@"player"];
        NSString *hls=YTJSONStringForKey(player,@"hlsManifestUrl",0);
        if(![hls hasPrefix:@"https://"]) {
            NSString *status=YTJSONStringForKey(player,@"status",0);
            [notes addObject:[NSString stringWithFormat:@"%@: %@",
                [client objectForKey:@"label"],
                status && ![status isEqualToString:@"OK"] ? status : @"no HLS manifest"]];
            continue;
        }

        YTHLSBridge *bridge=[[[YTHLSBridge alloc] initWithURL:[NSURL URLWithString:hls]
            userAgent:[client objectForKey:@"ua"]] autorelease];
        if(![bridge start]) {
            [notes addObject:[NSString stringWithFormat:@"%@: %@",
                [client objectForKey:@"label"],
                [bridge errorText] ? [bridge errorText] : @"HLS preflight failed"]];
            [bridge stop];
            continue;
        }

        NSInteger height=[bridge selectedHeight];
        double fps=[bridge selectedFPS];
        BOOL baseline=[bridge selectedBaseline];
        NSDictionary *info=[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:baseline],@"eligible",
            [NSNumber numberWithInt:baseline ? 66 : 77],@"profile",
            [NSNumber numberWithInt:30],@"level",
            [NSNumber numberWithDouble:fps],@"fps",
            [NSNumber numberWithInt:256],@"width",
            [NSNumber numberWithInteger:height>0 ? height : 144],@"height",
            [NSNumber numberWithLongLong:0],@"length",nil];
        NSMutableDictionary *ready=[NSMutableDictionary dictionaryWithObjectsAndKeys:
            [NSURL URLWithString:hls],@"hlsURL",
            bridge,@"hlsBridge",
            [NSNumber numberWithBool:baseline],@"nativeHLS",
            [NSNumber numberWithBool:baseline],@"nativeCandidate",
            [NSNumber numberWithBool:!baseline],@"softwareHLS",
            [NSNumber numberWithBool:YES],@"combined",
            info,@"nativeInfo",
            [NSNumber numberWithInteger:height>0 ? height : 144],@"height",
            [NSNumber numberWithInteger:91],@"videoItag",
            [NSNumber numberWithDouble:fps],@"fps",
            [client objectForKey:@"ua"],@"userAgent",
            [client objectForKey:@"label"],@"clientLabel",nil];
        NSString *description=[bridge selectedDescription];
        if([description length])
            [ready setObject:[NSString stringWithFormat:@"%@ via %@",
                description,[client objectForKey:@"label"]] forKey:@"nativeSearch"];
        return ready;
    }
    return nil;
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
static NSString *YTChooseItag18(NSArray *formats) {
    // First choice for the original iPhone: YouTube's progressive itag 18.
    // In 2026 this can still be H.264 Baseline L3.0 + AAC-LC. Do not trust
    // the itag alone: YTNativeStreamInfo() probes the actual MP4 before Apple
    // playback and rejects anything outside the iPhone 2G hardware envelope.
    for (NSString *format in formats) {
        if (YTJSONIntForKey(format, @"itag") != 18 || !YTFormatURL(format)) continue;
        NSString *mime = YTJSONStringForKey(format, @"mimeType", 0);
        if ([mime length]) {
            if ([mime rangeOfString:@"video/mp4" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            if ([mime rangeOfString:@"avc1" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            if ([mime rangeOfString:@"mp4a.40.2" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
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
    BOOL serverNative;
    NSInteger serverWidth, serverHeight, serverFPS;
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
            NSDictionary *headers=[http allHeaderFields];
            for (NSString *key in headers) {
                NSString *value=[headers objectForKey:key];
                if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
                    NSRange slash = [value rangeOfString:@"/" options:NSBackwardsSearch];
                    if (slash.location != NSNotFound) length = [[value substringFromIndex:slash.location + 1] longLongValue];
                } else if([key caseInsensitiveCompare:@"X-YouTube2G-Native"]==NSOrderedSame) {
                    serverNative=[value intValue]==1;
                } else if([key caseInsensitiveCompare:@"X-YouTube2G-Width"]==NSOrderedSame) {
                    serverWidth=[value integerValue];
                } else if([key caseInsensitiveCompare:@"X-YouTube2G-Height"]==NSOrderedSame) {
                    serverHeight=[value integerValue];
                } else if([key caseInsensitiveCompare:@"X-YouTube2G-FPS"]==NSOrderedSame) {
                    serverFPS=[value integerValue];
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

static NSMutableDictionary *YTServerPreparedNativeForID(NSString *videoID, NSString **failure) {
    /*
     * Remote compatibility fallback. The existing youtube-2g backend always
     * transcodes real videos to H.264 Baseline L3.0 + AAC-LC, verifies the
     * result with ffprobe, publishes it atomically, and serves byte ranges.
     * The phone therefore performs ZERO H.264 software decoding on this path.
     */
    NSString *address=[NSString stringWithFormat:
        @"https://aydreyoutube2g.duckdns.org/getvideo/%@",videoID];
    NSURL *url=[NSURL URLWithString:address];
    NSString *ua=@"YouTubeDirect/1.2.4 (iPhone1,1; iPhone OS 3.1.3)";

    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:62.0];
    [request setHTTPMethod:@"HEAD"];
    [request setValue:ua forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    YTLengthRequest *probe=[[YTLengthRequest alloc] init];
    probe->connection=[[NSURLConnection alloc] initWithRequest:request delegate:probe];

    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:62.5];
    while(probe->connection && !probe->done && [deadline timeIntervalSinceNow]>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    long long length=probe->length;
    BOOL native=probe->serverNative;
    NSInteger width=probe->serverWidth>0 ? probe->serverWidth : 320;
    NSInteger height=probe->serverHeight>0 ? probe->serverHeight : 240;
    NSInteger fps=probe->serverFPS>0 ? probe->serverFPS : 24;
    [probe->connection cancel];
    [probe release];

    if(!native || length<=0) {
        if(failure) *failure=native ? @"Server movie had no usable Content-Length." :
            @"Server did not return a prepared native movie within 62 seconds.";
        return nil;
    }

    NSDictionary *info=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES],@"eligible",
        [NSNumber numberWithInt:66],@"profile",
        [NSNumber numberWithInt:30],@"level",
        [NSNumber numberWithInteger:fps],@"fps",
        [NSNumber numberWithInteger:width],@"width",
        [NSNumber numberWithInteger:height],@"height",
        [NSNumber numberWithLongLong:length],@"length",nil];

    return [NSMutableDictionary dictionaryWithObjectsAndKeys:
        url,@"videoURL",url,@"audioURL",
        [NSNumber numberWithLongLong:length],@"videoLength",
        [NSNumber numberWithLongLong:length],@"audioLength",
        [NSNumber numberWithBool:YES],@"combined",
        [NSNumber numberWithBool:YES],@"nativeCandidate",
        info,@"nativeInfo",
        [NSNumber numberWithInteger:height],@"height",
        [NSNumber numberWithInteger:fps],@"fps",
        [NSNumber numberWithInteger:-18],@"videoItag",
        ua,@"userAgent",
        @"YouTube 2G server Baseline MP4",@"clientLabel",
        @"1.2.4 server-prepared H.264 Baseline/AAC-LC native path",@"nativeSearch",nil];
}


static NSMutableDictionary *YTCombinedCandidateFromPlayer(NSString *player, NSString *userAgent) {
    NSString *streaming=YTObjectForKey(player,@"streamingData");
    if(!streaming) return nil;
    NSMutableArray *formats=[NSMutableArray array];
    [formats addObjectsFromArray:YTJSONObjectStringsInArray(streaming,@"formats")];
    [formats addObjectsFromArray:YTJSONObjectStringsInArray(streaming,@"adaptiveFormats")];
    // Prefer progressive itag 18 so the Apple hardware path is tested before
    // the very-low-resolution 3GP escape hatch. The native probe below is the
    // authority: it must report H.264 Baseline (profile 66), level <= 3.0 and
    // AAC-LC before this stream is allowed into MPMoviePlayerController.
    NSString *format=YTChooseItag18(formats);
    if(!format) format=YTChooseLegacy3GP(formats);
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
    if([streams objectForKey:@"videoSource"] && [streams objectForKey:@"audioSource"]) return streams;
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
    [video enableStreamingReadAhead];
    [audio enableStreamingReadAhead];
    unsigned char header[12];
    if([video readAtOffset:0 into:header count:12]!=12) {
        if(failure) *failure=[video errorText]; return nil;
    }
    if([audio readAtOffset:0 into:header count:12]!=12) {
        if(failure) *failure=[audio errorText]; return nil;
    }
    // Warm another 256 KiB of each independent stream. At YouTube's 144p
    // bitrates this is substantial playback headroom and removes a second
    // TLS/range stall immediately after the player opens.
    unsigned char warm;
    if(videoLength>262144 && [video readAtOffset:262144 into:&warm count:1]!=1) {
        if(failure) *failure=[video errorText]; return nil;
    }
    if(![[streams objectForKey:@"combined"] boolValue] && audioLength>262144 &&
       [audio readAtOffset:262144 into:&warm count:1]!=1) {
        if(failure) *failure=[audio errorText]; return nil;
    }
    [streams setObject:video forKey:@"videoSource"];
    [streams setObject:audio forKey:@"audioSource"];
    return streams;
}

static NSInteger YTSmallVideoOrder(id left,id right,void *context) {
    (void)context;
    return [[left objectForKey:@"rank"] compare:[right objectForKey:@"rank"]];
}
static NSInteger YTSoftwareFallbackOrder(id left,id right,void *context) {
    (void)context;
    NSInteger lh=[[left objectForKey:@"height"] integerValue],rh=[[right objectForKey:@"height"] integerValue];
    if(lh<=0) lh=[[left objectForKey:@"videoItag"] integerValue]==18 ? 360 : 144;
    if(rh<=0) rh=[[right objectForKey:@"videoItag"] integerValue]==18 ? 360 : 144;
    NSInteger lr=(lh>144 ? 10000 : 0)+lh*10+[[left objectForKey:@"fps"] integerValue];
    NSInteger rr=(rh>144 ? 10000 : 0)+rh*10+[[right objectForKey:@"fps"] integerValue];
    return lr<rr ? NSOrderedAscending : lr>rr ? NSOrderedDescending : NSOrderedSame;
}
static NSMutableDictionary *YTSmallVideoWithExistingAudio(NSDictionary *original,NSArray *responses,NSMutableArray *notes) {
    if(![original objectForKey:@"audioSource"]) return nil;
    NSMutableArray *candidates=[NSMutableArray array];
    for(NSDictionary *response in responses) {
        NSString *streaming=YTObjectForKey([response objectForKey:@"player"],@"streamingData");
        for(NSString *format in YTJSONObjectStringsInArray(streaming,@"adaptiveFormats")) {
            NSInteger rank=YTFormatRank(format,YES);
            if(rank<0 || !YTFormatURL(format)) continue;
            NSInteger width=YTJSONIntForKey(format,@"width"),height=YTJSONIntForKey(format,@"height");
            if(width>256 || height>144) continue;
            [candidates addObject:[NSDictionary dictionaryWithObjectsAndKeys:format,@"format",
                [response objectForKey:@"client"],@"client",[NSNumber numberWithInteger:rank],@"rank",nil]];
        }
    }
    NSMutableSet *attempted=[NSMutableSet set]; unsigned attempts=0;
    for(NSDictionary *candidate in [candidates sortedArrayUsingFunction:YTSmallVideoOrder context:NULL]) {
        NSString *format=[candidate objectForKey:@"format"];
        NSDictionary *client=[candidate objectForKey:@"client"];
        NSURL *url=YTFormatURL(format);
        if([attempted containsObject:url]) continue;
        [attempted addObject:url];
        if(++attempts>3) break;
        long long length=YTFormatLength(format);
        if(length<=0) length=YTRemoteLength(url,[client objectForKey:@"ua"]);
        if(length<=0) continue;
        YTMediaSource *source=[[[YTMediaSource alloc] initWithURL:url length:length userAgent:[client objectForKey:@"ua"]] autorelease];
        [source enableStreamingReadAhead];
        [source setRequestTimeout:3];
        uint8_t header[12];
        if([source readAtOffset:0 into:header count:sizeof(header)]!=sizeof(header)) {
            [notes addObject:[NSString stringWithFormat:@"%@: 144p itag %ld unreadable",[client objectForKey:@"label"],(long)YTJSONIntForKey(format,@"itag")]];
            continue;
        }
        [source setRequestTimeout:12];
        NSMutableDictionary *result=[[original mutableCopy] autorelease];
        [result setObject:url forKey:@"videoURL"]; [result setObject:source forKey:@"videoSource"];
        [result setObject:[NSNumber numberWithLongLong:[source length]] forKey:@"videoLength"];
        [result setObject:[NSNumber numberWithBool:NO] forKey:@"combined"];
        [result setObject:[NSNumber numberWithBool:NO] forKey:@"nativeCandidate"];
        [result removeObjectForKey:@"nativeInfo"];
        NSInteger itag=YTJSONIntForKey(format,@"itag"),fps=YTJSONIntForKey(format,@"fps");
        if(fps<=0) fps=itag==597 ? 15 : 30;
        NSInteger height=YTJSONIntForKey(format,@"height");
        [result setObject:[NSNumber numberWithInteger:height>0 ? height : 144] forKey:@"height"];
        [result setObject:[NSNumber numberWithInteger:fps] forKey:@"fps"];
        [result setObject:[NSNumber numberWithInteger:itag] forKey:@"videoItag"];
        [result setObject:[NSString stringWithFormat:@"%@ video + %@ AAC",[client objectForKey:@"label"],
            [original objectForKey:@"clientLabel"] ? [original objectForKey:@"clientLabel"] : @"existing"] forKey:@"clientLabel"];
        [notes addObject:@"Readable small video paired with the existing native AAC source"];
        return result;
    }
    return nil;
}

static NSDictionary *YTLowFPSWebClient(void) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
        @"Web low-FPS",@"label",@"WEB",@"name",@"2.20260708.00.00",@"version",@"1",@"number",
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",@"ua",
        @"",@"extra",[NSNumber numberWithDouble:3.0],@"timeout",nil];
}
static NSMutableDictionary *YTLowFPSStreamsForID(NSString *videoID) {
    NSDictionary *client=YTLowFPSWebClient();
    NSString *player=YTPlayerResponse(videoID,client,NULL);
    NSString *streaming=YTObjectForKey(player,@"streamingData");
    if(!streaming) return nil;
    NSArray *formats=YTJSONObjectStringsInArray(streaming,@"adaptiveFormats");

    /*
     * Software emergency path: choose by the ACTUAL dimensions/fps, not by an
     * assumed itag-to-codec mapping. YouTube's low-rate 144p AVC is commonly
     * Main profile (for example 597), which Apple hardware may reject but our
     * FFmpeg decoder can handle. At 256x144 it has only ~36% of the pixels of
     * 426x240, giving the ARM11 its first realistic chance to sustain 15 fps.
     */
    NSString *video=nil,*audio=nil;
    long long bestScore=LLONG_MAX;
    for(NSString *format in formats) {
        NSInteger itag=YTJSONIntForKey(format,@"itag");
        NSString *mime=YTJSONStringForKey(format,@"mimeType",0);
        NSInteger width=YTJSONIntForKey(format,@"width");
        NSInteger height=YTJSONIntForKey(format,@"height");
        NSInteger fps=YTJSONIntForKey(format,@"fps");

        if(fps<=0 && itag==597) fps=15;
        if((width<=0 || height<=0) && (itag==597 || itag==160)) {
            width=256; height=144;
        }

        BOOL tinyAVC=[mime rangeOfString:@"video/mp4" options:NSCaseInsensitiveSearch].location!=NSNotFound &&
                     [mime rangeOfString:@"avc1." options:NSCaseInsensitiveSearch].location!=NSNotFound &&
                     width>0 && height>0 && width<=256 && height<=144 &&
                     fps>0 && fps<=18 && YTFormatURL(format);
        if(tinyAVC) {
            long long length=YTFormatLength(format);
            // Prefer fewer pixels first, then lower fps, then smaller bytes.
            long long score=(long long)width*height*1000000LL + (long long)fps*10000LL +
                            (length>0 ? MIN(length/1024,9999) : 9999);
            if(score<bestScore) { video=format; bestScore=score; }
        }

        if(!audio && itag==140 &&
           [mime rangeOfString:@"mp4a.40.2" options:NSCaseInsensitiveSearch].location!=NSNotFound &&
           YTFormatURL(format)) audio=format;
    }

    if(!video || !audio) return nil;

    NSInteger chosenItag=YTJSONIntForKey(video,@"itag");
    NSInteger chosenFPS=YTJSONIntForKey(video,@"fps");
    NSInteger chosenHeight=YTJSONIntForKey(video,@"height");
    if(chosenFPS<=0 && chosenItag==597) chosenFPS=15;
    if(chosenHeight<=0 && (chosenItag==597 || chosenItag==160)) chosenHeight=144;

    long long videoLength=YTFormatLength(video),audioLength=YTFormatLength(audio);
    NSMutableDictionary *streams=[NSMutableDictionary dictionaryWithObjectsAndKeys:
        YTFormatURL(video),@"videoURL",YTFormatURL(audio),@"audioURL",
        [NSNumber numberWithLongLong:videoLength],@"videoLength",
        [NSNumber numberWithLongLong:audioLength],@"audioLength",
        [NSNumber numberWithBool:NO],@"combined",
        [NSNumber numberWithBool:NO],@"nativeCandidate",
        [NSNumber numberWithInteger:chosenHeight],@"height",
        [NSNumber numberWithInteger:chosenFPS],@"fps",
        [NSNumber numberWithInteger:chosenItag],@"videoItag",
        [client objectForKey:@"ua"],@"userAgent",
        @"Web tiny-AVC software fallback",@"clientLabel",
        @"1.2.3 forced <=144p <=18fps AVC software path",@"nativeSearch",nil];
    NSString *failure=nil;
    return YTPrepareStreams(streams,&failure);
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
    /*
     * 1.2.2 native-first order:
     *
     *   progressive combined movie (prefer itag 18) -> Apple player
     *   old combined 3GP if exposed                  -> Apple player
     *   compatible HLS                              -> Apple player
     *   144p/low-FPS adaptive                       -> software fallback
     *
     * The old order could return HLS or a CPU-decoded 144p stream before an
     * available progressive Baseline MP4 was ever tested. That hid the path
     * most likely to use the iPhone 2G's hardware H.264 decoder.
     */
    NSMutableArray *responses=[NSMutableArray array];
    NSMutableArray *streamNotes=[NSMutableArray array];

    // Obtain the correctly contextualized WEB_EMBEDDED/Safari player
    // responses without starting or buffering HLS.
    NSArray *webClients=YTPreparedWebClients(videoID);
    for(NSDictionary *client in webClients) {
        NSString *failure=nil;
        NSString *player=YTPlayerResponse(videoID,client,&failure);
        if(player)
            [responses addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                player,@"player",client,@"client",nil]];
        else
            [streamNotes addObject:[NSString stringWithFormat:@"%@: %@",
                [client objectForKey:@"label"],failure ? failure : @"No player response."]];
    }

    NSArray *clients=YTPlayerClients();
    NSMutableArray *errors=[NSMutableArray array];
    NSMutableArray *fallbacks=[NSMutableArray array];
    NSMutableArray *nativeNotes=[NSMutableArray array];

    // First inspect the already-fetched web/embedded responses. WEB_EMBEDDED is
    // especially useful because it can still expose progressive itag 18 even
    // when newer YouTube delivery paths are SABR-oriented.
    NSArray *webResponses=[NSArray arrayWithArray:responses];
    for(NSDictionary *response in webResponses) {
        NSDictionary *client=[response objectForKey:@"client"];
        NSString *player=[response objectForKey:@"player"];
        NSString *label=[client objectForKey:@"label"];
        NSString *failure=nil;

        NSMutableDictionary *normal=[[[self streamsFromPlayerResponse:player
            userAgent:[client objectForKey:@"ua"] error:&failure] mutableCopy] autorelease];
        if(normal) {
            [normal setObject:(label ? label : @"Web") forKey:@"clientLabel"];
            [fallbacks addObject:normal];
        }

        NSMutableDictionary *candidate=YTCombinedCandidateFromPlayer(player,[client objectForKey:@"ua"]);
        if(!candidate) {
            [nativeNotes addObject:[NSString stringWithFormat:@"%@: no progressive combined movie",
                label ? label : @"Web"]];
            continue;
        }
        [candidate setObject:(label ? label : @"Web") forKey:@"clientLabel"];

        NSString *candidateFailure=nil;
        if(!YTPrepareStreams(candidate,&candidateFailure)) {
            [nativeNotes addObject:[NSString stringWithFormat:@"%@: progressive movie unreadable (%@)",
                label ? label : @"Web",
                candidateFailure ? candidateFailure : @"unknown error"]];
            continue;
        }

        NSDictionary *info=YTNativeStreamInfo(candidate);
        if(info) [candidate setObject:info forKey:@"nativeInfo"];
        if(info && [[info objectForKey:@"height"] integerValue]>0)
            [candidate setObject:[info objectForKey:@"height"] forKey:@"height"];

        [nativeNotes addObject:[NSString stringWithFormat:@"%@: itag %@ p%@ L%@ %@x%@ %@",
            label ? label : @"Web",
            [candidate objectForKey:@"videoItag"] ? [candidate objectForKey:@"videoItag"] : @"?",
            info ? [info objectForKey:@"profile"] : @"?",
            info ? [info objectForKey:@"level"] : @"?",
            info ? [info objectForKey:@"width"] : @"?",
            info ? [info objectForKey:@"height"] : @"?",
            (info && [[info objectForKey:@"eligible"] boolValue]) ? @"NATIVE" : @"rejected"]];

        if(info && [[info objectForKey:@"eligible"] boolValue]) {
            [nativeNotes insertObject:@"1.2.3 progressive-first" atIndex:0];
            [candidate setObject:[nativeNotes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
            [[NSUserDefaults standardUserDefaults] setObject:(label ? label : @"Web")
                                                      forKey:@"YTWorkingClient"];
            return candidate;
        }

        if(normal && [[normal objectForKey:@"videoURL"] isEqual:[candidate objectForKey:@"videoURL"]])
            [fallbacks replaceObjectAtIndex:[fallbacks indexOfObjectIdenticalTo:normal]
                                  withObject:candidate];
        else
            [fallbacks addObject:candidate];
    }

    // Then try the established direct clients. A compatible progressive movie
    // still outranks HLS and every software-decoded fallback.
    for(NSDictionary *client in clients) {
        NSString *failure=nil;
        NSString *player=YTPlayerResponse(videoID,client,&failure);
        if(!player) {
            [errors addObject:[NSString stringWithFormat:@"%@: %@",
                [client objectForKey:@"label"],failure ? failure : @"No player response."]];
            continue;
        }
        [responses addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            player,@"player",client,@"client",nil]];

        NSMutableDictionary *normal=[[[self streamsFromPlayerResponse:player
            userAgent:[client objectForKey:@"ua"] error:&failure] mutableCopy] autorelease];
        if(normal) {
            [normal setObject:[client objectForKey:@"label"] forKey:@"clientLabel"];
            [fallbacks addObject:normal];
        } else if([failure length]) {
            [errors addObject:[NSString stringWithFormat:@"%@: %@",
                [client objectForKey:@"label"],failure]];
        }

        NSMutableDictionary *candidate=YTCombinedCandidateFromPlayer(player,[client objectForKey:@"ua"]);
        if(!candidate) {
            [nativeNotes addObject:[NSString stringWithFormat:@"%@: no progressive combined movie",
                [client objectForKey:@"label"]]];
            continue;
        }
        [candidate setObject:[client objectForKey:@"label"] forKey:@"clientLabel"];

        NSString *candidateFailure=nil;
        if(!YTPrepareStreams(candidate,&candidateFailure)) {
            [nativeNotes addObject:[NSString stringWithFormat:@"%@: progressive unavailable",
                [client objectForKey:@"label"]]];
            continue;
        }

        NSDictionary *info=YTNativeStreamInfo(candidate);
        if(info) [candidate setObject:info forKey:@"nativeInfo"];
        if(info && [[info objectForKey:@"height"] integerValue]>0)
            [candidate setObject:[info objectForKey:@"height"] forKey:@"height"];

        [nativeNotes addObject:[NSString stringWithFormat:@"%@: itag %@ p%@ L%@ %@x%@ %@",
            [client objectForKey:@"label"],
            [candidate objectForKey:@"videoItag"] ? [candidate objectForKey:@"videoItag"] : @"?",
            info ? [info objectForKey:@"profile"] : @"?",
            info ? [info objectForKey:@"level"] : @"?",
            info ? [info objectForKey:@"width"] : @"?",
            info ? [info objectForKey:@"height"] : @"?",
            (info && [[info objectForKey:@"eligible"] boolValue]) ? @"NATIVE" : @"rejected"]];

        if(info && [[info objectForKey:@"eligible"] boolValue]) {
            [nativeNotes insertObject:@"1.2.3 progressive-first" atIndex:0];
            [candidate setObject:[nativeNotes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
            [[NSUserDefaults standardUserDefaults] setObject:[client objectForKey:@"label"]
                                                      forKey:@"YTWorkingClient"];
            return candidate;
        }

        if(normal && [[normal objectForKey:@"videoURL"] isEqual:[candidate objectForKey:@"videoURL"]])
            [fallbacks replaceObjectAtIndex:[fallbacks indexOfObjectIdenticalTo:normal]
                                  withObject:candidate];
        else
            [fallbacks addObject:candidate];
    }

    /*
     * Direct YouTube did not expose a hardware-safe progressive movie.
     * Ask the already-existing remote backend to prepare one. This is the
     * decisive 1.2.4 path: server transcode, Apple player decode.
     */
    NSString *serverFailure=nil;
    NSMutableDictionary *serverNative=YTServerPreparedNativeForID(videoID,&serverFailure);
    if(serverNative) {
        NSMutableArray *notes=[NSMutableArray arrayWithObject:
            @"1.2.4 direct native unavailable; server-prepared native MP4"];
        [notes addObjectsFromArray:nativeNotes];
        [serverNative setObject:[notes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
        return serverNative;
    }
    if([serverFailure length])
        [streamNotes addObject:[NSString stringWithFormat:@"Server native: %@",serverFailure]];

    // The remote native path was unavailable. Only now spend time probing HLS.
    NSDictionary *hlsCandidate=YTHLSStreamsFromResponses(webResponses,streamNotes);
    if(hlsCandidate &&
       [[[hlsCandidate objectForKey:@"nativeInfo"] objectForKey:@"eligible"] boolValue]) {
        NSMutableDictionary *nativeHLS=[[hlsCandidate mutableCopy] autorelease];
        NSMutableArray *notes=[NSMutableArray arrayWithObject:@"1.2.3 progressive unavailable; Apple hardware HLS fallback"];
        [notes addObjectsFromArray:nativeNotes];
        [nativeHLS setObject:[notes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
        return nativeHLS;
    }

    /*
     * A non-native HLS rendition still costs ARM11 decode time. Do NOT return
     * it before the tiny direct 144p/<=18fps AVC path. The last build could
     * therefore strand us at ~240p/15fps source and ~5-6 decoded fps.
     */
    NSMutableDictionary *lowFPS=YTLowFPSStreamsForID(videoID);
    if(lowFPS) {
        NSMutableArray *notes=[NSMutableArray arrayWithObject:@"1.2.3 native unavailable; forced tiny direct software path"];
        [notes addObjectsFromArray:nativeNotes];
        [lowFPS setObject:[notes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
        return lowFPS;
    }

    // Only if the direct tiny stream does not exist do we permit software HLS.
    if(hlsCandidate) {
        NSMutableDictionary *ready=[[hlsCandidate mutableCopy] autorelease];
        [ready removeObjectForKey:@"nativeHLS"];
        [ready setObject:[NSNumber numberWithBool:YES] forKey:@"softwareHLS"];
        [ready setObject:[NSNumber numberWithBool:YES] forKey:@"hlsAudio"];
        NSMutableArray *notes=[NSMutableArray arrayWithObject:@"1.2.3 tiny direct unavailable; software HLS last resort"];
        [notes addObjectsFromArray:nativeNotes];
        [ready setObject:[notes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
        return ready;
    }

    // Preserve the established software fallback, preferring the smallest
    // readable H.264 representation and retaining the already-working audio.
    for(NSMutableDictionary *fallback in [fallbacks sortedArrayUsingFunction:YTSoftwareFallbackOrder context:NULL]) {
        NSString *failure=nil;
        if(YTPrepareStreams(fallback,&failure)) {
            BOOL large=[[fallback objectForKey:@"height"] integerValue]>144 ||
                ([[fallback objectForKey:@"combined"] boolValue] &&
                 [[fallback objectForKey:@"videoItag"] integerValue]==18);
            if(large) {
                NSMutableDictionary *small=YTSmallVideoWithExistingAudio(fallback,responses,streamNotes);
                if(small) fallback=small;
                else [streamNotes addObject:@"No readable small video; using the 360p CPU fallback"];
            }
            NSMutableArray *allNotes=[NSMutableArray arrayWithArray:streamNotes];
            [allNotes addObjectsFromArray:nativeNotes];
            if([allNotes count])
                [fallback setObject:[allNotes componentsJoinedByString:@" | "] forKey:@"nativeSearch"];
            [[NSUserDefaults standardUserDefaults] setObject:[fallback objectForKey:@"clientLabel"]
                                                      forKey:@"YTWorkingClient"];
            return fallback;
        }
        [errors addObject:[NSString stringWithFormat:@"%@: %@",
            [fallback objectForKey:@"clientLabel"],
            failure ? failure : @"Media URL failed."]];
    }

    if(errorText) {
        *errorText=[errors count] ? [errors componentsJoinedByString:@"\n\n"] :
            @"YouTube responded, but none of the tested clients exposed a playable direct stream.";
    }
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
