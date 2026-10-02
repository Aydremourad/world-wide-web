#!/bin/sh
set -eu
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT
xcrun clang -fno-objc-arc -Wno-deprecated-declarations -I. -framework Foundation \
    YTYouTube.m YTMediaSource.m tests/resolver.m -o "$TESTDIR/resolver-test"
"$TESTDIR/resolver-test"
