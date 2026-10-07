#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdarg.h>

static NSString *TRBEndpoint = nil;
static NSString *TRBEndpointHost = nil;
static BOOL TRBInsideURLBuild = NO;
static BOOL TRBCollectVideoIDs = NO;
static NSMutableArray *TRBVideoIDs = nil;
static NSString *TRBPreparingVideoID = nil;
static NSMutableSet *TRBPreparedVideoIDs = nil;
static UITableView *TRBPendingTableView = nil;
static NSIndexPath *TRBPendingIndexPath = nil;
static BOOL TRBPendingAnimated = NO;
static UITableViewScrollPosition TRBPendingScrollPosition = UITableViewScrollPositionNone;
static BOOL TRBPendingNotifyDelegate = NO;
static NSString *TRBPendingVideoID = nil;
static IMP TRBOriginalPrivateSelectIMP = NULL;

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

static BOOL TRBIsOurEndpointURL(NSURL *url) {
    if (!url || ![TRBEndpointHost length]) return NO;
    NSString *host = [[url host] lowercaseString];
    return [host isEqualToString:[TRBEndpointHost lowercaseString]];
}

static NSString *TRBLocalVideoIDFromURL(NSURL *url) {
    if (!TRBIsOurEndpointURL(url)) return nil;
    NSString *path = [url path];
    NSString *prefix = @"/getvideo/";
    if (![path hasPrefix:prefix]) return nil;

    NSString *videoID = [path substringFromIndex:[prefix length]];
    NSRange slash = [videoID rangeOfString:@"/"];
    if (slash.location != NSNotFound) {
        videoID = [videoID substringToIndex:slash.location];
    }
    return [videoID length] ? videoID : nil;
}

static void TRBResetVideoMap(NSString *reason) {
    [TRBVideoIDs removeAllObjects];
    TRBCollectVideoIDs = YES;
    TRBLog(@"VIDEO MAP RESET %@", reason);
}

static void TRBRememberVideoURL(NSURL *url) {
    if (!TRBCollectVideoIDs) return;

    NSString *videoID = TRBLocalVideoIDFromURL(url);
    if (![videoID length]) return;
    if ([TRBVideoIDs containsObject:videoID]) return;

    [TRBVideoIDs addObject:videoID];
    TRBLog(@"VIDEO MAP [%lu] %@", (unsigned long)([TRBVideoIDs count] - 1), videoID);
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
    NSURL *url = [[[NSURL alloc] initWithString:string] autorelease];
    TRBInsideURLBuild = old;
    return url;
}

static NSURL *TRBURLWithStringRelativeNoRewrite(NSString *string, NSURL *baseURL) {
    BOOL old = TRBInsideURLBuild;
    TRBInsideURLBuild = YES;
    NSURL *url = [[[NSURL alloc] initWithString:string relativeToURL:baseURL] autorelease];
    TRBInsideURLBuild = old;
    return url;
}

static NSURL *TRBRewriteURL(NSURL *url, NSString *source) {
    if (!url || ![TRBEndpoint length]) return url;

    TRBRememberVideoURL(url);

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

    NSURL *url = TRBURLWithStringNoRewrite(string);
    NSURL *rewritten = TRBRewriteURL(url, source);
    if (rewritten != url) return [rewritten absoluteString];
    return string;
}


