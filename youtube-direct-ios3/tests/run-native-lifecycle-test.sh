#!/bin/sh
set -eu
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT
xcrun clang -fno-objc-arc -Wall -Wextra -Wno-unused-parameter -Itests/native-stubs -I. \
    -framework Foundation YTNativePlayer.m tests/native-player-lifecycle.m -o "$TESTDIR/native-lifecycle"
"$TESTDIR/native-lifecycle"
