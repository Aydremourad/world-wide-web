#!/bin/sh
set -e

LEGACY_LD="${LEGACY_LD:-$HOME/cctools-armv6/bin/ld}"
if [ ! -x "$LEGACY_LD" ]; then
  echo "armv6-capable linker not found at: $LEGACY_LD" >&2
  exit 1
fi

# Keep the current Apple clang driver, but force cctools-port ld64.
exec xcrun clang -fuse-ld="$LEGACY_LD" "$@"
