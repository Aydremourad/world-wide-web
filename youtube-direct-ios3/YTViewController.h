#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

@interface YTViewController : UIViewController
    <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate> {
    UISearchBar *_searchBar;
    UITableView *_tableView;
    NSArray *_results;
    UIActivityIndicatorView *_spinner;
    UILabel *_statusLabel;
    MPMoviePlayerController *_moviePlayer;
}
@end
