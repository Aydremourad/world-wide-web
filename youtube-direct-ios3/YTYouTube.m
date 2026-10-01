#import "YTYouTube.h"

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
    if (start >= [text length]) return nil;
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange search = NSMakeRange(start, [text length] - start);
    NSRange r = [text rangeOfString:needle options:0 range:search];
    if (r.location == NSNotFound) return nil;

    NSUInteger i = r.location + r.length;
    while (i < [text length] && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
           characterIsMember:[text characterAtIndex:i]]) i++;
    if (i >= [text length] || [text characterAtIndex:i] != ':') return nil;
    i++;
    while (i < [text length] && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
           characterIsMember:[text characterAtIndex:i]]) i++;
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

static NSString *YTBalancedObject(NSString *text, NSUInteger openIndex) {
    if (openIndex >= [text length] || [text characterAtIndex:openIndex] != '{') return nil;
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
            if (depth == 0) return [text substringWithRange:NSMakeRange(openIndex, i - openIndex + 1)];
        }
    }
    return nil;
}


static NSData *YTGET(NSString *urlString, NSString **errorText) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:18.0];
    [req setHTTPMethod:@"GET"];
    [req setValue:@"Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_1_3 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16" forHTTPHeaderField:@"User-Agent"];\n    [req setValue:@"application/json,text/plain,*/*" forHTTPHeaderField:@"Accept"];
    NSURLResponse *response = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&response error:&err];
    NSInteger status = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]])
        status = [(NSHTTPURLResponse *)response statusCode];
    if (data && status >= 200 && status < 300) return data;
    if (errorText) {
        if (err) *errorText = [err localizedDescription];
        else *errorText = [NSString stringWithFormat:@"HTTP %d", (int)status];
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
        if (ch == '"') {
            inString = YES;
            i++;
            continue;
        }
        if (ch == '[') {
            arrayDepth++;
            i++;
            continue;
        }
        if (ch == ']') {
            arrayDepth--;
            i++;
            continue;
        }
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

static BOOL YTJSONBoolForKey(NSString *obj, NSString *key, BOOL fallback) {
    NSString *trueNeedle = [NSString stringWithFormat:@"\"%@\":true", key];
    NSString *falseNeedle = [NSString stringWithFormat:@"\"%@\":false", key];
    NSString *trueSpaced = [NSString stringWithFormat:@"\"%@\": true", key];
    NSString *falseSpaced = [NSString stringWithFormat:@"\"%@\": false", key];
    if ([obj rangeOfString:trueNeedle].location != NSNotFound ||
        [obj rangeOfString:trueSpaced].location != NSNotFound) return YES;
    if ([obj rangeOfString:falseNeedle].location != NSNotFound ||
        [obj rangeOfString:falseSpaced].location != NSNotFound) return NO;
    return fallback;
}

static NSArray *YTTopLevelObjects(NSString *text) {
    NSMutableArray *objects = [NSMutableArray array];
    NSUInteger i = 0;
    NSInteger arrayDepth = 0;
    BOOL inString = NO, escaped = NO;
    while (i < [text length]) {
        unichar ch = [text characterAtIndex:i];
        if (inString) {
            if (escaped) escaped = NO;
            else if (ch == '\\') escaped = YES;
            else if (ch == '"') inString = NO;
            i++;
            continue;
        }
        if (ch == '"') {
            inString = YES;
            i++;
            continue;
        }
        if (ch == '[') {
            arrayDepth++;
            i++;
            continue;
        }
        if (ch == ']') {
            arrayDepth--;
            i++;
            continue;
        }
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

static NSURL *YTPipedCombinedURL(NSString *text) {
    NSArray *objects = YTJSONObjectStringsInArray(text, @"videoStreams");
    NSString *bestURL = nil;
    NSInteger bestHeight = 0;
    NSUInteger i;
    for (i = 0; i < [objects count]; i++) {
        NSString *obj = [objects objectAtIndex:i];
        if (YTJSONBoolForKey(obj, @"videoOnly", YES)) continue;
        NSString *mime = YTJSONStringForKey(obj, @"mimeType", 0);
        NSString *format = YTJSONStringForKey(obj, @"format", 0);
        NSString *codec = YTJSONStringForKey(obj, @"codec", 0);
        if (mime && [mime rangeOfString:@"video/mp4"].location == NSNotFound) continue;
        if (format && ![format isEqualToString:@"MPEG_4"]) continue;
        if (codec && [codec rangeOfString:@"avc1"].location == NSNotFound) continue;
        NSString *url = YTJSONStringForKey(obj, @"url", 0);
        if (!url || ![url hasPrefix:@"https://"]) continue;

        NSInteger height = 360;
        NSString *quality = YTJSONStringForKey(obj, @"quality", 0);
        if (quality && [quality hasSuffix:@"p"])
            height = [[quality substringToIndex:[quality length] - 1] integerValue];

        if (height <= 360) {
            if (!bestURL || height > bestHeight) {
                bestURL = url;
                bestHeight = height;
            }
            if (height == 360) return [NSURL URLWithString:url];
        }
    }
    return bestURL ? [NSURL URLWithString:bestURL] : nil;
}

static NSURL *YTInvidiousFormatURL(NSString *text) {
    NSArray *objects = YTJSONObjectStringsInArray(text, @"formatStreams");
    NSString *fallbackURL = nil;
    NSUInteger i;
    for (i = 0; i < [objects count]; i++) {
        NSString *obj = [objects objectAtIndex:i];
        NSString *url = YTJSONStringForKey(obj, @"url", 0);
        if (!url || ![url hasPrefix:@"https://"]) continue;
        NSString *itag = YTJSONStringForKey(obj, @"itag", 0);
        NSString *container = YTJSONStringForKey(obj, @"container", 0);
        NSString *encoding = YTJSONStringForKey(obj, @"encoding", 0);
        NSString *quality = YTJSONStringForKey(obj, @"qualityLabel", 0);
        if (container && ![container isEqualToString:@"mp4"]) continue;
        if (encoding && [encoding rangeOfString:@"h264" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [encoding rangeOfString:@"avc" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        if ([itag isEqualToString:@"18"]) return [NSURL URLWithString:url];
        if (!fallbackURL && (!quality || [quality hasPrefix:@"360"]))
            fallbackURL = url;
    }
    return fallbackURL ? [NSURL URLWithString:fallbackURL] : nil;
}


@implementation YTYouTube

+ (NSArray *)search:(NSString *)query error:(NSString **)errorText {
    NSString *escaped = [query stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *errors = [NSMutableString string];

    // Primary search path: Piped. The public API documents /search as an
    // unauthenticated endpoint and filter=videos returns StreamItem objects.
    NSArray *piped = [NSArray arrayWithObjects:
        @"https://pipedapi.kavin.rocks",
        @"https://pipedapi.leptons.xyz",
        @"https://pipedapi.nosebs.ru",
        nil];

    NSUInteger h;
    for (h = 0; h < [piped count]; h++) {
        NSString *host = [piped objectAtIndex:h];
        NSString *url = [NSString stringWithFormat:@"%@/search?q=%@&filter=videos",
                          host, escaped];
        NSString *requestError = nil;
        NSData *data = YTGET(url, &requestError);
        if (!data) {
            [errors appendFormat:@"%@=%@; ", host,
             requestError ? requestError : @"no response"];
            continue;
        }

        NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!text || ![text length]) {
            [errors appendFormat:@"%@=empty; ", host];
            continue;
        }

        NSArray *objects = YTJSONObjectStringsInArray(text, @"items");
        NSMutableArray *results = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSUInteger i;
        for (i = 0; i < [objects count] && [results count] < 20; i++) {
            NSString *obj = [objects objectAtIndex:i];
            NSString *type = YTJSONStringForKey(obj, @"type", 0);
            if (type && ![type isEqualToString:@"stream"]) continue;

            NSString *relative = YTJSONStringForKey(obj, @"url", 0);
            if (!relative) continue;

            NSString *videoID = nil;
            NSRange vr = [relative rangeOfString:@"v="];
            if (vr.location != NSNotFound) {
                NSUInteger start = vr.location + vr.length;
                if (start + 11 <= [relative length])
                    videoID = [relative substringWithRange:NSMakeRange(start, 11)];
            }
            if (!videoID || [videoID length] != 11 || [seen containsObject:videoID])
                continue;

            NSString *title = YTJSONStringForKey(obj, @"title", 0);
            NSString *author = YTJSONStringForKey(obj, @"uploaderName", 0);
            if (!title) title = videoID;
            if (!author) author = @"YouTube";

            [results addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                videoID, @"id", title, @"title", author, @"author", nil]];
            [seen addObject:videoID];
        }

        if ([results count]) return results;
        [errors appendFormat:@"%@=no video results; ", host];
    }

    // Fallback only: some Invidious public instances block anonymous API
    // traffic with 403, so never make them the sole search path.
    NSArray *invidious = [NSArray arrayWithObjects:
        @"https://inv.nadeko.net",
        @"https://invidious.nerdvpn.de",
        @"https://yt.chocolatemoo53.com",
        @"https://invidious.tiekoetter.com",
        nil];

    for (h = 0; h < [invidious count]; h++) {
        NSString *host = [invidious objectAtIndex:h];
        NSString *url = [NSString stringWithFormat:
            @"%@/api/v1/search?q=%@&type=video&region=US&hl=en",
            host, escaped];
        NSString *requestError = nil;
        NSData *data = YTGET(url, &requestError);
        if (!data) {
            [errors appendFormat:@"%@=%@; ", host,
             requestError ? requestError : @"no response"];
            continue;
        }

        NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!text || ![text length]) continue;

        NSArray *objects = YTTopLevelObjects(text);
        NSMutableArray *results = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSUInteger i;
        for (i = 0; i < [objects count] && [results count] < 20; i++) {
            NSString *obj = [objects objectAtIndex:i];
            NSString *type = YTJSONStringForKey(obj, @"type", 0);
            if (type && ![type isEqualToString:@"video"]) continue;
            NSString *videoID = YTJSONStringForKey(obj, @"videoId", 0);
            if (!videoID || [videoID length] != 11 || [seen containsObject:videoID]) continue;
            NSString *title = YTJSONStringForKey(obj, @"title", 0);
            NSString *author = YTJSONStringForKey(obj, @"author", 0);
            if (!title) title = videoID;
            if (!author) author = @"YouTube";
            [results addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                videoID, @"id", title, @"title", author, @"author", nil]];
            [seen addObject:videoID];
        }
        if ([results count]) return results;
        [errors appendFormat:@"%@=no video results; ", host];
    }

    if (errorText) {
        *errorText = [NSString stringWithFormat:@"All public search resolvers failed: %@",
                      [errors length] ? errors : @"no response"];
    }
    return nil;
}

+ (NSURL *)directVideoURLForID:(NSString *)videoID error:(NSString **)errorText {
    NSString *escapedID = [videoID stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSString *lastError = nil;

    // Do NOT call YouTube's /youtubei/v1/player here. In late 2026 anonymous
    // WEB/MWEB player requests can return "The page needs to be reloaded."
    // Piped resolves the video on its own backend and gives us a progressive
    // combined MP4/proxy URL suitable for old single-stream clients.
    NSArray *piped = [NSArray arrayWithObjects:
        @"https://pipedapi.kavin.rocks",
        @"https://pipedapi.leptons.xyz",
        @"https://pipedapi.nosebs.ru",
        nil];

    NSUInteger i;
    for (i = 0; i < [piped count]; i++) {
        NSString *host = [piped objectAtIndex:i];
        NSString *url = [NSString stringWithFormat:@"%@/streams/%@", host, escapedID];
        NSData *data = YTGET(url, &lastError);
        if (!data) continue;
        NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!text) continue;
        NSURL *stream = YTPipedCombinedURL(text);
        if (stream) return stream;
        lastError = [NSString stringWithFormat:@"No combined MP4 from %@", host];
    }

    // Second independent resolver family. local=true asks Invidious to return
    // instance-proxied formatStreams instead of handing the phone a modern
    // YouTube player URL directly.
    NSArray *invidious = [NSArray arrayWithObjects:
        @"https://inv.nadeko.net",
        @"https://invidious.nerdvpn.de",
        @"https://yt.chocolatemoo53.com",
        @"https://invidious.tiekoetter.com",
        nil];

    for (i = 0; i < [invidious count]; i++) {
        NSString *host = [invidious objectAtIndex:i];
        NSString *url = [NSString stringWithFormat:@"%@/api/v1/videos/%@?local=true&region=US",
                          host, escapedID];
        NSData *data = YTGET(url, &lastError);
        if (!data) continue;
        NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!text || ![text length]) continue;
        NSURL *stream = YTInvidiousFormatURL(text);
        if (stream) return stream;
        lastError = [NSString stringWithFormat:@"No progressive MP4 from %@", host];
    }

    if (errorText) {
        *errorText = [NSString stringWithFormat:
            @"No old-iPhone stream resolver succeeded. Last error: %@",
            lastError ? lastError : @"no response"];
    }
    return nil;
}

+ (NSString *)videoIDFromText:(NSString *)text {
    if (!text) return nil;
    NSString *s = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s length] == 11) {
        NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet];
        if ([s rangeOfCharacterFromSet:bad].location == NSNotFound) return s;
    }

    NSArray *needles = [NSArray arrayWithObjects:@"v=", @"youtu.be/", @"/shorts/", @"/embed/", nil];
    NSUInteger i;
    for (i = 0; i < [needles count]; i++) {
        NSString *needle = [needles objectAtIndex:i];
        NSRange r = [s rangeOfString:needle];
        if (r.location == NSNotFound) continue;
        NSUInteger start = r.location + r.length;
        if (start + 11 <= [s length]) {
            NSString *candidate = [s substringWithRange:NSMakeRange(start, 11)];
            NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet];
            if ([candidate rangeOfCharacterFromSet:bad].location == NSNotFound) return candidate;
        }
    }
    return nil;
}

@end
