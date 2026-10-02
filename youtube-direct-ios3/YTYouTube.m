#import "YTYouTube.h"
#import "YTMediaSource.h"
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

static NSData *YTGET(NSString *urlString, NSString **errorText) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:25.0];
    [req setHTTPMethod:@"GET"];
    // Ask YouTube for the normal desktop WEB page. The phone's real iOS 3 UA
    // would be served an unsupported-browser path.
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
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


static NSArray *YTPlayerClients(void) {
    return [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"Android", @"label", @"ANDROID", @"name", @"21.26.364", @"version", @"3", @"number",
            @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip", @"ua",
            @",\"androidSdkVersion\":30,\"osName\":\"Android\",\"osVersion\":\"11\"", @"extra", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"VisionOS", @"label", @"VISIONOS", @"name", @"1.02", @"version", @"101", @"number",
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", @"ua",
            @",\"deviceMake\":\"Apple\",\"deviceModel\":\"RealityDevice17,1\",\"osName\":\"visionOS\",\"osVersion\":\"26.5.23O471\"", @"extra", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"TV", @"label", @"TVHTML5", @"name", @"7.20260707.07.00", @"version", @"7", @"number",
            @"Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)", @"ua", @"", @"extra", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"TV old", @"label", @"TVHTML5", @"name", @"5.20260707", @"version", @"7", @"number",
            @"Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version", @"ua", @"", @"extra", nil], nil];
}

static NSString *YTPlayerResponse(NSString *videoID, NSDictionary *client, NSString **errorText) {
    NSString *body = [NSString stringWithFormat:
        @"{\"context\":{\"client\":{\"clientName\":\"%@\",\"clientVersion\":\"%@\","
        @"\"userAgent\":\"%@\",\"hl\":\"en\",\"gl\":\"US\"%@}},"
        @"\"videoId\":\"%@\",\"contentCheckOk\":true,\"racyCheckOk\":true}",
        [client objectForKey:@"name"], [client objectForKey:@"version"],
        [client objectForKey:@"ua"], [client objectForKey:@"extra"], videoID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
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
        return itag == 597 ? 0 : itag == 160 ? 1 : 2;
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
        if (rank >= 0 && YTFormatLength(format) <= 0) rank += 10;
        if (rank >= 0 && rank < bestRank && YTFormatURL(format)) { best = format; bestRank = rank; }
    }
    return best;
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
        NSString *access = YTFormatURL(format) ? @"URL" : @"ciphered";
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
    NSString *video = YTChooseFormat(formats, YES), *audio = YTChooseFormat(formats, NO);
    if (!video || !audio) {
        if (errorText) *errorText = [NSString stringWithFormat:@"%@ missing; %@",
            !video && !audio ? @"144p H.264 and AAC-LC" : !video ? @"144p H.264" : @"AAC-LC",
            YTPlayerDiagnostic(player, formats)];
        return nil;
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
        YTFormatURL(video), @"videoURL", YTFormatURL(audio), @"audioURL",
        [NSNumber numberWithLongLong:YTFormatLength(video)], @"videoLength",
        [NSNumber numberWithLongLong:YTFormatLength(audio)], @"audioLength",
        userAgent, @"userAgent", nil];
}

+ (NSDictionary *)playbackStreamsForID:(NSString *)videoID error:(NSString **)errorText {
    NSMutableArray *clients = [NSMutableArray arrayWithArray:YTPlayerClients()];
    NSString *preferred = [[NSUserDefaults standardUserDefaults] stringForKey:@"YTWorkingClient"];
    for (NSDictionary *client in [NSArray arrayWithArray:clients]) {
        if ([[client objectForKey:@"label"] isEqualToString:preferred]) {
            [clients removeObject:client]; [clients insertObject:client atIndex:0]; break;
        }
    }
    NSMutableArray *errors = [NSMutableArray array];
    for (NSDictionary *client in clients) {
        NSString *failure = nil;
        NSString *player = YTPlayerResponse(videoID, client, &failure);
        NSMutableDictionary *streams = player ? [[[self streamsFromPlayerResponse:player
            userAgent:[client objectForKey:@"ua"] error:&failure] mutableCopy] autorelease] : nil;
        if (streams) {
            long long videoLength = [[streams objectForKey:@"videoLength"] longLongValue];
            long long audioLength = [[streams objectForKey:@"audioLength"] longLongValue];
            if (videoLength <= 0) videoLength = YTRemoteLength([streams objectForKey:@"videoURL"], [client objectForKey:@"ua"]);
            if (audioLength <= 0) audioLength = YTRemoteLength([streams objectForKey:@"audioURL"], [client objectForKey:@"ua"]);
            [streams setObject:[NSNumber numberWithLongLong:videoLength] forKey:@"videoLength"];
            [streams setObject:[NSNumber numberWithLongLong:audioLength] forKey:@"audioLength"];
            if (videoLength <= 0 || audioLength <= 0) {
                failure = [NSString stringWithFormat:@"URLs found but byte lengths missing (video %lld, audio %lld).", videoLength, audioLength];
            } else {
                YTMediaSource *video = [[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"videoURL"]
                    length:videoLength userAgent:[client objectForKey:@"ua"]] autorelease];
                YTMediaSource *audio = [[[YTMediaSource alloc] initWithURL:[streams objectForKey:@"audioURL"]
                    length:audioLength userAgent:[client objectForKey:@"ua"]] autorelease];
                unsigned char header[12];
                if ([video readAtOffset:0 into:header count:12] != 12) failure = [video errorText];
                else if ([audio readAtOffset:0 into:header count:12] != 12) failure = [audio errorText];
                else {
                    [streams setObject:video forKey:@"videoSource"];
                    [streams setObject:audio forKey:@"audioSource"];
                    [[NSUserDefaults standardUserDefaults] setObject:[client objectForKey:@"label"] forKey:@"YTWorkingClient"];
                    return streams;
                }
            }
        }
        [errors addObject:[NSString stringWithFormat:@"%@: %@", [client objectForKey:@"label"], failure ? failure : @"No usable stream."]];
    }
    if (errorText) *errorText = [errors componentsJoinedByString:@"\n\n"];
    return nil;
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
