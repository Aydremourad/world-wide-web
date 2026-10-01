#import "YTYouTube.h"

static NSString * const YTAPIKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

static NSString *YTJSONEscape(NSString *value) {
    NSMutableString *out = [NSMutableString string];
    NSUInteger i, n = [value length];
    for (i = 0; i < n; i++) {
        unichar c = [value characterAtIndex:i];
        switch (c) {
            case '\\': [out appendString:@"\\\\"]; break;
            case '"': [out appendString:@"\\\""]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (c < 0x20) [out appendFormat:@"\\u%04x", c];
                else [out appendFormat:@"%C", c];
        }
    }
    return out;
}

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
    NSString *needle = [NSString stringWithFormat:@"\"%@\":\"", key];
    if (start >= [text length]) return nil;
    NSRange search = NSMakeRange(start, [text length] - start);
    NSRange r = [text rangeOfString:needle options:0 range:search];
    if (r.location == NSNotFound) {
        needle = [NSString stringWithFormat:@"\"%@\" : \"", key];
        r = [text rangeOfString:needle options:0 range:search];
        if (r.location == NSNotFound) return nil;
    }

    NSUInteger i = r.location + r.length;
    NSMutableString *raw = [NSMutableString string];
    BOOL escaped = NO;
    while (i < [text length]) {
        unichar c = [text characterAtIndex:i++];
        if (!escaped && c == '"') break;
        [raw appendFormat:@"%C", c];
        if (escaped) escaped = NO;
        else if (c == '\\') escaped = YES;
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

@implementation YTYouTube

+ (NSData *)postBody:(NSString *)body
            endpoint:(NSString *)endpoint
          clientName:(NSString *)clientName
       clientVersion:(NSString *)clientVersion
        clientNumber:(NSString *)clientNumber
           userAgent:(NSString *)userAgent
               error:(NSString **)errorText {
    NSArray *urls = [NSArray arrayWithObjects:
        [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?key=%@&prettyPrint=false", endpoint, YTAPIKey],
        [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint],
        nil];

    NSString *lastError = nil;
    NSUInteger u;
    for (u = 0; u < [urls count]; u++) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[urls objectAtIndex:u]]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:25.0];
        [req setHTTPMethod:@"POST"];
        [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:clientNumber forHTTPHeaderField:@"X-YouTube-Client-Name"];
        [req setValue:clientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
        [req setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
        if (userAgent) [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];

        NSURLResponse *response = nil;
        NSError *err = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&response error:&err];
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]])
            status = [(NSHTTPURLResponse *)response statusCode];

        if (data && status >= 200 && status < 300) return data;
        if (err) lastError = [err localizedDescription];
        else lastError = [NSString stringWithFormat:@"YouTube HTTP %d", (int)status];
    }

    if (errorText) *errorText = lastError ? lastError : @"No response from YouTube.";
    return nil;
}

+ (NSArray *)search:(NSString *)query error:(NSString **)errorText {
    NSString *version = @"2.20260708.00.00";
    NSString *body = [NSString stringWithFormat:
        @"{\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"%@\",\"hl\":\"en\",\"gl\":\"US\"}},\"query\":\"%@\"}",
        version, YTJSONEscape(query)];

    NSData *data = [self postBody:body endpoint:@"search" clientName:@"WEB"
                      clientVersion:version clientNumber:@"1"
                          userAgent:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36"
                              error:errorText];
    if (!data) return nil;

    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!text) {
        if (errorText) *errorText = @"YouTube returned unreadable search data.";
        return nil;
    }

    NSMutableArray *results = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *marker = @"\"videoRenderer\":";
    NSUInteger pos = 0;

    while (pos < [text length] && [results count] < 20) {
        NSRange r = [text rangeOfString:marker options:0 range:NSMakeRange(pos, [text length] - pos)];
        if (r.location == NSNotFound) break;
        NSUInteger brace = r.location + r.length;
        while (brace < [text length] && [text characterAtIndex:brace] != '{') brace++;
        NSString *obj = YTBalancedObject(text, brace);
        if (!obj) {
            pos = r.location + r.length;
            continue;
        }

        NSString *videoID = YTJSONStringForKey(obj, @"videoId", 0);
        NSString *title = nil;
        NSString *author = nil;

        NSRange titleRange = [obj rangeOfString:@"\"title\":"];
        if (titleRange.location != NSNotFound)
            title = YTJSONStringForKey(obj, @"text", titleRange.location);

        NSRange ownerRange = [obj rangeOfString:@"\"ownerText\":"];
        if (ownerRange.location != NSNotFound)
            author = YTJSONStringForKey(obj, @"text", ownerRange.location);

        if (videoID && [videoID length] == 11 && ![seen containsObject:videoID]) {
            if (!title) title = videoID;
            if (!author) author = @"YouTube";
            [results addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                videoID, @"id", title, @"title", author, @"author", nil]];
            [seen addObject:videoID];
        }
        pos = brace + [obj length];
    }

    return results;
}

