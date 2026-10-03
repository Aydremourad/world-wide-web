#!/bin/sh
set -eu
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT
cat > "$TESTDIR/sabr-stub.m" <<'EOF'
#import <Foundation/Foundation.h>
NSString *YTDownloadSABRVideo(NSDictionary *options, NSString **errorText) {
    if(errorText) *errorText=@"SABR not used by resolver fixtures.";
    return nil;
}
NSDictionary *YTNativeStreamInfo(NSDictionary *streams) {
    if(![[streams objectForKey:@"combined"] boolValue]) return nil;
    return [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES],@"eligible",
        [NSNumber numberWithInt:66],@"profile",
        [NSNumber numberWithInt:30],@"level",
        [NSNumber numberWithInt:640],@"width",
        [NSNumber numberWithInt:360],@"height",nil];
}
EOF
xcrun clang -fno-objc-arc -Wno-deprecated-declarations -I. -framework Foundation \
    YTYouTube.m YTMediaSource.m tests/resolver.m "$TESTDIR/sabr-stub.m" -o "$TESTDIR/resolver-test"
"$TESTDIR/resolver-test"
