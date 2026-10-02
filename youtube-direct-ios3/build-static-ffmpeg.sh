#!/bin/sh
set -e

if [ -z "$THEOS" ] && [ -d "$HOME/theos" ]; then
  THEOS="$HOME/theos"
  export THEOS
fi

SDKVER="${SDKVER:-3.1.3}"
SDKROOT="$THEOS/sdks/iPhoneOS${SDKVER}.sdk"
LEGACY_LD="${LEGACY_LD:-$HOME/cctools-armv6/bin/ld}"

if [ ! -d "$SDKROOT" ]; then
  echo "Missing SDK: $SDKROOT"
  exit 1
fi
if [ ! -x "$LEGACY_LD" ]; then
  echo "Missing armv6 linker: $LEGACY_LD"
  exit 1
fi

ROOT="$(pwd)"
DEPS="$ROOT/.deps"
SRC="$DEPS/FFmpeg-2.8.22"
GASDIR="$DEPS/gas-preprocessor"
GASPRE="$GASDIR/gas-preprocessor.pl"
OUT="$ROOT/layout/usr/libexec/ytdirect-ffmpeg"
REVFILE="$ROOT/layout/usr/libexec/ytdirect-ffmpeg.rev"
CONVERTER_REV="4"
mkdir -p "$DEPS" "$ROOT/layout/usr/libexec"

if [ -x "$OUT" ] && [ -f "$REVFILE" ] && [ "$(cat "$REVFILE")" = "$CONVERTER_REV" ]; then
  if file "$OUT" | grep -q "Mach-O executable arm_v6" \
    && ! xcrun otool -L "$OUT" | egrep -q 'libav(codec|format|util|filter)|libsw(scale|resample)' \
    && ! xcrun otool -l "$OUT" | grep -q LC_MAIN \
    && xcrun otool -l "$OUT" | grep -q LC_UNIXTHREAD; then
    echo "Reusing optimized bundled static converter: $OUT"
    exit 0
  fi
fi

if [ ! -d "$SRC/.git" ]; then
  echo "Fetching FFmpeg 2.8.22..."
  rm -rf "$SRC"
  git clone --depth 1 --branch n2.8.22 https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

if [ ! -f "$GASPRE" ]; then
  echo "Fetching gas-preprocessor for Apple ARM assembly..."
  rm -rf "$GASDIR"
  git clone --depth 1 https://github.com/libav/gas-preprocessor.git "$GASDIR"
fi
chmod +x "$GASPRE"

CC_WRAP="${TMPDIR:-/tmp}/ytdirect-ffmpeg-cc.sh"
LD_WRAP="${TMPDIR:-/tmp}/ytdirect-ffmpeg-ld.sh"

cat > "$CC_WRAP" <<EOF
#!/bin/sh
exec xcrun clang -arch armv6 -isysroot "$SDKROOT" -miphoneos-version-min=3.0 "\$@"
EOF

cat > "$LD_WRAP" <<EOF
#!/bin/sh
exec xcrun clang -arch armv6 -isysroot "$SDKROOT" -miphoneos-version-min=3.0 -fuse-ld="$LEGACY_LD" -Wl,-no_new_main -Wl,-no_pie "\$@"
EOF

chmod +x "$CC_WRAP" "$LD_WRAP"

cd "$SRC"
make distclean >/dev/null 2>&1 || true

echo "Configuring static armv6 FFmpeg..."
./configure \
  --enable-cross-compile \
  --target-os=darwin \
  --arch=arm \
  --cpu=arm1176jzf-s \
  --sysroot="$SDKROOT" \
  --cc="$CC_WRAP" \
  --as="$GASPRE $CC_WRAP -arch armv6" \
  --ld="$LD_WRAP" \
  --disable-shared \
  --enable-static \
  --disable-neon \
  --disable-armv6t2 \
  --disable-vfp \
  --disable-yasm \
  --disable-debug \
  --disable-stripping \
  --disable-doc \
  --disable-ffplay \
  --disable-ffprobe \
  --disable-ffserver \
  --disable-avdevice \
  --disable-postproc \
  --disable-network \
  --disable-securetransport \
  --disable-iconv \
  --disable-bzlib \
  --disable-lzma \
  --disable-zlib \
  --disable-vda \
  --disable-everything \
  --enable-protocol=file \
  --enable-demuxer=mov \
  --enable-muxer=mp4 \
  --enable-decoder=h264 \
  --enable-decoder=aac \
  --enable-encoder=mpeg4 \
  --enable-parser=h264 \
  --enable-filter=scale \
  --enable-filter=format \
  --enable-filter=fps \
  --enable-small \
  --extra-cflags="-O2 -miphoneos-version-min=3.0" \
  --extra-ldflags="-miphoneos-version-min=3.0"

echo "Building static armv6 FFmpeg..."
make -j2 ffmpeg

cp ffmpeg "$OUT"
chmod 0755 "$OUT"

LDID="$(command -v ldid 2>/dev/null || true)"
if [ -z "$LDID" ]; then
  LDID="$(find "$THEOS" -type f -name ldid -perm -111 2>/dev/null | head -1)"
fi
if [ -z "$LDID" ]; then
  echo "Could not find ldid to sign bundled converter."
  exit 1
fi

"$LDID" -S -Hsha1 "$OUT"

echo
echo "Checking bundled converter..."
file "$OUT"
xcrun otool -hv "$OUT" || true
xcrun otool -L "$OUT" || true

if xcrun otool -L "$OUT" | egrep -q 'libav(codec|format|util|filter)|libsw(scale|resample)'; then
  echo "ERROR: converter still depends on FFmpeg dylibs."
  exit 1
fi
if xcrun otool -l "$OUT" | grep -q LC_MAIN; then
  echo "ERROR: converter contains LC_MAIN."
  exit 1
fi
if ! xcrun otool -l "$OUT" | grep -q LC_UNIXTHREAD; then
  echo "ERROR: converter lacks LC_UNIXTHREAD."
  exit 1
fi

echo "$CONVERTER_REV" > "$REVFILE"
echo "Bundled optimized ARM1176 static converter ready: $OUT"
