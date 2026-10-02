#!/bin/zsh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [ ! -x .venv/bin/python ]; then
  echo "Run: zsh setup-mac.sh"
  exit 1
fi
if [ ! -f .deps/bgutil/server/build/main.js ]; then
  echo "BgUtil provider is not built. Run: zsh setup-mac.sh"
  exit 1
fi
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "cloudflared is missing. Install it with:"
  echo "  brew install cloudflared"
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

TUNNEL_LOG="/tmp/youtube2g-cloudflared.log"
rm -f "$TUNNEL_LOG"

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$TUNNEL_PID" ]; then
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
    wait "$TUNNEL_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting Cloudflare Quick Tunnel..."
cloudflared tunnel --no-autoupdate --url http://127.0.0.1:10000 >"$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

PUBLIC_URL=""
for i in {1..150}; do
  if ! kill -0 "$TUNNEL_PID" >/dev/null 2>&1; then
    echo "cloudflared stopped during startup:"
    cat "$TUNNEL_LOG"
    exit 1
  fi
  PUBLIC_URL="$(grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
  if [ -n "$PUBLIC_URL" ]; then
    break
  fi
  sleep 0.2
done

if [ -z "$PUBLIC_URL" ]; then
  echo "Cloudflare did not provide a Quick Tunnel URL."
  cat "$TUNNEL_LOG"
  exit 1
fi

export PUBLIC_BASE_URL="$PUBLIC_URL"

source .venv/bin/activate
echo "Starting YouTube 2G backend..."
python start.py &
SERVER_PID=$!

for i in {1..150}; do
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
  echo "Backend did not become ready locally."
  exit 1
}

echo "Checking public tunnel..."
PUBLIC_OK=0
for i in {1..60}; do
  if curl -fsS --max-time 10 "$PUBLIC_URL/healthz" >/dev/null 2>&1; then
    PUBLIC_OK=1
    break
  fi
  sleep 0.5
done

if [ "$PUBLIC_OK" != "1" ]; then
  echo "The backend works locally, but the public Cloudflare URL did not become ready."
  echo "Tunnel log:"
  tail -80 "$TUNNEL_LOG"
  exit 1
fi

PUBLIC_HOST="${PUBLIC_URL#https://}"
echo
echo "============================================================"
echo "YouTube 2G is PUBLIC and verified:"
echo "  $PUBLIC_URL"
echo
echo "Diagnostics:"
echo "  $PUBLIC_URL/diagnostics"
echo
echo "TubeRepair server host:"
echo "  $PUBLIC_HOST"
echo "============================================================"
echo
echo "Keep this Terminal window open."
echo "The trycloudflare.com hostname changes each time this script is restarted."
echo "Press Control-C to stop the backend and tunnel."
wait "$SERVER_PID"
