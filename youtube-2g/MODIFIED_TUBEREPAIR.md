# Modified TubeRepair deployment

This service runs the actual upstream Modified TubeRepair project for classic iOS YouTube.

Upstream:
https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4

Pinned upstream commit:
f94cea890ba94b8e92eccc02317f10b8439be144

## Runtime

- Stock iOS YouTube.app remains the client.
- TubeRepair points the app at https://aydreyoutube2g.duckdns.org
- Upstream Modified TubeRepair provides GData feeds, search, history/subscriptions/login support and the iOS 3 playback conversion path.
- FFmpeg and a current yt-dlp nightly are installed by our Dockerfile because upstream expects them to be present.
- Dynamic state is routed through /var/data so a paid Render persistent disk can preserve login tokens, metadata caches and prepared media.

## Always-on Render setup

The active render.yaml intentionally remains on Free so repository updates cannot start billing automatically.

For always-on operation:
1. Change the youtube-2g service Compute Plan from Free to at least 1 CPU / 2 GB.
2. Add a 1 GB persistent disk mounted at /var/data.
3. Keep health check path /healthz.
4. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in Render.
5. Set the OAuth client type in Google Cloud to "TVs and Limited Input devices" and enable YouTube Data API v3.

A ready reference profile is in /render.always-on.yaml.

## Login

The upstream login system uses Google's device authorization flow. It stores linked device sessions under:
  /var/data/data/tokens.json

The iPhone does not send the user's Google password to this server. Authorization is completed on a modern browser using Google's own verification flow.