static NSURLRequest *TRBRewriteRequest(NSURLRequest *request, NSString *source) {
    if (!request) return request;

    NSURL *oldURL = [request URL];

    if (TRBIsOurEndpointURL(oldURL)) {
        NSString *path = [oldURL path];
        NSString *query = [oldURL query];

        if (([path hasPrefix:@"/feeds/api/videos"] &&
             [query rangeOfString:@"q="].location != NSNotFound) ||
            [path hasPrefix:@"/feeds/api/standardfeeds/"]) {
            TRBResetVideoMap([oldURL absoluteString]);
        }
    }
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

+ (id)URLWithString:(NSString *)URLString relativeToURL:(NSURL *)baseURL {
    if (TRBInsideURLBuild) return %orig(URLString, baseURL);

    NSURL *combined = TRBURLWithStringRelativeNoRewrite(URLString, baseURL);
    NSURL *rewritten = TRBRewriteURL(combined, @"+URLWithString:relativeToURL:");

    if (rewritten != combined &&
        ![[rewritten absoluteString] isEqualToString:[combined absoluteString]]) {
        return %orig([rewritten absoluteString], nil);
    }

    return %orig(URLString, baseURL);
}

- (id)initWithString:(NSString *)URLString relativeToURL:(NSURL *)baseURL {
    if (TRBInsideURLBuild) return %orig(URLString, baseURL);

    NSURL *combined = TRBURLWithStringRelativeNoRewrite(URLString, baseURL);
    NSURL *rewritten = TRBRewriteURL(combined, @"-initWithString:relativeToURL:");

    if (rewritten != combined &&
        ![[rewritten absoluteString] isEqualToString:[combined absoluteString]]) {
        return %orig([rewritten absoluteString], nil);
    }

    return %orig(URLString, baseURL);
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

static NSURL *TRBRewritePreparedMovieURL(NSURL *url) {
    NSString *videoID = TRBLocalVideoIDFromURL(url);
    if (![videoID length] || ![TRBPreparedVideoIDs containsObject:videoID]) {
        return url;
    }

    NSString *targetString = [NSString stringWithFormat:@"http://%@/static/%@.mp4",
                              TRBEndpointHost, videoID];
    NSURL *target = TRBURLWithStringNoRewrite(targetString);
    if (target) {
        TRBLog(@"PLAYER READY REWRITE %@ -> %@", [url absoluteString], targetString);
        return target;
    }

    return url;
}

%hook MPMoviePlayerController

- (id)initWithContentURL:(NSURL *)URL {
    NSURL *rewritten = TRBRewriteURL(URL, @"MPMoviePlayerController initWithContentURL:");
    rewritten = TRBRewritePreparedMovieURL(rewritten);
    TRBLog(@"PLAYER init %@", [rewritten absoluteString]);
    return %orig(rewritten);
}

- (void)setContentURL:(NSURL *)URL {
    NSURL *rewritten = TRBRewriteURL(URL, @"MPMoviePlayerController setContentURL:");
    rewritten = TRBRewritePreparedMovieURL(rewritten);
    TRBLog(@"PLAYER set %@", [rewritten absoluteString]);
    %orig(rewritten);
}

%end

typedef void (*TRBPrivateSelectIMP)(id, SEL, NSIndexPath *, BOOL, UITableViewScrollPosition, BOOL);

static void TRBClearPendingSelection(void) {
    [TRBPendingTableView release];
    TRBPendingTableView = nil;

    [TRBPendingIndexPath release];
    TRBPendingIndexPath = nil;

    [TRBPendingVideoID release];
    TRBPendingVideoID = nil;

    TRBPendingAnimated = NO;
    TRBPendingScrollPosition = UITableViewScrollPositionNone;
    TRBPendingNotifyDelegate = NO;

    [TRBPreparingVideoID release];
    TRBPreparingVideoID = nil;
}

@interface TRBPrepareWorker : NSObject
+ (void)prepareVideo:(NSString *)videoID;
+ (void)resumeAppleSelection:(NSString *)videoID;
+ (void)prepareFailed:(NSString *)videoID;
@end

@implementation TRBPrepareWorker

+ (void)resumeAppleSelection:(NSString *)videoID {
    TRBLog(@"PREPARE READY %@", videoID);

    if (![videoID length] ||
        !TRBPendingVideoID ||
        ![TRBPendingVideoID isEqualToString:videoID] ||
        !TRBPendingTableView ||
        !TRBPendingIndexPath ||
        !TRBOriginalPrivateSelectIMP) {
        TRBLog(@"PREPARE READY but no matching pending Apple selection");
        TRBClearPendingSelection();
        return;
    }

    [TRBPreparedVideoIDs addObject:videoID];

    UITableView *tableView = [TRBPendingTableView retain];
    NSIndexPath *indexPath = [TRBPendingIndexPath retain];
    BOOL animated = TRBPendingAnimated;
    UITableViewScrollPosition scrollPosition = TRBPendingScrollPosition;
    BOOL notifyDelegate = TRBPendingNotifyDelegate;

    TRBClearPendingSelection();

    TRBLog(@"RESUME APPLE SELECT index=%@ video=%@", indexPath, videoID);
    ((TRBPrivateSelectIMP)TRBOriginalPrivateSelectIMP)(
        tableView,
        NSSelectorFromString(@"_selectRowAtIndexPath:animated:scrollPosition:notifyDelegate:"),
        indexPath,
        animated,
        scrollPosition,
        notifyDelegate
    );

    [indexPath release];
    [tableView release];
}

+ (void)prepareFailed:(NSString *)videoID {
    TRBLog(@"PREPARE FAILED %@", videoID);

    if (TRBPendingTableView && TRBPendingIndexPath) {
        [TRBPendingTableView deselectRowAtIndexPath:TRBPendingIndexPath animated:YES];
    }

    TRBClearPendingSelection();
}

+ (void)prepareVideo:(NSString *)videoID {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    TRBLog(@"PREPARE THREAD START %@", videoID);

    BOOL ready = NO;
    for (NSInteger attempt = 0; attempt < 180; attempt++) {
        NSString *urlString = [NSString stringWithFormat:
            @"http://%@/prepare/%@?attempt=%ld",
            TRBEndpointHost,
            videoID,
            (long)attempt
        ];

        NSURL *url = TRBURLWithStringNoRewrite(urlString);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
            timeoutInterval:10.0];

        NSURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request
                                             returningResponse:&response
                                                         error:&error];

        NSInteger status = 0;
        if ([response respondsToSelector:@selector(statusCode)]) {
            status = [(NSHTTPURLResponse *)response statusCode];
        }

        NSString *body = data
            ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]
            : nil;

        TRBLog(@"PREPARE POLL %ld status=%ld body=%@ error=%@",
               (long)attempt, (long)status, body, error);

        if (status == 200 && [body rangeOfString:@"\"ready\""].location != NSNotFound) {
            ready = YES;
            break;
        }

        if (status >= 400 || (body && [body rangeOfString:@"\"error\""].location != NSNotFound)) {
            TRBLog(@"PREPARE SERVER ERROR status=%ld body=%@", (long)status, body);
            break;
        }

        [NSThread sleepForTimeInterval:1.0];
    }

    if (ready) {
        [self performSelectorOnMainThread:@selector(resumeAppleSelection:)
                               withObject:videoID
                            waitUntilDone:NO];
    } else {
        [self performSelectorOnMainThread:@selector(prepareFailed:)
                               withObject:videoID
                            waitUntilDone:NO];
    }

    [pool drain];
}

