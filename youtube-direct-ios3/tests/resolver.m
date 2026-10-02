#import <Foundation/Foundation.h>
#import "YTYouTube.h"
#include <assert.h>

static NSString *Player(NSString *formats) {
    return [NSString stringWithFormat:@"{\"playabilityStatus\":{\"status\":\"OK\"},\"streamingData\":{\"adaptiveFormats\":[%@]}}", formats];
}
static NSDictionary *Resolve(NSString *formats) {
    NSString *failure = nil;
    NSDictionary *result = [YTYouTube streamsFromPlayerResponse:Player(formats) userAgent:@"fixture" error:&failure];
    if (!result) NSLog(@"Unexpected resolver rejection: %@", failure);
    assert(result);
    return result;
}
static NSString *Video = @"{\"itag\":160,\"mimeType\":\"video/mp4; codecs=\\\"avc1.4d400c\\\"\",\"width\":256,\"height\":144,\"fps\":30,\"url\":\"https://media.example/video?clen=70000\"}";
static NSString *HalfRateVideo = @"{\"itag\":597,\"mimeType\":\"video/mp4; codecs=\\\"avc1.4d400b\\\"\",\"width\":256,\"height\":144,\"fps\":15,\"url\":\"https://media.example/half?clen=35000\"}";
static NSString *Audio = @"{\"itag\":140,\"mimeType\":\"audio/mp4; codecs=\\\"mp4a.40.2\\\"\",\"url\":\"https://media.example/audio?clen=80000\"}";
static NSString *Combined = @"{\"itag\":18,\"mimeType\":\"video/mp4; codecs=\\\"avc1.4d401e, mp4a.40.2\\\"\",\"width\":640,\"height\":360,\"url\":\"https://media.example/combined\"}";

