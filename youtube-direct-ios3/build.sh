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

chmod +x ./legacy-link.sh
export LEGACY_LD
export TARGET_LD="$PWD/legacy-link.sh"
echo "Using armv6 linker: $LEGACY_LD"
make clean SDKVERSION="$SDKVER"
make package SDKVERSION="$SDKVER"
echo
echo "Built packages:"
find packages -type f -name '*.deb' -maxdepth 2 -print
