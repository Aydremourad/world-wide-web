#import "YTViewController.h"
#import "YTYouTube.h"

@implementation YTViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"YouTube Direct";
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
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 155, bounds.size.width - 40, 80)];
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.textColor = [UIColor darkGrayColor];
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.numberOfLines = 4;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    _statusLabel.text = @"Direct YouTube client for iPhone OS 3.\nNo TubeRepair, Render, Piped, or Invidious.\nSearch above or paste a YouTube link.";
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_statusLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spinner.center = CGPointMake(bounds.size.width / 2, 135);
    _spinner.hidesWhenStopped = YES;
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spinner];
}

- (void)setBusy:(BOOL)busy text:(NSString *)text {
    if (busy) [_spinner startAnimating];
    else [_spinner stopAnimating];
    _statusLabel.hidden = NO;
    _statusLabel.text = text;
    _tableView.hidden = busy;
    _searchBar.userInteractionEnabled = !busy;
}

- (void)showError:(NSString *)message {
    [self setBusy:NO text:@"Search YouTube or paste a video URL."];
    _tableView.hidden = NO;
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"YouTube Direct"
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
    cell.detailTextLabel.text = [item objectForKey:@"author"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = [_results objectAtIndex:indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self beginResolve:[item objectForKey:@"id"]];
}

- (void)beginResolve:(NSString *)videoID {
    [self setBusy:YES text:@"Resolving and downloading video to iPhone..."];
    [NSThread detachNewThreadSelector:@selector(resolveThread:) toTarget:self withObject:videoID];
}

- (void)resolveThread:(NSString *)videoID {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *error = nil;
    NSURL *url = [YTYouTube directVideoURLForID:videoID error:&error];
    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        (url ? [url absoluteString] : @""), @"url",
        (error ? error : @""), @"error", nil];
    [self performSelectorOnMainThread:@selector(resolveFinished:) withObject:payload waitUntilDone:NO];
    [pool release];
}

- (void)resolveFinished:(NSDictionary *)payload {
    NSString *urlString = [payload objectForKey:@"url"];
    if (![urlString length]) {
        [self showError:[payload objectForKey:@"error"]];
        return;
    }

    [_spinner stopAnimating];
    _tableView.hidden = NO;
    _searchBar.userInteractionEnabled = YES;
    _statusLabel.hidden = YES;

    if (_moviePlayer) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:MPMoviePlayerPlaybackDidFinishNotification
                                                      object:_moviePlayer];
        [_moviePlayer stop];
        [_moviePlayer release];
        _moviePlayer = nil;
    }

    _moviePlayer = [[MPMoviePlayerController alloc] initWithContentURL:[NSURL URLWithString:urlString]];
    [_movieStartedAt release];
    _movieStartedAt = [[NSDate date] retain];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(movieFinished:)
                                                 name:MPMoviePlayerPlaybackDidFinishNotification
                                               object:_moviePlayer];
    [_moviePlayer play];
}

- (void)movieFinished:(NSNotification *)note {
    NSTimeInterval elapsed = _movieStartedAt ? -[_movieStartedAt timeIntervalSinceNow] : 999.0;
    NSDictionary *info = [note userInfo];
    NSError *mediaError = [info objectForKey:@"error"];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:MPMoviePlayerPlaybackDidFinishNotification
                                                  object:_moviePlayer];
    [_moviePlayer release];
    _moviePlayer = nil;
    [_movieStartedAt release];
    _movieStartedAt = nil;

    if (mediaError || elapsed < 4.0) {
        NSString *message = nil;
        if (mediaError)
            message = [NSString stringWithFormat:@"The local MP4 was rejected by iPhone OS 3 MediaPlayer: %@",
                       [mediaError localizedDescription]];
        else
            message = @"The local MP4 was downloaded successfully, but iPhone OS 3 MediaPlayer rejected it immediately. This means the remaining problem is the video file/container itself, not YouTube networking.";
        [self showError:message];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_moviePlayer stop];
    [_moviePlayer release];
    [_movieStartedAt release];
    [_results release];
    [_spinner release];
    [_statusLabel release];
    [_tableView release];
    [_searchBar release];
    [super dealloc];
}

@end
