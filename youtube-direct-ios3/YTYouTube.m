#import "YTYouTube.h"
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


static NSString *YTPlayerPOST(NSString *videoID,
                              NSString *clientName,
                              NSString *clientVersion,
                              NSString *clientNumber,
                              NSString *userAgent,
                              BOOL embedded,
                              NSString **errorText) {
    NSString *thirdParty = embedded
        ? @",\"thirdParty\":{\"embedUrl\":\"https://www.youtube.com/\"}"
        : @"";
    NSString *body = [NSString stringWithFormat:
        @"{\"context\":{\"client\":{\"clientName\":\"%@\","
        @"\"clientVersion\":\"%@\",\"userAgent\":\"%@\","
        @"\"hl\":\"en\",\"gl\":\"US\"}%@},"
        @"\"videoId\":\"%@\",\"contentCheckOk\":true,\"racyCheckOk\":true}",
        clientName, clientVersion, userAgent, thirdParty, videoID];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:clientNumber forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [req setValue:clientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    NSURLResponse *response = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:&response
                                                     error:&err];
    NSInteger status = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]])
        status = [(NSHTTPURLResponse *)response statusCode];

    if (!data || status < 200 || status >= 300) {
        if (errorText) {
            if (err) *errorText = [err localizedDescription];
            else *errorText = [NSString stringWithFormat:@"%@ player HTTP %d",
                               clientName, (int)status];
        }
        return nil;
    }

    NSString *json = [[[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding] autorelease];
    if (!json && errorText)
        *errorText = [NSString stringWithFormat:@"%@ player response was not UTF-8.",
                      clientName];
    return json;
}

static NSString *YTEmbeddedPlayerResponse(NSString *videoID, NSString **errorText) {
    return YTPlayerPOST(videoID,
        @"WEB_EMBEDDED_PLAYER",
        @"2.20260708.00.00",
        @"56",
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15",
        YES, errorText);
}

static NSString *YTTVPlayerResponse(NSString *videoID, NSString **errorText) {
    return YTPlayerPOST(videoID,
        @"TVHTML5",
        @"7.20260707.07.00",
        @"7",
        @"Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
        NO, errorText);
}

static NSURL *YTItag18FromPlayerResponse(NSString *player, NSString **detail);

static BOOL YTProbeVideoURL(NSURL *url, NSString **errorText) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:18.0];
    [req setHTTPMethod:@"GET"];
    [req setValue:@"bytes=0-1" forHTTPHeaderField:@"Range"];
    [req setValue:@"Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_1_3 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16"
forHTTPHeaderField:@"User-Agent"];

    NSURLResponse *response = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:&response
                                                     error:&err];
    NSInteger status = 0;
    NSString *type = nil;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        status = [http statusCode];
        type = [[http allHeaderFields] objectForKey:@"Content-Type"];
        if (!type) type = [response MIMEType];
    }

    if (data && (status == 200 || status == 206)) {
        if (!type || [type rangeOfString:@"video/" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [type rangeOfString:@"application/octet-stream" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    }

    if (errorText) {
        if (err) *errorText = [err localizedDescription];
        else *errorText = [NSString stringWithFormat:@"media HTTP %d%@%@",
                           (int)status, type ? @" (" : @"",
                           type ? type : @""];
        if (type) *errorText = [*errorText stringByAppendingString:@")"];
    }
    return NO;
}

static NSURL *YTUsableItag18(NSString *player, NSString **errorText) {
    NSString *detail = nil;
    NSURL *url = YTItag18FromPlayerResponse(player, &detail);
    if (!url) {
        if (errorText) *errorText = detail;
        return nil;
    }

    NSString *probeError = nil;
    if (YTProbeVideoURL(url, &probeError))
        return url;

    if (errorText) {
        *errorText = [NSString stringWithFormat:@"format 18 URL rejected: %@",
                      probeError ? probeError : @"unknown media error"];
    }
    return nil;
}


static NSString *YTAndroidPlayerResponse(NSString *videoID, NSString **errorText) {
    NSString *clientVersion = @"21.26.364";
    NSString *userAgent =
        @"com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip";

    NSString *body = [NSString stringWithFormat:
        @"{\"context\":{\"client\":{\"clientName\":\"ANDROID\","
        @"\"clientVersion\":\"%@\",\"androidSdkVersion\":30,"
        @"\"userAgent\":\"%@\",\"osName\":\"Android\",\"osVersion\":\"11\","
        @"\"hl\":\"en\",\"gl\":\"US\"}},"
        @"\"videoId\":\"%@\",\"contentCheckOk\":true,\"racyCheckOk\":true}",
        clientVersion, userAgent, videoID];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"3" forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [req setValue:clientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];

    NSURLResponse *response = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:&response
                                                     error:&err];
    NSInteger status = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]])
        status = [(NSHTTPURLResponse *)response statusCode];

    if (!data || status < 200 || status >= 300) {
        if (errorText) {
            if (err) *errorText = [err localizedDescription];
            else *errorText = [NSString stringWithFormat:@"Android player HTTP %d", (int)status];
        }
        return nil;
    }

    NSString *json = [[[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding] autorelease];
    if (!json && errorText) *errorText = @"Android player response was not UTF-8.";
    return json;
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


@interface YTFileDownloader : NSObject {
    NSFileHandle *_handle;
    NSError *_error;
    BOOL _done;
    NSInteger _status;
    long long _received;
}
- (BOOL)downloadURL:(NSURL *)url toPath:(NSString *)path error:(NSString **)errorText;
@end

@implementation YTFileDownloader

- (id)init {
    self = [super init];
    if (self) {
        _handle = nil;
        _error = nil;
        _done = NO;
        _status = 0;
        _received = 0;
    }
    return self;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]])
        _status = [(NSHTTPURLResponse *)response statusCode];
    else
        _status = 200;

    if (_status != 200 && _status != 206) {
        _done = YES;
        [connection cancel];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (_done || ![data length]) return;
    [_handle writeData:data];
    _received += [data length];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [_error release];
    _error = [error retain];
    _done = YES;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    _done = YES;
}

