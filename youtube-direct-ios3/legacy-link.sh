#!/bin/sh
set -e

LEGACY_LD="${LEGACY_LD:-$HOME/cctools-armv6/bin/ld}"
if [ ! -x "$LEGACY_LD" ]; then
  echo "armv6-capable linker not found at: $LEGACY_LD" >&2
  exit 1
fi

# iPhone OS 3 predates LC_MAIN and PIE startup semantics used by modern ld64.
# Force the classic LC_UNIXTHREAD-style entry point and a non-PIE executable.
exec xcrun clang -fuse-ld="$LEGACY_LD" -Wl,-no_new_main -Wl,-no_pie "$@"
