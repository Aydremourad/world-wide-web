#!/bin/zsh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [ ! -x .venv/bin/python ]; then
  echo "Run ./setup-mac.sh first."
  exit 1
fi
if [ ! -f .deps/bgutil/server/build/main.js ]; then
  echo "BgUtil provider is not built. Run ./setup-mac.sh first."
  exit 1
fi

TAILSCALE="$(command -v tailscale 2>/dev/null || true)"
if [ -z "$TAILSCALE" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
fi
if [ -z "$TAILSCALE" ]; then
  echo "Tailscale CLI was not found."
  echo "Install the Funnel-capable Homebrew formula with:"
  echo "  brew install --formula tailscale"
  echo "  sudo brew services start tailscale"
  echo "  sudo tailscale up"
  echo "Then run this script again."
  exit 1
fi

DNSNAME="$("$TAILSCALE" status --json | .venv/bin/python -c 'import json,sys; d=json.load(sys.stdin); print((d.get("Self") or {}).get("DNSName","").rstrip("."))')"
if [ -z "$DNSNAME" ]; then
  echo "Tailscale is not signed in or MagicDNS is unavailable."
  exit 1
fi

export PATH="$(brew --prefix)/bin:$PATH"
export PORT=10000
export STATE_DIR="$ROOT/state"
export MAX_CACHE_BYTES=1073741824
export MAX_VIDEO_SECONDS=1200
export SERVER_THREADS=8
export PLAYBACK_WAIT_SECONDS=180
export YOUTUBE_POT_ENABLED=1
export YOUTUBE_TOKEN_SERVER_DIR="$ROOT/.deps/bgutil/server"
export PUBLIC_BASE_URL="https://$DNSNAME"

source .venv/bin/activate

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting YouTube 2G backend on your Mac..."
python start.py &
SERVER_PID=$!

for i in {1..100}; do
  if curl -fsS http://127.0.0.1:10000/healthz >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "Backend stopped during startup."
    wait "$SERVER_PID"
    exit 1
  fi
  sleep 0.2
done

curl -fsS http://127.0.0.1:10000/healthz >/dev/null || {
  echo "Backend did not become ready."
  exit 1
}

echo "Enabling public HTTPS Funnel..."
"$TAILSCALE" funnel --bg --https=443 http://127.0.0.1:10000

echo
echo "============================================================"
echo "YouTube 2G is running at:"
echo "  https://$DNSNAME"
echo
echo "Diagnostics:"
echo "  https://$DNSNAME/diagnostics"
echo
echo "TubeRepair server host:"
echo "  $DNSNAME"
echo "============================================================"
echo
echo "Keep this Terminal window open and keep the Mac awake."
echo "Press Control-C to stop the backend."
wait "$SERVER_PID"
