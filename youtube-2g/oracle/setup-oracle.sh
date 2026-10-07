#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "[1/5] Installing Docker..."
$SUDO apt-get update
$SUDO apt-get install -y ca-certificates curl git openssl gnupg
$SUDO install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
$SUDO chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
$SUDO apt-get update
$SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
$SUDO systemctl enable --now docker

echo "[2/5] Preparing environment..."
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  cp .env.example .env
fi

if ! grep -Eq '^COMPANION_SECRET_KEY=[0-9a-fA-F]{16}$' .env; then
  SECRET="$(openssl rand -hex 8)"
  python3 - "$SECRET" <<'PY'
from pathlib import Path
import sys
p = Path(".env")
s = p.read_text()
lines = []
found = False
for line in s.splitlines():
    if line.startswith("COMPANION_SECRET_KEY="):
        lines.append("COMPANION_SECRET_KEY=" + sys.argv[1])
        found = True
    else:
        lines.append(line)
if not found:
    lines.append("COMPANION_SECRET_KEY=" + sys.argv[1])
p.write_text("\n".join(lines) + "\n")
PY
  echo "Generated 16-character Companion secret."
fi

echo "[3/5] Building TubeRepair and pulling Companion..."
$SUDO docker compose pull companion
$SUDO docker compose build --pull tuberepair

echo "[4/5] Starting services..."
$SUDO docker compose up -d

echo "[5/5] Local health checks..."
sleep 5
curl -fsS http://127.0.0.1:10000/healthz
echo
echo
echo "Testing Companion route locally..."
curl -sS -D - --max-time 30   -o /dev/null   'http://127.0.0.1:10000/getvideo/jNQXAC9IVRw' || true

echo
echo "Oracle TubeRepair stack is running on TCP 10000."
echo "Do not repoint DuckDNS yet. Test the VM public IP from your Mac first."
