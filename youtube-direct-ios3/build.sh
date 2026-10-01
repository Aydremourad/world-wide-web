#!/bin/sh
set -e

if [ -z "$THEOS" ]; then
  echo "THEOS is not set."
  echo "Example: export THEOS=~/theos"
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
make clean SDKVERSION="$SDKVER"
make package SDKVERSION="$SDKVER"
echo
echo "Built packages:"
find packages -type f -name '*.deb' -maxdepth 2 -print
