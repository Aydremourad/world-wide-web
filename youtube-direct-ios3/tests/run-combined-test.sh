#!/bin/sh
set -eu
ROOT="$(pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT
# Build the same FFmpeg revision as the phone app, for the runner's CPU.
git clone --quiet "$ROOT/.deps/FFmpeg-2.8.22" "$TESTDIR/decoder"
cd "$TESTDIR/decoder"
./configure --disable-shared --enable-static --disable-asm --disable-debug --disable-doc \
    --disable-ffmpeg --disable-ffplay --disable-ffprobe --disable-ffserver \
    --disable-avdevice --disable-avfilter --disable-postproc --disable-swresample \
    --disable-network --disable-securetransport --disable-iconv --disable-bzlib \
    --disable-lzma --disable-zlib --disable-vda --disable-everything \
    --enable-demuxer=mov --enable-decoder=h264 --enable-parser=h264 --enable-small > "$TESTDIR/config.log" 2>&1
make -j3 libavformat/libavformat.a libavcodec/libavcodec.a libswscale/libswscale.a libavutil/libavutil.a > "$TESTDIR/build.log" 2>&1
cd "$ROOT"
xcrun clang -fno-objc-arc -Wno-deprecated-declarations -I. -I"$TESTDIR/decoder" \
    -framework Foundation -framework AudioToolbox YTMediaSource.m YTAudioFile.m YTVideoDecoder.c tests/combined-player.m \
    "$TESTDIR/decoder/libavformat/libavformat.a" "$TESTDIR/decoder/libavcodec/libavcodec.a" \
    "$TESTDIR/decoder/libswscale/libswscale.a" "$TESTDIR/decoder/libavutil/libavutil.a" \
    -lm -o "$TESTDIR/combined-test"
"$TESTDIR/combined-test" tests/fixtures/combined-main-aac.mp4
