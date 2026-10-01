# YouTube 2G server

Backend for the original stock YouTube app on a jailbroken iPhone 2G running
iPhone OS 3.1.3. Uses TubeRepair to supply legacy GData feeds and converts videos
to 320x240 H.264 Baseline / AAC MP4. No home computer needs to remain running.

## Current setup

- GitHub branch: `youtube-2g-server`
- Render service: `youtube-2g`, Free compute, Hobby workspace
- Working phone address: `https://aydreyoutube2g.duckdns.org/`
- Render environment: `PUBLIC_BASE_URL=https://aydreyoutube2g.duckdns.org`
- Phone: TLSFix 1.1, root certificates, TubeRepair 1.2-Beta-1
- TubeRepair Custom URL: `https://aydreyoutube2g.duckdns.org/`

The user confirmed Safari compatibility-video playback, stock-app search, and
playback of preparation/error clips. Actual YouTube downloads failed with
“Sign in to confirm you’re not a bot.” Cookies were added as an optional recovery
method. Live playback of an actual YouTube video is not yet verified.

## Deploy the faster playback update

1. Open Render, select `youtube-2g`, and select **Manual Deploy → Deploy latest commit**.
2. Wait for **Live**.
3. Open https://aydreyoutube2g.duckdns.org/diagnostics. Confirm `version` is
   `2g-1.2-rc1` and `token_provider_ready` is `true`.
4. Keep the working phone Custom URL above. Search for **stream test** in the
   original YouTube app and play **Streaming test**.
5. If the sample plays, set `PLAYBACK_MODE=hls` in Render → Environment, then
   choose **Save and deploy** from the save dropdown. Leave it unset if the sample fails.

Automatic preparation and the short playback wait work with the default MP4
mode. HLS is optional until the phone passes the local streaming test.

There is no new paid service, domain, API key, or mandatory login for this update.
The existing optional private cookie secret is retained. Do not add a payment
method or upgrade compute to deploy this change.

## How the update works

The Docker image builds BgUtils PO-token provider 2.0.0 and runs it only on
`127.0.0.1:4416`. yt-dlp nightly 2026.09.27.232945 uses the mobile-web and
embedded YouTube clients; its provider plugin obtains playback tokens locally.
Both downloaded source archives are version-pinned and checksum-verified.

The supervisor waits for provider readiness, starts the legacy server, and
shuts down both processes if either stops. Downloader processes are limited to
one at a time to reduce memory usage on the free service. FFmpeg conversion
settings remain compatible with the iPhone 2G.

This follows current upstream guidance, but a token does not guarantee access
from a blocked hosting-provider IP. The deployed version 1.1 provider was ready,
but Me at the zoo still returned `youtube-bot-check`. No alternative public
ARMv6 server was verified working.

## Optional private YouTube cookies

Export only youtube.com cookies in Netscape format using the official yt-dlp wiki
instructions. Use a separate account without private videos, memberships, or
sensitive playlists: the playback server is public, and authenticated extraction
can access content available to that account. Account use with yt-dlp can risk
suspension. Never put cookie contents in GitHub, logs, or chat.

In Render → Environment → Secret Files, create `youtube-cookies.txt` and paste
the export. Render mounts it at `/etc/secrets/youtube-cookies.txt`. The server
automatically detects the file and gives each downloader an isolated writable
copy, deleted when the request finishes or fails. Cookies may expire and may
not overcome an IP block. `YOUTUBE_COOKIES_FILE` can override the file path.

## Diagnostics and limits

`/healthz` reports the application version. `/diagnostics` exposes only software
versions and readiness flags: no generated tokens, cookie contents, or account
information. `/status/VIDEO_ID` exposes a safe failure category such as
`youtube-bot-check`, `youtube-forbidden`, `cookies-expired`, `timeout`, or
`conversion-failed`. Private details remain in operator logs.

Free Render sleeps after idle periods, and cached videos can disappear after
sleep or restart. The image limits videos to ten minutes, converts one at a
time, and uses a bounded cache. Comments, sign-in inside the old app, live
streams, and cloud playlist management are not implemented. Browse tabs use
search-backed suggestions rather than official YouTube rankings.

## Verification

- Twenty-one local tests cover feeds, XML escaping, ranges, queue limits, credential
  copy cleanup, safe status reporting, and a real FFmpeg compatibility conversion.
- The token provider installs and compiles under Node 24; its local `/ping` responds.
- Both processes start through the supervisor; diagnostics report provider ready
  and the expected downloader version, the sample MP4 is served, and shutdown works.
- Version 1.1 built successfully on Render; its live provider was ready, but
  the tested YouTube download was blocked. Version 1.2 and stock-app HLS need
  the user's deployment and physical phone test.

## Primary sources

- https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide
- https://github.com/Brainicism/bgutil-ytdlp-pot-provider
- https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/tag/2026.09.27.232945
- https://render.com/docs/configure-environment-variables
- https://render.com/docs/free
- https://github.com/ObscureMosquito/TubeRepair-Client
- https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4

See NOTICE.md and LICENSE for attribution and licensing.


## Faster playback update (2g-1.2-rc1)

Short top search results (up to sixty seconds) begin preparing automatically
when their feeds are served. Prefetching uses only an idle queue; the server
does not download every visible result. Opening a video's details also starts
preparation, and its known metadata avoids a repeated metadata extraction.
A playback GET may wait up to eight seconds under the normal loading spinner
and serve the completed MP4 directly if it finishes during that interval.
Only two requests can wait at once, leaving server capacity for other routes.
Cached videos remain immediate. New long videos can still require preparation.

### Try progressive streaming in the stock app

1. Deploy the latest commit. Keep the existing TubeRepair Custom URL.
2. In the stock YouTube app search for **stream test**. Play the **Streaming test**
   result. This is an original local sample and does not need YouTube access.
3. If it plays, set Render environment variable `PLAYBACK_MODE=hls`, then choose
   **Save and deploy** from the save dropdown. This reuses the existing build.
4. If the stock app rejects the sample, leave `PLAYBACK_MODE` unset (MP4).

An optional streaming mode serves HLS version 2 playlists with integer durations
and separate MPEG-TS segments, H.264 Baseline level 3.0 / AAC-LC. Modern fragmented
MP4 is avoided. The video can begin after three complete two-second segments
are encoded while the rest continues. Full source download is still required
before encoding starts, so this reduces conversion wait rather than guaranteeing
instant playback. The original YouTube player must pass the phone test before
streaming is enabled. Partial files are not served, and failed streams are removed.

Settings: `PREFETCH_SECONDS=0` disables speculative prefetch;
`PLAYBACK_WAIT_SECONDS=0` disables the brief automatic wait; default is eight
seconds, capped at fifteen. The stream test always uses its own local files.

The real-time FFmpeg test verifies that a version 2 playlist and playable codec
segments appear while the encoder is still running. Routes, byte ranges, and
partial-stream safety are covered locally. Stock-app HLS playback remains
unverified on the physical phone.

At the live test of version 1.1, the provider was ready but Me at the zoo still
failed with `youtube-bot-check`, and diagnostics reported no private cookies
loaded. Faster playback cannot independently fix that upstream access failure.

Sources for legacy streaming:
https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/StreamingMediaGuide/UsingHTTPLiveStreaming/UsingHTTPLiveStreaming.html
https://developer.apple.com/library/archive/referencelibrary/GettingStarted/AboutHTTPLiveStreaming/about/about.html
https://ffmpeg.org/ffmpeg-formats.html