@end

static void TRBPrepareMappedVideo(NSString *videoID,
                                  UITableView *tableView,
                                  NSIndexPath *indexPath,
                                  BOOL animated,
                                  UITableViewScrollPosition scrollPosition,
                                  BOOL notifyDelegate) {
    if (![videoID length] || !tableView || !indexPath) return;

    if ([TRBPreparedVideoIDs containsObject:videoID]) {
        TRBLog(@"ALREADY PREPARED %@", videoID);
        ((TRBPrivateSelectIMP)TRBOriginalPrivateSelectIMP)(
            tableView,
            NSSelectorFromString(@"_selectRowAtIndexPath:animated:scrollPosition:notifyDelegate:"),
            indexPath,
            animated,
            scrollPosition,
            notifyDelegate
        );
        return;
    }

    if (TRBPreparingVideoID && [TRBPreparingVideoID isEqualToString:videoID]) {
        TRBLog(@"PREPARE ALREADY RUNNING %@", videoID);
        return;
    }

    TRBClearPendingSelection();

    TRBPreparingVideoID = [videoID copy];
    TRBPendingVideoID = [videoID copy];
    TRBPendingTableView = [tableView retain];
    TRBPendingIndexPath = [indexPath retain];
    TRBPendingAnimated = animated;
    TRBPendingScrollPosition = scrollPosition;
    TRBPendingNotifyDelegate = notifyDelegate;

    TRBLog(@"PREPARE BEGIN %@ (Apple UI held, not replaced)", videoID);

    [NSThread detachNewThreadSelector:@selector(prepareVideo:)
                             toTarget:[TRBPrepareWorker class]
                           withObject:[[videoID copy] autorelease]];
}

