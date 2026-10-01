#!/bin/bash
# Installs only the YouTube service on a NEW Ubuntu 24.04 Oracle VM.
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo 'Run this installer as root.' >&2; exit 1; fi
source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
  echo 'This automatic installer requires Ubuntu 24.04.' >&2; exit 1
fi
project_path=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 python3-venv ffmpeg curl ca-certificates unzip iptables iptables-persistent fonts-dejavu-core
id youtube2g >/dev/null 2>&1 || useradd --system --home /var/lib/youtube2g --shell /usr/sbin/nologin youtube2g
install -d -m 755 /opt/youtube2g
if [[ $project_path != /opt/youtube2g ]]; then cp -a "$project_path"/. /opt/youtube2g/; fi
install -d -o youtube2g -g youtube2g /var/lib/youtube2g
python3 -m venv /opt/youtube2g/.venv
/opt/youtube2g/.venv/bin/pip install -r /opt/youtube2g/requirements.txt
/opt/youtube2g/.venv/bin/python /opt/youtube2g/make_clips.py
case $(uname -m) in
  aarch64) deno_target=aarch64-unknown-linux-gnu;;
  x86_64) deno_target=x86_64-unknown-linux-gnu;;
  *) echo 'Unsupported CPU architecture.' >&2;exit 1;;
esac
curl --fail --location --retry 3 https://github.com/denoland/deno/releases/download/v2.9.7/deno-$deno_target.zip -o /tmp/youtube2g-deno.zip
unzip -o /tmp/youtube2g-deno.zip -d /usr/local/bin deno
chmod 755 /usr/local/bin/deno
rm /tmp/youtube2g-deno.zip
chown -R root:root /opt/youtube2g
cat > /etc/systemd/system/youtube2g.service <<'UNIT'
[Unit]
Description=Stock iPhone OS 3 YouTube compatibility server
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=youtube2g
Group=youtube2g
WorkingDirectory=/opt/youtube2g
Environment=PORT=80
Environment=STATE_DIR=/var/lib/youtube2g
Environment=HOME=/var/lib/youtube2g
Environment=DENO_DIR=/var/lib/youtube2g/deno
Environment=PATH=/opt/youtube2g/.venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/opt/youtube2g/.venv/bin/python /opt/youtube2g/app.py
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/youtube2g
TimeoutStopSec=15
[Install]
WantedBy=multi-user.target
UNIT
# Add only HTTP; preserve existing SSH and other rules.
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
install -d /etc/iptables
iptables-save > /etc/iptables/rules.v4
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow 80/tcp; fi
systemctl daemon-reload
systemctl enable --now youtube2g.service
curl --fail --retry 5 --retry-connrefused --retry-delay 2 http://127.0.0.1/healthz
printf '\nYouTube 2G installed. Open http://YOUR_PUBLIC_IP/ on the phone.\n'
