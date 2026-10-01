#import "YTAppDelegate.h"
#import "YTViewController.h"

@implementation YTAppDelegate
@synthesize window = _window;
@synthesize navigationController = _navigationController;

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    YTViewController *root = [[[YTViewController alloc] init] autorelease];
    self.navigationController = [[[UINavigationController alloc] initWithRootViewController:root] autorelease];

    [self.window addSubview:self.navigationController.view];
    [self.window makeKeyAndVisible];
}

- (void)dealloc {
    [_navigationController release];
    [_window release];
    [super dealloc];
}
@end
