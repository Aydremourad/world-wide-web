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

static NSString *YTHTML(NSString *url, NSString **errorText) {
    NSData *data = YTGET(url, errorText);
    if (!data) return nil;
    NSString *html = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!html && errorText) *errorText = @"YouTube returned a page that was not UTF-8.";
    return html;
}

static NSString *YTPlayerResponseFromHTML(NSString *html) {
    NSArray *markers = [NSArray arrayWithObjects:
        @"ytInitialPlayerResponse", @"\"PLAYER_VARS\"", nil];

    NSUInteger m;
    for (m = 0; m < [markers count]; m++) {
        NSString *marker = [markers objectAtIndex:m];
        NSRange r = [html rangeOfString:marker];
        if (r.location == NSNotFound) continue;

        NSUInteger i = r.location + r.length;
        NSUInteger max = MIN([html length], i + 500);
        while (i < max && [html characterAtIndex:i] != '{') i++;
        if (i < max) {
            NSString *obj = YTBalancedObject(html, i);
            if (obj && [obj rangeOfString:@"\"streamingData\""].location != NSNotFound)
                return obj;
        }
    }
    return nil;
}

static NSURL *YTItag18FromPlayerResponse(NSString *player, NSString **detail) {
    NSArray *formats = YTJSONObjectStringsInArray(player, @"formats");
    NSUInteger i;
    for (i = 0; i < [formats count]; i++) {
        NSString *obj = [formats objectAtIndex:i];
        if (YTJSONIntForKey(obj, @"itag") != 18) continue;

        NSString *mime = YTJSONStringForKey(obj, @"mimeType", 0);
        if (mime && [mime rangeOfString:@"video/mp4"].location == NSNotFound) continue;

        NSString *url = YTJSONStringForKey(obj, @"url", 0);
        if (url && [url hasPrefix:@"https://"])
            return [NSURL URLWithString:url];

        NSString *cipher = YTJSONStringForKey(obj, @"signatureCipher", 0);
        if (!cipher) cipher = YTJSONStringForKey(obj, @"cipher", 0);
        if (cipher && detail) *detail = @"YouTube returned format 18, but ciphered its URL.";
        else if (detail) *detail = @"Format 18 was present without a usable URL.";
        return nil;
    }

    if (detail) {
        NSString *reason = YTJSONStringForKey(player, @"reason", 0);
        if (reason) *detail = reason;
        else *detail = @"YouTube page did not expose progressive format 18.";
    }
    return nil;
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

+ (NSURL *)directVideoURLForID:(NSString *)videoID error:(NSString **)errorText {
    NSString *requestError = nil;
    NSString *detail = nil;

    NSArray *pages = [NSArray arrayWithObjects:
        [NSString stringWithFormat:
            @"https://www.youtube.com/watch?v=%@&bpctr=9999999999&has_verified=1&hl=en&gl=US",
            videoID],
        [NSString stringWithFormat:
            @"https://www.youtube.com/embed/%@?hl=en&gl=US", videoID],
        nil];

    NSUInteger i;
    for (i = 0; i < [pages count]; i++) {
        NSString *html = YTHTML([pages objectAtIndex:i], &requestError);
        if (!html) continue;

        NSString *player = YTPlayerResponseFromHTML(html);
        if (!player) {
            detail = @"YouTube HTML loaded without an embedded player response.";
            continue;
        }

        NSURL *stream = YTItag18FromPlayerResponse(player, &detail);
        if (stream) return stream;
    }

    if (errorText) {
        if (detail) *errorText = detail;
        else if (requestError) *errorText = requestError;
        else *errorText = @"Could not resolve a direct YouTube format 18 stream.";
    }
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