static NSString *TRBVideoIDForTableIndexPath(UITableView *tableView, NSIndexPath *indexPath) {
    if (!tableView || !indexPath) return nil;

    NSInteger section = [indexPath section];
    NSInteger row = [indexPath row];
    NSInteger count = (NSInteger)[TRBVideoIDs count];
    if (count <= 0 || section != 0) return nil;

    NSInteger rows = [tableView numberOfRowsInSection:section];
    NSInteger offset = (rows == count + 1) ? 1 : 0;
    NSInteger mappedIndex = row - offset;

    TRBLog(@"MAP CHECK table=%@ section=%ld row=%ld rows=%ld mapped=%ld offset=%ld",
           NSStringFromClass([tableView class]),
           (long)section,
           (long)row,
           (long)rows,
           (long)count,
           (long)offset);

    if ((rows == count || rows == count + 1) &&
        mappedIndex >= 0 && mappedIndex < count) {
        return [TRBVideoIDs objectAtIndex:mappedIndex];
    }

    return nil;
}

static void TRBPrivateSelectReplacement(id self,
                                        SEL cmd,
                                        NSIndexPath *indexPath,
                                        BOOL animated,
                                        UITableViewScrollPosition scrollPosition,
                                        BOOL notifyDelegate) {
    UITableView *tableView = (UITableView *)self;
    NSString *videoID = TRBVideoIDForTableIndexPath(tableView, indexPath);

    TRBLog(@"PRIVATE SELECT table=%@ index=%@ notify=%d video=%@",
           NSStringFromClass([tableView class]),
           indexPath,
           notifyDelegate ? 1 : 0,
           videoID);

    if ([videoID length] && notifyDelegate) {
        TRBPrepareMappedVideo(videoID, tableView, indexPath,
                              animated, scrollPosition, notifyDelegate);
        return;
    }

    if (TRBOriginalPrivateSelectIMP) {
        ((TRBPrivateSelectIMP)TRBOriginalPrivateSelectIMP)(
            self, cmd, indexPath, animated, scrollPosition, notifyDelegate
        );
    }
}

static void TRBInstallPrivateTableHooks(void) {
    Class cls = [UITableView class];
    SEL selectSel = NSSelectorFromString(@"_selectRowAtIndexPath:animated:scrollPosition:notifyDelegate:");
    Method selectMethod = class_getInstanceMethod(cls, selectSel);

    if (selectMethod) {
        TRBOriginalPrivateSelectIMP = method_getImplementation(selectMethod);
        method_setImplementation(selectMethod, (IMP)TRBPrivateSelectReplacement);
        TRBLog(@"HOOKED STOCK-UI GATE %@", NSStringFromSelector(selectSel));
    } else {
        TRBLog(@"STOCK-UI SELECTOR MISSING %@", NSStringFromSelector(selectSel));
    }
}

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TRBEndpoint = [TRBLoadEndpoint() copy];
    NSURL *endpointURL = TRBURLWithStringNoRewrite(TRBEndpoint);
    TRBEndpointHost = [[[endpointURL host] lowercaseString] copy];

    TRBVideoIDs = [[NSMutableArray alloc] init];
    TRBPreparedVideoIDs = [[NSMutableSet alloc] init];

    FILE *fp = fopen("/tmp/TubeRepairIOS3Bridge.log", "w");
    if (fp) fclose(fp);

    TRBLog(@"TubeRepairIOS3Bridge 1.4.0 loaded endpoint=%@ host=%@", TRBEndpoint, TRBEndpointHost);
    TRBInstallPrivateTableHooks();
    [pool drain];
}
