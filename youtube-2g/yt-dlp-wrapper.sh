#!/bin/sh
set -eu

REAL_YTDLP="/usr/local/bin/yt-dlp-real"
COOKIE_FILE="/tmp/youtube-cookies.txt"

if [ -n "${YOUTUBE_COOKIES_B64:-}" ]; then
    umask 077
    TMP_COOKIE_FILE="${COOKIE_FILE}.$$"
    printf '%s' "$YOUTUBE_COOKIES_B64" | python -c 'import sys, base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read(), validate=True))' > "$TMP_COOKIE_FILE"
    mv "$TMP_COOKIE_FILE" "$COOKIE_FILE"
    exec "$REAL_YTDLP" --cookies "$COOKIE_FILE" "$@"
fi

exec "$REAL_YTDLP" "$@"
