#!/bin/sh
set -eu
ROOT="$(pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT
git clone --quiet --depth 1 --branch n2.8.22 https://github.com/FFmpeg/FFmpeg.git "$TESTDIR/decoder"
python3 patch-decoder.py "$TESTDIR/decoder"
cd "$TESTDIR/decoder"
./configure --enable-cross-compile --target-os=linux --arch=arm --cpu=arm1176jzf-s \
    --cc=arm-linux-gnueabi-gcc --disable-neon --disable-armv6t2 --disable-vfp \
    --disable-shared --enable-static --disable-debug --disable-doc --disable-everything \
    --disable-ffmpeg --disable-ffplay --disable-ffprobe --disable-ffserver \
    --disable-avdevice --disable-avfilter --disable-postproc --disable-swresample \
    --disable-network --disable-iconv --disable-bzlib --disable-lzma --disable-zlib \
    --enable-demuxer=mov --enable-decoder=h264,mpeg4 --enable-parser=h264,mpeg4video \
    --optflags="-O3 -mcpu=arm1176jzf-s -marm" > "$TESTDIR/config.log" 2>&1
grep -q '^#define HAVE_ARMV6_INLINE 1' config.h
grep -q '^#define HAVE_ARMV6T2_INLINE 0' config.h
make -j3 libavformat/libavformat.a libavcodec/libavcodec.a libswscale/libswscale.a libavutil/libavutil.a > "$TESTDIR/build.log" 2>&1 || { tail -80 "$TESTDIR/build.log"; exit 1; }
cd "$ROOT"
for safe in 0 1; do
    # The checked/unchecked reader changes at include time in this test.
    arm-linux-gnueabi-gcc -O3 -mcpu=arm1176jzf-s -marm -static -I"$TESTDIR/decoder" \
        -DUNCHECKED_BITSTREAM_READER="$safe" tests/cabac-arm11.c \
        "$TESTDIR/decoder/libavcodec/libavcodec.a" "$TESTDIR/decoder/libavutil/libavutil.a" \
        -lm -lpthread -o "$TESTDIR/cabac-test"
    qemu-arm -cpu arm1176 "$TESTDIR/cabac-test"
done
arm-linux-gnueabi-gcc -O3 -mcpu=arm1176jzf-s -marm -static -I. -I"$TESTDIR/decoder" \
    YTVideoDecoder.c tests/pixels.c "$TESTDIR/decoder/libavformat/libavformat.a" \
    "$TESTDIR/decoder/libavcodec/libavcodec.a" "$TESTDIR/decoder/libswscale/libswscale.a" \
    "$TESTDIR/decoder/libavutil/libavutil.a" -lm -lpthread -o "$TESTDIR/pixels-test"
qemu-arm -cpu arm1176 "$TESTDIR/pixels-test"
arm-linux-gnueabi-objdump -d "$TESTDIR/pixels-test" | grep -m1 usat
arm-linux-gnueabi-gcc -O3 -std=c99 -mcpu=arm1176jzf-s -marm -static -I. -I"$TESTDIR/decoder" \
    tests/motion-arm11.c "$TESTDIR/decoder/libavcodec/libavcodec.a" \
    "$TESTDIR/decoder/libavutil/libavutil.a" -lm -lpthread -o "$TESTDIR/motion-test"
YT_MOTION_BENCH=1 qemu-arm -cpu arm1176 "$TESTDIR/motion-test"
# Emulator elapsed time includes software emulation of ARM11 packed DSP.
# Count real guest instructions for the identical motion/IDCT workload too.
curl -fsSL https://raw.githubusercontent.com/qemu/qemu/v8.2.2/include/qemu/qemu-plugin.h -o "$TESTDIR/qemu-plugin.h"
gcc -O2 -fPIC -shared -I"$TESTDIR" tests/count-arm-instructions.c -o "$TESTDIR/count.so"
qemu-arm -cpu arm1176 -plugin "$TESTDIR/count.so" "$TESTDIR/motion-test" 0
qemu-arm -cpu arm1176 -plugin "$TESTDIR/count.so" "$TESTDIR/motion-test" 1
arm-linux-gnueabi-gcc -O3 -std=c99 -mcpu=arm1176jzf-s -marm -static -I. -I"$TESTDIR/decoder" \
    YTVideoDecoder.c tests/decoder-arm11.c "$TESTDIR/decoder/libavformat/libavformat.a" \
    "$TESTDIR/decoder/libavcodec/libavcodec.a" "$TESTDIR/decoder/libswscale/libswscale.a" \
    "$TESTDIR/decoder/libavutil/libavutil.a" -lm -lpthread -o "$TESTDIR/decoder-test"
qemu-arm -cpu arm1176 "$TESTDIR/decoder-test" tests/fixtures/video-motion-30.mp4
arm-linux-gnueabi-objdump -d "$TESTDIR/decoder-test" | grep -m1 sadd16