+ (NSURL *)directVideoURLForID:(NSString *)videoID error:(NSString **)errorText {
    NSArray *clients = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"WEB", @"name", @"2.20260708.00.00", @"version", @"1", @"number",
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36", @"ua", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"MWEB", @"name", @"2.20260708.05.00", @"version", @"2", @"number",
            @"Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 Version/16.6 Mobile/15E148 Safari/604.1", @"ua", nil],
        nil];

    NSString *lastError = nil;
    NSUInteger i;
    for (i = 0; i < [clients count]; i++) {
        NSDictionary *client = [clients objectAtIndex:i];
        NSString *name = [client objectForKey:@"name"];
        NSString *version = [client objectForKey:@"version"];
        NSString *body = [NSString stringWithFormat:
            @"{\"context\":{\"client\":{\"clientName\":\"%@\",\"clientVersion\":\"%@\",\"hl\":\"en\",\"gl\":\"US\"}},\"videoId\":\"%@\",\"contentCheckOk\":true,\"racyCheckOk\":true,\"playbackContext\":{\"contentPlaybackContext\":{\"html5Preference\":\"HTML5_PREF_WANTS\"}}}",
            name, version, YTJSONEscape(videoID)];

        NSData *data = [self postBody:body endpoint:@"player" clientName:name
                          clientVersion:version clientNumber:[client objectForKey:@"number"]
                              userAgent:[client objectForKey:@"ua"] error:&lastError];
        if (!data) continue;

        NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!text) continue;

        NSArray *markers = [NSArray arrayWithObjects:@"\"itag\":18", @"\"itag\": 18", nil];
        NSUInteger m;
        for (m = 0; m < [markers count]; m++) {
            NSRange itag = [text rangeOfString:[markers objectAtIndex:m]];
            if (itag.location == NSNotFound) continue;

            NSRange remain = NSMakeRange(itag.location, [text length] - itag.location);
            NSRange urlKey = [text rangeOfString:@"\"url\":\"" options:0 range:remain];
            if (urlKey.location == NSNotFound || urlKey.location - itag.location > 12000) continue;

            NSUInteger valueStart = urlKey.location + urlKey.length;
            NSMutableString *raw = [NSMutableString string];
            BOOL escaped = NO;
            NSUInteger p;
            for (p = valueStart; p < [text length]; p++) {
                unichar c = [text characterAtIndex:p];
                if (!escaped && c == '"') break;
                [raw appendFormat:@"%C", c];
                if (escaped) escaped = NO;
                else if (c == '\\') escaped = YES;
            }
            NSString *decoded = YTJSONUnescape(raw);
            if ([decoded hasPrefix:@"https://"]) {
                NSURL *url = [NSURL URLWithString:decoded];
                if (url) return url;
            }
        }

        NSString *reason = YTJSONStringForKey(text, @"reason", 0);
        if (reason) lastError = reason;
        else lastError = [NSString stringWithFormat:@"%@ did not return direct format 18.", name];
    }

    if (errorText) *errorText = lastError ? lastError : @"No direct iPhone-compatible stream is available.";
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
