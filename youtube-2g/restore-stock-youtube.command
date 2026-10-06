#!/bin/bash
set -e

PHONE="${1:-10.0.13.231}"

SSH_OPTS=(
  -o HostKeyAlgorithms=+ssh-rsa
  -o KexAlgorithms=+diffie-hellman-group1-sha1
  -o Ciphers=+aes128-cbc,3des-cbc
)

echo "Restoring stock YouTube + TubeRepair on $PHONE"

ssh "${SSH_OPTS[@]}" root@"$PHONE" 'sh -s' <<'REMOTE'
set -e

echo "[1/6] Removing custom YouTubeDirect package/app..."
killall YouTubeDirect 2>/dev/null || true
if dpkg -s com.aydre.youtubedirect >/dev/null 2>&1; then
  dpkg -r com.aydre.youtubedirect || true
fi
rm -rf /Applications/YouTubeDirect.app

echo "[2/6] Verifying Apple's stock YouTube.app..."
if [ ! -d /Applications/YouTube.app ]; then
  echo "ERROR: /Applications/YouTube.app is missing."
  echo "Do NOT continue. Restore YouTube.app from the iPhone1,1 3.1.3 IPSW."
  exit 20
fi
if [ ! -f /Applications/YouTube.app/YouTube ]; then
  echo "ERROR: Stock YouTube executable is missing."
  exit 21
fi

echo "[3/6] Checking TubeRepair..."
if ! dpkg -s bag.xml.tuberepair >/dev/null 2>&1; then
  echo "ERROR: TubeRepair (bag.xml.tuberepair) is not installed."
  echo "Install TubeRepair 1.2-Beta-1, then run this helper again."
  exit 22
fi

echo "[4/6] Writing TubeRepair preferences..."
mkdir -p /var/mobile/Library/Preferences
cat > /var/mobile/Library/Preferences/bag.xml.tuberepairpreference.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>URLEndpoint</key>
    <string>https://aydreyoutube2g.duckdns.org</string>
</dict>
</plist>
PLIST

cat > /var/mobile/Library/Preferences/com.apple.youtubeframework.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ConfiguredServiceHost</key>
    <string>aydreyoutube2g.duckdns.org</string>
</dict>
</plist>
PLIST

chown mobile:mobile   /var/mobile/Library/Preferences/bag.xml.tuberepairpreference.plist   /var/mobile/Library/Preferences/com.apple.youtubeframework.plist
chmod 600   /var/mobile/Library/Preferences/bag.xml.tuberepairpreference.plist   /var/mobile/Library/Preferences/com.apple.youtubeframework.plist

echo "[5/6] Clearing old YouTube process/cache state..."
killall YouTube 2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.youtube 2>/dev/null || true
rm -rf /var/mobile/Library/Caches/YouTube 2>/dev/null || true
if command -v uicache >/dev/null 2>&1; then
  uicache || true
fi

echo "[6/6] Summary..."
dpkg -s bag.xml.tuberepair 2>/dev/null | grep -E '^(Package|Version):' || true
echo "Stock app: /Applications/YouTube.app"
echo "TubeRepair URL: https://aydreyoutube2g.duckdns.org"
echo "Restarting SpringBoard..."
killall SpringBoard
REMOTE

echo
echo "Done. Open Apple's stock YouTube app after SpringBoard returns."
