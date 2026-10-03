#import "YTViewController.h"
#import "YTYouTube.h"
#import "YTSoftwarePlayer.h"
#import "YTNativeProbe.h"
#import "YTPlaybackLog.h"

@implementation YTViewController

- (void)restoreApplicationChrome {
    [[UIApplication sharedApplication] setStatusBarHidden:_savedStatusHidden animated:NO];
    // Restore UIKit's known-good launch geometry in its original coordinate
    // system. applicationFrame adds another status-bar inset on iOS 3.
    UINavigationController *navigation=self.navigationController;
    navigation.view.frame=_savedNavigationFrame;
    [navigation.view setNeedsLayout];
    [navigation.view layoutIfNeeded];
    navigation.navigationBar.frame=_savedNavigationBarFrame;
    self.view.frame=_savedContentFrame;
}
- (void)finishPlayerChromeRestore {
    if(!_restoreChromeAfterPlayer) return;
    [self restoreApplicationChrome];
    _restoreChromeAfterPlayer=NO;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(_restoreChromeAfterPlayer) {
        [self restoreApplicationChrome];
        [self performSelector:@selector(finishPlayerChromeRestore) withObject:nil afterDelay:0.0];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"YouTube";
    UIButton *info=[UIButton buttonWithType:UIButtonTypeInfoDark];
    [info addTarget:self action:@selector(showBuildInfo) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem=[[[UIBarButtonItem alloc] initWithCustomView:info] autorelease];
    self.view.backgroundColor = [UIColor whiteColor];

    CGRect bounds = self.view.bounds;

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 44)];
    _searchBar.delegate = self;
    _searchBar.placeholder = @"Search or paste YouTube URL";
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_searchBar];

    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 44, bounds.size.width, bounds.size.height - 44)
                                             style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 56.0f;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 155, bounds.size.width - 40, 80)];
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.textColor = [UIColor darkGrayColor];
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.numberOfLines = 4;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    _statusLabel.hidden = YES;
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_statusLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spinner.center = CGPointMake(bounds.size.width / 2, 135);
    _spinner.hidesWhenStopped = YES;
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spinner];
}

- (void)showBuildInfo {
    NSString *version=[[NSBundle mainBundle] objectForInfoDictionaryKey:@"YTBuildLabel"];
    if(![version length]) version=[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    NSString *details=YTReadPlaybackLog();
    NSString *message=[NSString stringWithFormat:@"Version %@\n\n%@",version,details ? details : @"No video opened yet."];
    UIAlertView *alert=[[[UIAlertView alloc] initWithTitle:@"YouTube" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease];
    [alert show];
}

- (void)setBusy:(BOOL)busy text:(NSString *)text {
    [UIApplication sharedApplication].networkActivityIndicatorVisible = busy;
    if (busy) [_spinner startAnimating];
    else [_spinner stopAnimating];
    _statusLabel.hidden = ![text length];
    _statusLabel.text = text;
    _tableView.hidden = busy;
    _searchBar.userInteractionEnabled = !busy;
}

- (void)showError:(NSString *)message {
    [self setBusy:NO text:nil];
    _tableView.hidden = NO;
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"YouTube"
                                                    message:(message ? message : @"Unknown error")
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil] autorelease];
    [alert show];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *text = searchBar.text;
    if (![text length]) return;

    NSString *videoID = [YTYouTube videoIDFromText:text];
    if (videoID) {
        [self beginResolve:videoID];
        return;
    }

    [self setBusy:YES text:@"Searching YouTube..."];
    [NSThread detachNewThreadSelector:@selector(searchThread:) toTarget:self withObject:text];
}

- (void)searchThread:(NSString *)query {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *error = nil;
    NSArray *found = [YTYouTube search:query error:&error];
    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        (found ? found : [NSArray array]), @"results",
        (error ? error : @""), @"error", nil];
    [self performSelectorOnMainThread:@selector(searchFinished:) withObject:payload waitUntilDone:NO];
    [pool release];
}

- (void)searchFinished:(NSDictionary *)payload {
    NSString *error = [payload objectForKey:@"error"];
    if ([error length]) {
        [self showError:error];
        return;
    }

    [_results release];
    _results = [[payload objectForKey:@"results"] retain];
    [_tableView reloadData];
    _tableView.hidden = NO;
    _searchBar.userInteractionEnabled = YES;
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    [_spinner stopAnimating];
    _statusLabel.hidden = ([_results count] != 0);
    if (![_results count]) _statusLabel.text = @"No videos found.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_results count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellID = @"VideoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellID];
    if (!cell)
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellID] autorelease];

    NSDictionary *item = [_results objectAtIndex:indexPath.row];
    cell.textLabel.text = [item objectForKey:@"title"];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:14.0f];
    cell.detailTextLabel.text = [item objectForKey:@"author"];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0f];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = [_results objectAtIndex:indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self beginResolve:[item objectForKey:@"id"]];
}

- (void)beginResolve:(NSString *)videoID {
    [self setBusy:YES text:@"Getting the video stream..."];
    [NSThread detachNewThreadSelector:@selector(resolveThread:) toTarget:self withObject:videoID];
}

