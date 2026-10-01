# YouTube 2G server

Backend for the original stock YouTube app on a jailbroken iPhone 2G running
iPhone OS 3.1.3. Uses TubeRepair for legacy GData feeds and ordinary MP4 playback.
The server runs on free Render; no home computer needs to remain running.

## Deploy version 1.3

1. Open Render, select `youtube-2g`, then **Manual Deploy → Deploy latest commit**.
2. Wait for **Live**. The deployed commit starts with the version 1.3 recovery change.
3. Open https://aydreyoutube2g.duckdns.org/diagnostics and check
   `version: 2g-1.3` and `playback_mode: mp4`.
4. Reopen the original YouTube app, search **playback test**, and play **Playback test**.
   This uses the same locally generated MP4 as the working Safari compatibility test.

No new environment variables, payment method, domain, or phone tweak is required.
`PLAYBACK_MODE=hls` from an earlier deployment is ignored, so it cannot select
an incompatible player path. The old streaming test ID also serves MP4 directly.
The new test ID avoids the previously rejected movie entry in the phone's cache.

## Current setup

- GitHub branch: `youtube-2g-server`
- Render service: `youtube-2g`, Free compute, Hobby workspace
- Phone address and TubeRepair Custom URL: `https://aydreyoutube2g.duckdns.org/`
- Render environment: `PUBLIC_BASE_URL=https://aydreyoutube2g.duckdns.org`
- Phone: TLSFix 1.1, modern root certificates, TubeRepair 1.2-Beta-1

The user confirmed Safari sample playback, stock-app search, and playback of
preparation/error clips. The corrected HLS sample was served successfully by
version 1.2.1, but the phone still rejected it. Version 1.3 removes HLS conversion
and delivery from the stock-app workflow and serves H.264 Baseline level 3.0 /
AAC-LC MP4. It preserves byte ranges, HEAD, fast-start metadata, and atomic cache
publication. Local test clips contain only original text and silent audio.

## Preparation and loading

Only the top search result is prefetched, only if it is at most sixty seconds
long and the conversion queue is idle. Opening video details also starts work.
Known result metadata avoids a redundant extraction before downloading.

A playback GET can wait up to eight seconds under the player's normal loading
indicator. If the MP4 finishes during that interval, it plays without the
preparation clip or a second tap. Only two requests may wait at once. Cached
videos play immediately. A new video still needs to be downloaded and converted
before the compatible MP4 is published; long videos may still require a retry.

`PREFETCH_SECONDS=0` disables speculative preparation.
`PLAYBACK_WAIT_SECONDS=0` disables the brief wait; the maximum is fifteen seconds.
Neither setting bypasses YouTube access restrictions.

## YouTube download status

Actual YouTube playback is not yet verified. The most recent live diagnostics
reported the token provider ready and no private cookies loaded; the tested
Me at the zoo download returned `youtube-bot-check`. MP4 recovery fixes the
rejected local sample path, not this separate upstream access failure.

The image pins yt-dlp nightly 2026.09.27.232945 and BgUtils PO-token provider
2.0.0, with checksum-verified source downloads. The provider runs on loopback
only at `127.0.0.1:4416`. The supervisor starts and monitors both processes.
Downloader requests are serialized to limit memory. A token does not guarantee
access from a blocked hosting-provider IP.

Optional recovery: export youtube.com cookies in Netscape format according to
the official yt-dlp wiki. Store them only in Render → Environment → Secret Files
as `youtube-cookies.txt`; Render mounts `/etc/secrets/youtube-cookies.txt`.
The server makes a private writable copy for each downloader and deletes it on
completion or failure. Never commit cookies to GitHub or paste them in chat.
Use an account without private or sensitive content; authenticated public-server
extraction can access content available to that account, and yt-dlp account use
can risk suspension. Cookies may expire and may not overcome the IP block.

## Diagnostics, limits, and verification

`/healthz` and `/diagnostics` expose versions and readiness only.
`/status/VIDEO_ID` reports a safe failure category such as `youtube-bot-check`,
`cookies-expired`, `youtube-forbidden`, `timeout`, or `conversion-failed`.
No cookie contents, account data, or generated tokens are returned.

Free Render can sleep when idle; caches are temporary and can disappear on
restart. The image supports videos up to ten minutes and converts one at a time.
Live streams, comments, cloud playlists, and sign-in in the stock app are absent.
Browse tabs use search-backed suggestions rather than official rankings.

Twenty-two local tests cover feed XML, public playback routes, byte ranges,
HEAD, immutable build-generated samples, migration from the old HLS setting,
queue limits, short-job automatic playback, private-cookie cleanup, and safe
error reporting. Real FFmpeg tests check H.264 Baseline/AAC-LC, MP4 fast-start
layout, and the full conversion-to-cache path. These tests establish server
behavior; they do not establish playback of a real YouTube video on the phone.

## Primary sources

- https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariWebContent/CreatingVideoforSafarioniPhone/CreatingVideoforSafarioniPhone.html
- https://github.com/Preloading/ios3tuberepairserver
- https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide
- https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies
- https://github.com/Brainicism/bgutil-ytdlp-pot-provider
- https://render.com/docs/configure-environment-variables
- https://render.com/docs/free
- https://github.com/ObscureMosquito/TubeRepair-Client
- https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4

See NOTICE.md and LICENSE for attribution and licensing.
