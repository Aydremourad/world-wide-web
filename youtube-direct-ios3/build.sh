#!/bin/sh
set -e

if [ -z "$THEOS" ] && [ -d "$HOME/theos" ]; then
  THEOS="$HOME/theos"
  export THEOS
fi

if [ -z "$THEOS" ]; then
  echo "Theos is not installed/configured."
  echo "Install it to ~/theos, then run this script again."
  exit 1
fi

if [ ! -d "$THEOS/sdks" ]; then
  echo "No Theos SDK directory found at $THEOS/sdks"
  exit 1
fi

SDK=""
SDKVER=""
for candidate in 3.1.3 3.1.2 3.1; do
  if [ -d "$THEOS/sdks/iPhoneOS${candidate}.sdk" ]; then
    SDK="iPhoneOS${candidate}.sdk"
    SDKVER="$candidate"
    break
  fi
done

if [ -z "$SDK" ]; then
  echo "Need an iPhone OS 3.1.x SDK in $THEOS/sdks."
  exit 1
fi

echo "Using $SDK"

LEGACY_LD="${LEGACY_LD:-$HOME/cctools-armv6/bin/ld}"
if [ ! -x "$LEGACY_LD" ]; then
  echo
  echo "Modern Xcode cannot link armv6."
  echo "Install cctools-port to $HOME/cctools-armv6 first."
  echo "Expected linker: $LEGACY_LD"
  exit 2
fi

LINK_WRAPPER="${TMPDIR:-/tmp}/youtube-direct-ios3-legacy-link.sh"
cp ./legacy-link.sh "$LINK_WRAPPER"
chmod +x "$LINK_WRAPPER"
export LEGACY_LD
export TARGET_LD="$LINK_WRAPPER"
echo "Using armv6 linker: $LEGACY_LD"

echo
echo "Preparing bundled ARMv6 converter..."
SDKVER="$SDKVER" LEGACY_LD="$LEGACY_LD" sh ./build-static-ffmpeg.sh

make clean SDKVERSION="$SDKVER" FINALPACKAGE=1
make package SDKVERSION="$SDKVER" FINALPACKAGE=1

BIN=".theos/obj/armv6/YouTubeDirect.app/YouTubeDirect"
if [ ! -f "$BIN" ]; then
  BIN=".theos/obj/release/armv6/YouTubeDirect.app/YouTubeDirect"
fi
if [ ! -f "$BIN" ]; then
  BIN=".theos/obj/debug/armv6/YouTubeDirect.app/YouTubeDirect"
fi
echo
echo "Checking Mach-O load commands..."
if [ -f "$BIN" ]; then
  xcrun otool -hv "$BIN" || true
  xcrun otool -l "$BIN" | egrep "LC_MAIN|LC_UNIXTHREAD|LC_VERSION_MIN_IPHONEOS|LC_BUILD_VERSION|version|minos" || true
  if xcrun otool -l "$BIN" | grep -q "LC_MAIN"; then
    echo "ERROR: Binary still contains LC_MAIN; iPhone OS 3 cannot launch it."
    exit 3
  fi
  if ! xcrun otool -l "$BIN" | grep -q "LC_UNIXTHREAD"; then
    echo "ERROR: Binary does not contain LC_UNIXTHREAD."
    exit 4
  fi
  if xcrun otool -hv "$BIN" | grep -q " PIE"; then
    echo "ERROR: Binary is still PIE; iPhone OS 3 build must be non-PIE."
    exit 5
  fi
  if xcrun otool -l "$BIN" | grep -q "LC_BUILD_VERSION"; then
    echo "ERROR: Binary contains modern LC_BUILD_VERSION."
    exit 6
  fi
  echo "Mach-O check passed: LC_UNIXTHREAD, non-PIE, legacy version command."
fi
echo
echo "Built packages:"
find packages -type f -name '*.deb' -maxdepth 2 -print