// Exercise production requests, header length recovery, CDN reads and fallback
// with NSURLProtocol. Fixtures never contact YouTube or another external host.
static BOOL BlockAndroid;
static BOOL CombinedOnly;
static BOOL LighterAvailable, LighterBroken;
static BOOL CompatReady;
static int AndroidRequests, VisionRequests, HeadRequests, VRRequests, AudioReads;
@interface YTFixtureProtocol : NSURLProtocol
@end
@implementation YTFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = [[request URL] host];
    return [host isEqualToString:@"www.youtube.com"] || [host isEqualToString:@"media.example"] ||
           [host isEqualToString:@"aydreyoutube2g.duckdns.org"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSURLRequest *request = [self request];
    NSURL *url = [request URL];
    NSData *data = nil;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSInteger status = 200;
    if ([[url host] isEqualToString:@"www.youtube.com"]) {
        NSString *clientName = [request valueForHTTPHeaderField:@"X-YouTube-Client-Name"];
        BOOL android = [clientName isEqualToString:@"3"];
        if (android) AndroidRequests++; else if ([clientName isEqualToString:@"101"]) VisionRequests++;
        if([clientName isEqualToString:@"28"]) VRRequests++;
        NSString *json = [clientName isEqualToString:@"28"] ? Player(LighterAvailable ? HalfRateVideo : [NSString stringWithFormat:@"%@,%@",Video,Audio]) : android && BlockAndroid ?
            @"{\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\",\"reason\":\"Fixture blocked Android\"}}" :
            CombinedOnly ? Player([NSString stringWithFormat:@"%@,%@,%@", Combined,
                @"{\"itag\":160,\"mimeType\":\"video/mp4; codecs=\\\"avc1.4d400c\\\"\"}",
                @"{\"itag\":140,\"mimeType\":\"audio/mp4; codecs=\\\"mp4a.40.2\\\"\"}"]) :
            Player([NSString stringWithFormat:@"%@,%@",
                @"{\"itag\":160,\"url\":\"https://media.example/video\"}",
                @"{\"itag\":140,\"url\":\"https://media.example/audio\"}"]);
        data = [json dataUsingEncoding:NSUTF8StringEncoding];
        [headers setObject:@"application/json" forKey:@"Content-Type"];
        [headers setObject:[NSString stringWithFormat:@"%lu", (unsigned long)[data length]] forKey:@"Content-Length"];
    } else if ([[url host] isEqualToString:@"aydreyoutube2g.duckdns.org"]) {
        if ([[url path] hasPrefix:@"/status/"]) {
            NSString *json=CompatReady ? @"{\"status\":\"ready\"}" : @"{\"status\":\"failed\"}";
            data=[json dataUsingEncoding:NSUTF8StringEncoding];
            [headers setObject:@"application/json" forKey:@"Content-Type"];
            [headers setObject:[NSString stringWithFormat:@"%lu",(unsigned long)[data length]] forKey:@"Content-Length"];
        } else {
            [headers setObject:@"video/mp4" forKey:@"Content-Type"];
            [headers setObject:@"120000" forKey:@"Content-Length"];
            [headers setObject:(CompatReady ? @"ready" : @"failed") forKey:@"X-YouTube2G-Status"];
            [headers setObject:(CompatReady ? @"1" : @"0") forKey:@"X-YouTube2G-Native"];
            data=[NSData data];
        }
    } else {
        long long length = [[url path] isEqualToString:@"/video"] ? 70000 : [[url path] isEqualToString:@"/half"] ? 35000 : 80000;
        [headers setObject:@"video/mp4" forKey:@"Content-Type"];
        if ([[request HTTPMethod] isEqualToString:@"HEAD"]) {
            HeadRequests++;
            [headers setObject:[NSString stringWithFormat:@"%lld", length] forKey:@"Content-Length"];
            data = [NSData data];
        } else {
            long long start = 0, end = 0;
            NSScanner *scan = [NSScanner scannerWithString:[request valueForHTTPHeaderField:@"Range"]];
            assert([scan scanString:@"bytes=" intoString:NULL] && [scan scanLongLong:&start] &&
                   [scan scanString:@"-" intoString:NULL] && [scan scanLongLong:&end]);
            assert(end - start + 1 <= 65536);
            status = 206;
            if([[url path] isEqualToString:@"/half"] && LighterBroken) status=403;
            if([[url path] isEqualToString:@"/audio"]) AudioReads++;
            data = [NSMutableData dataWithLength:(NSUInteger)(end - start + 1)];
            [headers setObject:[NSString stringWithFormat:@"%lld", end - start + 1] forKey:@"Content-Length"];
            [headers setObject:[NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, length] forKey:@"Content-Range"];
        }
    }
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:status
        HTTPVersion:@"HTTP/1.1" headerFields:headers] autorelease];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if ([data length]) [[self client] URLProtocol:self didLoadData:data];
    [[self client] URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *result = Resolve([NSString stringWithFormat:@"%@,%@", Video, Audio]);
    assert([[result objectForKey:@"videoLength"] longLongValue] == 70000);
    assert([[result objectForKey:@"audioLength"] longLongValue] == 80000);
    result = Resolve([NSString stringWithFormat:@"%@,{\"itag\":160},{\"itag\":140}", Combined]);
    assert([[result objectForKey:@"combined"] boolValue]);
    assert([[result objectForKey:@"videoURL"] isEqual:[result objectForKey:@"audioURL"]]);
    result = Resolve([NSString stringWithFormat:@"%@,%@,%@", Combined, Video, Audio]);
    assert(![[result objectForKey:@"combined"] boolValue]);
    result = Resolve([NSString stringWithFormat:@"%@,%@,%@", HalfRateVideo, Video, Audio]);
    assert([[[result objectForKey:@"videoURL"] path] isEqualToString:@"/half"]);
    assert([[result objectForKey:@"videoItag"] intValue]==597 && [[result objectForKey:@"fps"] intValue]==15);
    NSString *baseline=[Combined stringByReplacingOccurrencesOfString:@"avc1.4d401e" withString:@"avc1.42001e"];
    result=Resolve([NSString stringWithFormat:@"%@,%@,%@",baseline,Video,Audio]);
    assert([[result objectForKey:@"combined"] boolValue]); // Prefer native playback over software 144p.
    result = Resolve([NSString stringWithFormat:@"%@,%@",
        @"{\"itag\":160,\"url\":\"https://media.example/v\",\"contentLength\":4294967301}", Audio]);
    assert([[result objectForKey:@"videoLength"] longLongValue] == 4294967301LL);
    result = Resolve([NSString stringWithFormat:@"%@,%@",
        @"{\"itag\":160,\"url\":\"https://media.example/v\",\"contentLength\":\"90000\"}", Audio]);
    assert([[result objectForKey:@"videoLength"] longLongValue] == 90000);
    result = Resolve([NSString stringWithFormat:@"%@,%@,%@",
        @"{\"itag\":597,\"signatureCipher\":\"url=https%3A%2F%2Fmedia.example%2Fv&s=encrypted\"}", Video, Audio]);
    assert([[[result objectForKey:@"videoURL"] path] isEqualToString:@"/video"]);
    result = Resolve([NSString stringWithFormat:@"%@,%@",
        @"{\"itag\":160,\"cipher\":\"url=https%3A%2F%2Fmedia.example%2Fv%3Fclen%3D50000&sig=abc&sp=sig\"}", Audio]);
    assert([[result objectForKey:@"videoLength"] longLongValue] == 50000);
    assert([[[result objectForKey:@"videoURL"] absoluteString] rangeOfString:@"sig=abc"].location != NSNotFound);
    result = Resolve([NSString stringWithFormat:@"%@,%@,%@",
        @"{\"itag\":597,\"url\":\"https://media.example/no-length\"}", Video, Audio]);
    assert([[result objectForKey:@"videoLength"] longLongValue] == 70000);
    NSString *anotherBaseline=[baseline stringByReplacingOccurrencesOfString:@"\"itag\":18" withString:@"\"itag\":777"];
    result=Resolve([NSString stringWithFormat:@"%@,%@,%@,%@",Combined,anotherBaseline,Video,Audio]);
    assert([[result objectForKey:@"combined"] boolValue] && [[result objectForKey:@"videoURL"] isEqual:[result objectForKey:@"audioURL"]]);
    NSString *simple=@"{\"itag\":17,\"mimeType\":\"video/3gpp; codecs=\\\"mp4v.20.3, mp4a.40.2\\\"\",\"width\":176,\"height\":144,\"url\":\"https://media.example/simple?clen=12000\"}";
    result=Resolve([NSString stringWithFormat:@"%@,%@,%@,%@",Combined,simple,Video,Audio]);
    assert([[result objectForKey:@"combined"] boolValue] && [[result objectForKey:@"height"] intValue]==144);
    assert([[[result objectForKey:@"videoURL"] path] isEqualToString:@"/simple"]);
    NSString *error = nil;
    assert(![YTYouTube streamsFromPlayerResponse:Player([NSString stringWithFormat:@"%@,%@", Video,
        @"{\"itag\":139,\"mimeType\":\"audio/mp4; codecs=\\\"mp4a.40.5\\\"\",\"url\":\"https://media.example/HE\"}"])
        userAgent:@"fixture" error:&error]);
    assert([error rangeOfString:@"AAC-LC missing"].location != NSNotFound);
    error = nil;
    assert(![YTYouTube streamsFromPlayerResponse:@"{\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\",\"reason\":\"Actual block reason\"}}"
        userAgent:@"fixture" error:&error]);
    assert([error rangeOfString:@"Actual block reason"].location != NSNotFound);
    [NSURLProtocol registerClass:[YTFixtureProtocol class]];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"YTWorkingClient"];
    result = [YTYouTube playbackStreamsForID:@"jNQXAC9IVRw" error:&error];
    assert(result && HeadRequests == 2 && AndroidRequests == 1);
    assert([[result objectForKey:@"videoLength"] longLongValue] == 70000);
    assert([result objectForKey:@"videoSource"] && [result objectForKey:@"audioSource"]);
    assert(VRRequests==1 && [[[result objectForKey:@"videoURL"] path] isEqualToString:@"/video"]);
    LighterAvailable=YES; VRRequests=AudioReads=0;
    result=[YTYouTube playbackStreamsForID:@"jNQXAC9IVRw" error:&error];
    assert(result && VRRequests==1 && AudioReads==1);
    assert([[result objectForKey:@"fps"] intValue]==15 && [[result objectForKey:@"videoItag"] intValue]==597);
    assert([[[result objectForKey:@"videoURL"] path] isEqualToString:@"/half"]);
    assert([[[result objectForKey:@"audioURL"] path] isEqualToString:@"/audio"]);
    assert([[result objectForKey:@"audioLength"] longLongValue]==80000 && [result objectForKey:@"audioSource"]);
    LighterBroken=YES;
    result=[YTYouTube playbackStreamsForID:@"jNQXAC9IVRw" error:&error];
    assert(result && [[result objectForKey:@"fps"] intValue]==30);
    assert([[[result objectForKey:@"videoURL"] path] isEqualToString:@"/video"]);
    LighterAvailable=LighterBroken=NO;
    BlockAndroid = YES; AndroidRequests = VisionRequests = 0;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"YTWorkingClient"];
    result = [YTYouTube playbackStreamsForID:@"jNQXAC9IVRw" error:&error];
    assert(result && AndroidRequests == 1 && VisionRequests == 1);
    BlockAndroid = NO; CombinedOnly = YES; AndroidRequests = VisionRequests = HeadRequests = 0;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"YTWorkingClient"];
    result = [YTYouTube playbackStreamsForID:@"jNQXAC9IVRw" error:&error];
    assert(result && AndroidRequests == 1 && VisionRequests == 0 && HeadRequests == 1);
    assert([[result objectForKey:@"combined"] boolValue]);
    assert([[result objectForKey:@"videoLength"] longLongValue] == [[result objectForKey:@"audioLength"] longLongValue]);
    assert([result objectForKey:@"videoSource"] != [result objectForKey:@"audioSource"]);
    result=[YTYouTube lowResolutionStreamsForID:@"jNQXAC9IVRw"];
    assert(result && ![[result objectForKey:@"combined"] boolValue] && [[result objectForKey:@"videoLength"] longLongValue]==70000);
    CompatReady=YES;
    result=[YTYouTube compatibilityStreamsForID:@"jNQXAC9IVRw"];
    assert(result && [[result objectForKey:@"compatibilityServer"] boolValue]);
    assert([[result objectForKey:@"combined"] boolValue] && [[result objectForKey:@"height"] intValue]==240);
    assert([[[result objectForKey:@"nativeInfo"] objectForKey:@"eligible"] boolValue]);
    assert([[result objectForKey:@"videoLength"] longLongValue]==120000);
    CompatReady=NO;
    assert(![YTYouTube compatibilityStreamsForID:@"jNQXAC9IVRw"]);
    [NSURLProtocol unregisterClass:[YTFixtureProtocol class]];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"YTWorkingClient"];
    NSLog(@"Resolver checks passed, including lighter video across clients, unchanged working audio, unavailable lighter fallback, and native/progressive routing.");
    [pool release];
    return 0;
}