- (void)showLowResolutionStatus { _statusLabel.text=@"Getting a smaller video..."; }

- (void)resolveThread:(NSString *)videoID {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *error = nil;
    NSMutableDictionary *streams = [[[YTYouTube playbackStreamsForID:videoID error:&error] mutableCopy] autorelease];
    if (streams) {
        NSDictionary *info=YTNativeStreamInfo(streams);
        if(info) [streams setObject:info forKey:@"nativeInfo"];
        if([[streams objectForKey:@"combined"] boolValue] && ![[info objectForKey:@"eligible"] boolValue]) {
            // The actual movie is authoritative. Main profile 77 must not be
            // forced into Apple playback by a misleading Baseline MIME hint.
            NSString *nativeError=nil;
            NSDictionary *compatible=[YTYouTube nativeCompatibleStreamsForID:videoID
                excludingClient:[streams objectForKey:@"clientLabel"] error:&nativeError];
            if(compatible) streams=[[compatible mutableCopy] autorelease];
            else { streams=nil; error=nativeError; }
        }

    }
    if(streams) {
        [streams setObject:videoID forKey:@"videoID"];
        BOOL tryNative=YTShouldUseNativePlayer(streams);
        NSString *route=tryNative ? @"Apple player" : @"Software player";
        NSString *build=[[NSBundle mainBundle] objectForInfoDictionaryKey:@"YTBuildLabel"];
        if(![build length]) build=[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        NSString *diagnostic=[NSString stringWithFormat:@"Version %@\nPlayback: %@\nQuality: %@p\n",
            build,route,[streams objectForKey:@"height"]];
        YTWritePlaybackLog(diagnostic);
    } else {
        YTWritePlaybackLog([NSString stringWithFormat:@"Version %@\nPlayback source rejected\n%@\n",
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],error ? error : @"No usable stream"]);
    }
    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        (streams ? (id)streams : (id)[NSNull null]), @"streams",
        (error ? error : @""), @"error", nil];
    [self performSelectorOnMainThread:@selector(resolveFinished:) withObject:payload waitUntilDone:NO];
    [pool release];
}

- (void)resolveFinished:(NSDictionary *)payload {
    NSDictionary *streams = [payload objectForKey:@"streams"];
    if (![streams isKindOfClass:[NSDictionary class]]) {
        [self showError:[payload objectForKey:@"error"]];
        return;
    }
    [_spinner stopAnimating];
    _tableView.hidden = NO;
    _searchBar.userInteractionEnabled = YES;
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    _statusLabel.hidden = YES;
    BOOL tryNative=YTShouldUseNativePlayer(streams);
    if (tryNative) {
        _nativePlayer=[[YTNativePlayer alloc] initWithStreams:streams delegate:self];
        if([_nativePlayer play]) return;
        NSString *failure=[[_nativePlayer errorText] copy];
        [_nativePlayer stop]; [_nativePlayer release]; _nativePlayer=nil;
        [self showError:failure]; [failure release]; return;
    }
    [self playSoftwareStreams:streams];
}
- (void)playSoftwareStreams:(NSDictionary *)streams {
    YTSoftwarePlayer *player = [[YTSoftwarePlayer alloc] initWithStreams:streams];
    _savedStatusHidden=[UIApplication sharedApplication].statusBarHidden;
    _savedNavigationFrame=self.navigationController.view.frame;
    _savedNavigationBarFrame=self.navigationController.navigationBar.frame;
    _savedContentFrame=self.view.frame;
    _restoreChromeAfterPlayer=YES;
    [[UIApplication sharedApplication] setStatusBarHidden:YES animated:NO];
    player.wantsFullScreenLayout=YES;
    [self presentModalViewController:player animated:NO];
    [player release];
}
- (void)nativeFallbackThread:(NSDictionary *)payload {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    NSString *videoID=[payload objectForKey:@"videoID"];
    NSDictionary *lower=[YTYouTube lowResolutionStreamsForID:videoID];
    NSMutableDictionary *chosen=nil;
    if(lower) {
        chosen=[[lower mutableCopy] autorelease];
        [chosen setObject:videoID forKey:@"videoID"];
    } else chosen=[payload objectForKey:@"original"];
    [self performSelectorOnMainThread:@selector(nativeFallbackFinished:) withObject:chosen waitUntilDone:YES];
    [pool release];
}
- (void)nativeFallbackFinished:(NSDictionary *)streams {
    [self setBusy:NO text:nil];
    [self playSoftwareStreams:streams];
}

- (void)nativePlayer:(YTNativePlayer *)player finishedWithError:(BOOL)failed {
    NSString *failure=[[player errorText] copy];
    [_nativePlayer release]; _nativePlayer=nil;
    // Do not hide native startup failures behind another known-slow 360p
    // software attempt. Use the existing error alert; the existing Info button
    // retains the full preload/bridge report, even on legacy empty finishes.
    if(failed) [self showError:failure];
    [failure release];
}
- (void)dealloc {
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    [_nativePlayer stop]; [_nativePlayer release];
    [_results release];
    [_spinner release];
    [_statusLabel release];
    [_tableView release];
    [_searchBar release];
    [super dealloc];
}

@end
