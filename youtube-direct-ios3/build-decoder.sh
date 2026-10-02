#!/bin/sh
set -eu

# The libraries are linked into the application. No converter runs on the phone.
SDKVER="${SDKVER:-3.1.3}"
SDKROOT="$THEOS/sdks/iPhoneOS${SDKVER}.sdk"
LEGACY_LD="${LEGACY_LD:-$HOME/cctools-armv6/bin/ld}"
ROOT="$(pwd)"
DEPS="$ROOT/.deps"
SRC="$DEPS/FFmpeg-2.8.22"
GASDIR="$DEPS/gas-preprocessor"
REVFILE="$SRC/.ytdirect-decoder-rev"

test -d "$SDKROOT" || { echo "Missing SDK: $SDKROOT"; exit 1; }
test -x "$LEGACY_LD" || { echo "Missing ARMv6 linker: $LEGACY_LD"; exit 1; }
if [ -f "$REVFILE" ] && [ "$(cat "$REVFILE")" = "1" ] &&
   [ -f "$SRC/libavformat/libavformat.a" ] && [ -f "$SRC/libavcodec/libavcodec.a" ] &&
   [ -f "$SRC/libavutil/libavutil.a" ] && [ -f "$SRC/libswscale/libswscale.a" ]; then
    echo "Using cached ARMv6 decoder libraries."
    exit 0
fi
mkdir -p "$DEPS"
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch n2.8.22 https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi
if [ ! -f "$GASDIR/gas-preprocessor.pl" ]; then
    git clone --depth 1 https://github.com/libav/gas-preprocessor.git "$GASDIR"
fi
CC_WRAP="$DEPS/decoder-cc.sh"
LD_WRAP="$DEPS/decoder-ld.sh"
cat > "$CC_WRAP" <<EOF
#!/bin/sh
exec xcrun clang -arch armv6 -isysroot "$SDKROOT" -miphoneos-version-min=3.0 "\$@"
EOF
cat > "$LD_WRAP" <<EOF
#!/bin/sh
exec xcrun clang -arch armv6 -isysroot "$SDKROOT" -miphoneos-version-min=3.0 -fuse-ld="$LEGACY_LD" -Wl,-no_new_main -Wl,-no_pie "\$@"
EOF
chmod +x "$CC_WRAP" "$LD_WRAP" "$GASDIR/gas-preprocessor.pl"
cd "$SRC"
make distclean >/dev/null 2>&1 || true
./configure --enable-cross-compile --target-os=darwin --arch=arm --cpu=arm1176jzf-s \
    --sysroot="$SDKROOT" --cc="$CC_WRAP" --as="$GASDIR/gas-preprocessor.pl $CC_WRAP -arch armv6" \
    --ld="$LD_WRAP" --disable-shared --enable-static --disable-neon --disable-armv6t2 \
    --disable-vfp --disable-yasm --disable-debug --disable-stripping --disable-doc \
    --disable-ffmpeg --disable-ffplay --disable-ffprobe --disable-ffserver \
    --disable-avdevice --disable-avfilter --disable-postproc --disable-swresample \
    --disable-network --disable-securetransport --disable-iconv --disable-bzlib \
    --disable-lzma --disable-zlib --disable-vda --disable-everything \
    --enable-demuxer=mov --enable-decoder=h264 --enable-parser=h264 --enable-small \
    --extra-cflags="-O2 -miphoneos-version-min=3.0" --extra-ldflags="-miphoneos-version-min=3.0"
make -j"${JOBS:-3}" libavformat/libavformat.a libavcodec/libavcodec.a libswscale/libswscale.a libavutil/libavutil.a
echo "1" > "$REVFILE"
