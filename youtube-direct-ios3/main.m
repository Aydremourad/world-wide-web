#import <UIKit/UIKit.h>
#import "YTAppDelegate.h"

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int ret = UIApplicationMain(argc, argv, nil, @"YTAppDelegate");
    [pool release];
    return ret;
}
