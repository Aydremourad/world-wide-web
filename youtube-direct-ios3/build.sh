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
for candidate in iPhoneOS3.1.3.sdk iPhoneOS3.1.2.sdk iPhoneOS3.1.sdk; do
  if [ -d "$THEOS/sdks/$candidate" ]; then
    SDK="$candidate"
    break
  fi
done

if [ -z "$SDK" ]; then
  echo "Need an iPhone OS 3.1.x SDK in $THEOS/sdks."
  exit 1
fi

echo "Using $SDK"
make clean
make package
echo
echo "Built packages:"
find packages -type f -name '*.deb' -maxdepth 2 -print
