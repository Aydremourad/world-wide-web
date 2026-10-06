#!/bin/sh
set -eu

REAL_YTDLP="/usr/local/bin/yt-dlp-real"

if [ -n "${YTDLP_PROXY:-}" ]; then
    exec "$REAL_YTDLP" --proxy "$YTDLP_PROXY" "$@"
fi

exec "$REAL_YTDLP" "$@"
