#!/bin/sh
set -eu
SDKVER="${SDKVER:-3.1.3}"
SDKROOT="$THEOS/sdks/iPhoneOS${SDKVER}.sdk"
sh ./build-decoder.sh
SRC=".deps/FFmpeg-2.8.22"
STAGE=".ci-package"
APP="$STAGE/Applications/YouTubeDirect.app"
mkdir -p "$APP" "$STAGE/DEBIAN" packages
xcrun clang -arch armv6 -isysroot "$SDKROOT" -miphoneos-version-min=3.0 \
    -fno-objc-arc -O2 -Wno-deprecated-declarations -I"$SRC" \
    main.m YTAppDelegate.m YTViewController.m YTYouTube.m YTMediaSource.m YTVideoSurface.m YTSoftwarePlayer.m YTAudioFile.m YTAudioPump.m YTNativeProbe.m YTLoopbackServer.m YTNativePlayer.m YTVideoDecoder.c \
    "$SRC/libavformat/libavformat.a" "$SRC/libavcodec/libavcodec.a" \
    "$SRC/libswscale/libswscale.a" "$SRC/libavutil/libavutil.a" \
    -framework UIKit -framework Foundation -framework AudioToolbox -framework QuartzCore \
    -framework OpenGLES -framework MediaPlayer -lm -fuse-ld="$LEGACY_LD" -Wl,-no_new_main -Wl,-no_pie \
    -o "$APP/YouTubeDirect"
cp Resources/Info.plist "$APP/Info.plist"
cp control "$STAGE/DEBIAN/control"
cp layout/DEBIAN/postinst "$STAGE/DEBIAN/postinst"
chmod 0755 "$STAGE/DEBIAN/postinst"
ldid -S -Hsha1 "$APP/YouTubeDirect"
chmod 0755 "$APP/YouTubeDirect"
file "$APP/YouTubeDirect"
xcrun otool -L "$APP/YouTubeDirect"
xcrun otool -l "$APP/YouTubeDirect" > .ci-load-commands.txt
xcrun otool -hv "$APP/YouTubeDirect" > .ci-header.txt
grep -q LC_UNIXTHREAD .ci-load-commands.txt
if grep -qE 'LC_MAIN|LC_BUILD_VERSION' .ci-load-commands.txt || grep -q ' PIE' .ci-header.txt; then
    echo "The binary contains startup commands that iPhone OS 3 cannot use."; exit 1
fi
if xcrun otool -L "$APP/YouTubeDirect" | grep -qE 'libav(codec|format|util)|libswscale'; then
    echo "The binary depends on unbundled decoder libraries."; exit 1
fi
python3 ./package-deb.py "$STAGE" packages/com.aydre.youtubedirect_0.9.1-1_iphoneos-arm.deb
echo "ARMv6, legacy startup, static decoder and gzip package checks passed."
