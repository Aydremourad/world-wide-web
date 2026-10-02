#!/bin/zsh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required. Install it from https://brew.sh, then run this again."
  exit 1
fi

echo "Installing/updating Mac dependencies..."
brew install python@3.12 ffmpeg node deno git tailscale

PY="$(brew --prefix python@3.12)/bin/python3.12"
if [ ! -x "$PY" ]; then
  echo "Python 3.12 was not found after Homebrew install."
  exit 1
fi

if [ ! -d .venv ]; then
  "$PY" -m venv .venv
fi
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

mkdir -p .deps
if [ ! -d .deps/bgutil/.git ]; then
  echo "Fetching BgUtil PO-token provider 2.0.0..."
  git clone --depth 1 --branch 2.0.0 https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git .deps/bgutil
fi

echo "Building BgUtil provider..."
cd .deps/bgutil/server
npm ci --no-audit --no-fund
npx tsc
cd "$ROOT"

mkdir -p state

echo
echo "Mac backend dependencies are ready."
echo "Start Tailscale with: sudo brew services start tailscale"
echo "Then sign in with: sudo tailscale up"
echo "After that run: ./run-mac-funnel.sh"
