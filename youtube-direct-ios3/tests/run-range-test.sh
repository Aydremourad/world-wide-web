#!/bin/sh
set -eu
TESTDIR="$(mktemp -d)"
python3 tests/range-server.py "$TESTDIR/port" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TESTDIR"' EXIT
xcrun clang -fno-objc-arc -Wno-deprecated-declarations -I. -framework Foundation \
    YTMediaSource.m tests/range-reader.m -o "$TESTDIR/range-reader"
READY_TRIES=0
while [ ! -f "$TESTDIR/port" ]; do
    kill -0 "$SERVER_PID"
    READY_TRIES=$((READY_TRIES + 1))
    test "$READY_TRIES" -lt 100
    sleep 0.1
done
"$TESTDIR/range-reader" "http://127.0.0.1:$(cat "$TESTDIR/port")"
