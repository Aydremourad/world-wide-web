#import <UIKit/UIKit.h>
#import "YTNativePlayer.h"

@interface YTViewController : UIViewController
    <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, YTNativePlayerDelegate> {
    UISearchBar *_searchBar;
    UITableView *_tableView;
    NSArray *_results;
    UIActivityIndicatorView *_spinner;
    UILabel *_statusLabel;
    YTNativePlayer *_nativePlayer;
    BOOL _restoreChromeAfterPlayer;
}
@end

