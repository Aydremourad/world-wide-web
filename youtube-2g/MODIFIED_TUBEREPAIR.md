# Modified TubeRepair deployment

This service runs the upstream Modified TubeRepair application unchanged.

Upstream:
https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4

Pinned upstream commit:
f94cea890ba94b8e92eccc02317f10b8439be144

## Runtime

- Stock iOS YouTube.app remains the client.
- TubeRepair points the app at https://aydreyoutube2g.duckdns.org
- The container clones the pinned upstream repository and runs:
  python main.py
  from the upstream tuberepair directory.
- No playback, login, route, yt-dlp, FFmpeg, redirect, or response code is patched.
- The container only supplies prerequisites required by the upstream README:
  Python 3.11, FFmpeg, and yt-dlp.
- GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET remain Render environment variables.

## Always-on / persistent login

The active render.yaml intentionally remains Free.

Upstream stores linked accounts in:
  /app/modified-tuberepair/tuberepair/data/tokens.json

On a paid Render service, mount a persistent disk directly at:
  /app/modified-tuberepair/tuberepair/data

That preserves upstream's own data directory without changing its Python code.

The optional reference profile is /render.always-on.yaml.