- (BOOL)downloadURL:(NSURL *)url toPath:(NSString *)path error:(NSString **)errorText {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    if (![[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]) {
        if (errorText) *errorText = @"Could not create temporary movie file.";
        return NO;
    }

    _handle = [[NSFileHandle fileHandleForWritingAtPath:path] retain];
    if (!_handle) {
        if (errorText) *errorText = @"Could not open temporary movie file.";
        return NO;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:60.0];
    [req setHTTPMethod:@"GET"];
    [req setValue:@"Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_1_3 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16"
forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"video/mp4,*/*;q=0.8" forHTTPHeaderField:@"Accept"];

    _done = NO;
    _status = 0;
    _received = 0;

    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:req
                                                                  delegate:self
                                                          startImmediately:NO];
    [connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [connection start];

    while (!_done) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        [pool release];
    }

    [connection cancel];
    [connection release];
    [_handle synchronizeFile];
    [_handle closeFile];
    [_handle release];
    _handle = nil;

    if (_error) {
        if (errorText) *errorText = [_error localizedDescription];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return NO;
    }

    if (_status != 200 && _status != 206) {
        if (errorText)
            *errorText = [NSString stringWithFormat:@"movie download HTTP %d", (int)_status];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return NO;
    }

    if (_received < 1024) {
        if (errorText)
            *errorText = [NSString stringWithFormat:@"movie download was only %lld bytes", _received];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return NO;
    }

    return YES;
}

- (void)dealloc {
    [_handle closeFile];
    [_handle release];
    [_error release];
    [super dealloc];
}

@end

static NSURL *YTDownloadVideoLocally(NSURL *remoteURL, NSString *videoID, NSString **errorText) {
    NSString *safeID = videoID ? videoID : @"video";
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"ytdirect-%@.mp4", safeID]];

    YTFileDownloader *downloader = [[YTFileDownloader alloc] init];
    BOOL ok = [downloader downloadURL:remoteURL toPath:path error:errorText];
    [downloader release];
    if (!ok) return nil;

    return [NSURL fileURLWithPath:path];
}


static NSString *YTFFmpegPath(void) {
    NSArray *paths = [NSArray arrayWithObjects:
        @"/usr/libexec/ytdirect-ffmpeg",
        nil];
    NSUInteger i;
    for (i = 0; i < [paths count]; i++) {
        NSString *path = [paths objectAtIndex:i];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path])
            return path;
    }
    return nil;
}

static NSURL *YTConvertForOriginalIPhone(NSURL *downloadedURL,
                                          NSString *videoID,
                                          NSString **errorText) {
    NSString *ffmpeg = YTFFmpegPath();
    if (!ffmpeg) {
        if (errorText) {
            *errorText = @"The bundled YT Direct converter is missing. Reinstall YT Direct 0.4.1 or newer.";
        }
        return nil;
    }

    NSString *inputPath = [downloadedURL path];
    NSString *safeID = videoID ? videoID : @"video";
    NSString *outputPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"ytdirect-legacy-%@.mp4", safeID]];
    NSString *logPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"ytdirect-ffmpeg.log"];

    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

    // Original iPhone-safe target:
    // MPEG-4 Part 2 Simple Profile video, no B-frames, 320x180, 24 fps,
    // ~500 kbps. Keep YouTube's AAC-LC audio without re-encoding.
    NSString *command = [NSString stringWithFormat:
        @"'%@' -y -i '%@' -vcodec mpeg4 -profile:v 0 -b:v 500k -r 24 -s 320x180 -pix_fmt yuv420p -bf 0 -acodec copy -movflags +faststart '%@' >'%@' 2>&1",
        ffmpeg, inputPath, outputPath, logPath];

    int status = system([command UTF8String]);

    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:outputPath error:nil];
    unsigned long long size = attrs ? [[attrs objectForKey:NSFileSize] unsignedLongLongValue] : 0;

    if (status != 0 || size < 1024) {
        NSString *log = [NSString stringWithContentsOfFile:logPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if ([log length] > 700)
            log = [log substringFromIndex:[log length] - 700];
        if (errorText) {
            *errorText = [NSString stringWithFormat:
                @"On-device FFmpeg conversion failed (status %d). %@",
                status, [log length] ? log : @"No FFmpeg log was produced."];
        }
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        return nil;
    }

    // Remove the incompatible YouTube source after conversion to save space.
    [[NSFileManager defaultManager] removeItemAtPath:inputPath error:nil];
    return [NSURL fileURLWithPath:outputPath];
}

