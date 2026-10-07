#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_DIR="$SCRIPT_DIR/ios3-client-bridge"
IPHONE_IP="${1:-${IPHONE_IP:-10.0.13.231}}"

if [ -z "${THEOS:-}" ]; then
    if [ -d "$HOME/theos" ]; then
        export THEOS="$HOME/theos"
    else
        echo "THEOS is not set and $HOME/theos does not exist."
        echo "Set THEOS to your existing Theos installation and run this again."
        exit 1
    fi
fi

SSH_OPTS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o KexAlgorithms=+diffie-hellman-group1-sha1
    -o Ciphers=+aes128-cbc,3des-cbc
)

LEGACY_LD="$HOME/legacy-cctools/bin/arm-apple-darwin9-ld"

if [ ! -x "$LEGACY_LD" ]; then
    echo "Missing legacy armv6 linker:"
    echo "  $LEGACY_LD"
    echo
    echo "Your working iPhone 2G projects use this exact linker."
    exit 1
fi

if [ ! -d "$THEOS/sdks/iPhoneOS3.1.3.sdk" ]; then
    echo "Missing iPhoneOS3.1.3.sdk at:"
    echo "  $THEOS/sdks/iPhoneOS3.1.3.sdk"
    exit 1
fi

LINKER_SHIM="$(mktemp -d /tmp/tuberepair-armv6-linker.XXXXXX)"
trap 'rm -rf "$LINKER_SHIM"' EXIT
ln -s "$LEGACY_LD" "$LINKER_SHIM/ld"

SERVER_API="$(curl -fsS --max-time 10 https://aydreyoutube2g.duckdns.org/bridge-api-version 2>/dev/null || true)"
if [ "$SERVER_API" != "prepare-v2" ]; then
    echo
    echo "Render does not have the new nonblocking prepare API yet."
    echo "Deploy the latest youtube-2g-server branch on Render, then rerun this command."
    echo "Expected: prepare-v2"
    if [ -n "$SERVER_API" ]; then
        echo "Received: $SERVER_API"
    else
        echo "Received: no response"
    fi
    exit 2
fi

echo "[server] Nonblocking prepare API is live."
echo "[preflight] Verifying clang will use the legacy armv6 linker..."
PREFLIGHT="$(
    clang -### \
        -target armv6-apple-ios3.0 \
        -isysroot "$THEOS/sdks/iPhoneOS3.1.3.sdk" \
        -B"$LINKER_SHIM/" \
        -dynamiclib \
        -x c /dev/null \
        -o /tmp/tuberepair-armv6-preflight.dylib \
        2>&1 || true
)"

if ! printf '%s\n' "$PREFLIGHT" | grep -F "$LINKER_SHIM/ld" >/dev/null; then
    echo "ERROR: clang is still not selecting the legacy linker."
    echo
    echo "$PREFLIGHT"
    exit 1
fi

echo "[preflight] OK: clang selected $LINKER_SHIM/ld"

PROBE_C="$LINKER_SHIM/probe.c"
PROBE_DYLIB="$LINKER_SHIM/probe.dylib"
printf '%s\n' 'int tuberepair_armv6_link_probe(void) { return 1; }' > "$PROBE_C"

echo "[preflight] Performing a real armv6 dylib link..."
if ! clang \
    -target armv6-apple-ios3.0 \
    -isysroot "$THEOS/sdks/iPhoneOS3.1.3.sdk" \
    -B"$LINKER_SHIM/" \
    -dynamiclib \
    -Wl,-segalign,4000 \
    "$PROBE_C" \
    -o "$PROBE_DYLIB"; then
    echo "ERROR: real armv6 legacy-linker preflight failed."
    exit 1
fi

if command -v file >/dev/null 2>&1; then
    echo "[preflight] Output: $(file "$PROBE_DYLIB")"
fi
echo "[preflight] Real armv6 link succeeded."

echo "[1/4] Building ARMv6 iOS 3 bridge with verified legacy linker..."

cd "$BRIDGE_DIR"
rm -rf packages .theos
make clean
make package \
    DEBUG=0 \
    STRIP=0 \
    ARCHS=armv6 \
    TARGET=iphone:clang:3.1.3:3.0 \
    LEGACYFLAGS="-Xlinker -segalign -Xlinker 4000" \
    TARGET_LD="clang -B$LINKER_SHIM/"

DEB="$(ls -t packages/*.deb 2>/dev/null | head -n 1)"
if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
    echo "Build finished but no .deb was produced."
    exit 1
fi

echo "[2/4] Copying $(basename "$DEB") to iPhone at $IPHONE_IP..."
scp -O "${SSH_OPTS[@]}" "$DEB" "root@$IPHONE_IP:/tmp/tuberepair-ios3-bridge.deb"

echo "[3/4] Installing without replacing TubeRepair..."
ssh "${SSH_OPTS[@]}" "root@$IPHONE_IP" '
    set -e
    dpkg -i /tmp/tuberepair-ios3-bridge.deb
    rm -f /tmp/tuberepair-ios3-bridge.deb
    rm -f /tmp/TubeRepairIOS3Bridge.log
    killall YouTube >/dev/null 2>&1 || true
'

echo
echo "Installed TubeRepair iOS 3 Bridge."
echo "Open the STOCK YouTube app now."
echo "Use Featured or search for: ya mashallah"
echo "Tap ONE normal video and let it reach the failure/success point."
echo
read -r -p "After that test, press Return here to collect the client log..."

echo
echo "[4/4] Client tap trace:"
echo "------------------------------------------------------------"
ssh "${SSH_OPTS[@]}" "root@$IPHONE_IP" 'cat /tmp/TubeRepairIOS3Bridge.log 2>/dev/null || echo "NO BRIDGE LOG FOUND"'
echo "------------------------------------------------------------"
echo
echo "If playback still fails, copy everything between the dashed lines."