static NSURL *YTDownloadAndConvertForOriginalIPhone(NSURL *remoteURL,
                                                     NSString *videoID,
                                                     NSString **errorText) {
    NSURL *downloaded = YTDownloadVideoLocally(remoteURL, videoID, errorText);
    if (!downloaded) return nil;
    return YTConvertForOriginalIPhone(downloaded, videoID, errorText);
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
    NSMutableArray *errors = [NSMutableArray array];
    NSString *err = nil;
    NSURL *stream = nil;

    // First choice: WEB_EMBEDDED_PLAYER. Current yt-dlp policy does not require
    // a GVS PO token for this client. It only works when the video is embeddable.
    NSString *embedded = YTEmbeddedPlayerResponse(videoID, &err);
    if (embedded) {
        stream = YTUsableItag18(embedded, &err);
        if (stream) {
        NSString *downloadError = nil;
        NSURL *local = YTDownloadAndConvertForOriginalIPhone(stream, videoID, &downloadError);
        if (local) return local;
        err = [NSString stringWithFormat:@"resolved MP4 but download/conversion failed: %@",
               downloadError ? downloadError : @"unknown download error"];
    }
    }
    if (err) [errors addObject:[NSString stringWithFormat:@"Embedded: %@", err]];

    // Second no-PO-token family: TVHTML5. It may not expose progressive format
    // 18 for every video, but when it does we verify the CDN URL before playback.
    err = nil;
    NSString *tv = YTTVPlayerResponse(videoID, &err);
    if (tv) {
        stream = YTUsableItag18(tv, &err);
        if (stream) {
        NSString *downloadError = nil;
        NSURL *local = YTDownloadAndConvertForOriginalIPhone(stream, videoID, &downloadError);
        if (local) return local;
        err = [NSString stringWithFormat:@"resolved MP4 but download/conversion failed: %@",
               downloadError ? downloadError : @"unknown download error"];
    }
    }
    if (err) [errors addObject:[NSString stringWithFormat:@"TV: %@", err]];

    // Android can still expose format 18, but GVS enforcement may make the URL
    // return 403. Keep it only as a verified fallback.
    err = nil;
    NSString *android = YTAndroidPlayerResponse(videoID, &err);
    if (android) {
        stream = YTUsableItag18(android, &err);
        if (stream) {
        NSString *downloadError = nil;
        NSURL *local = YTDownloadAndConvertForOriginalIPhone(stream, videoID, &downloadError);
        if (local) return local;
        err = [NSString stringWithFormat:@"resolved MP4 but download/conversion failed: %@",
               downloadError ? downloadError : @"unknown download error"];
    }
    }
    if (err) [errors addObject:[NSString stringWithFormat:@"Android: %@", err]];

    // Last attempt: the player response embedded directly in YouTube's own page.
    err = nil;
    NSArray *pages = [NSArray arrayWithObjects:
        [NSString stringWithFormat:
            @"https://www.youtube.com/embed/%@?hl=en&gl=US", videoID],
        [NSString stringWithFormat:
            @"https://www.youtube.com/watch?v=%@&bpctr=9999999999&has_verified=1&hl=en&gl=US",
            videoID],
        nil];

    NSUInteger i;
    for (i = 0; i < [pages count]; i++) {
        NSString *html = YTHTML([pages objectAtIndex:i], &err);
        if (!html) continue;
        NSString *player = YTPlayerResponseFromHTML(html);
        if (!player) {
            err = @"page contained no embedded player response";
            continue;
        }
        stream = YTUsableItag18(player, &err);
        if (stream) {
        NSString *downloadError = nil;
        NSURL *local = YTDownloadAndConvertForOriginalIPhone(stream, videoID, &downloadError);
        if (local) return local;
        err = [NSString stringWithFormat:@"resolved MP4 but download/conversion failed: %@",
               downloadError ? downloadError : @"unknown download error"];
    }
    }
    if (err) [errors addObject:[NSString stringWithFormat:@"HTML: %@", err]];

    if (errorText) {
        *errorText = [NSString stringWithFormat:@"No playable format 18. %@",
                      [errors componentsJoinedByString:@" | "]];
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
