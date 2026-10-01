# YouTube Direct for iPhone OS 3

A native, serverless YouTube client experiment for the original iPhone / iPhone 2G.

This project does **not** use TubeRepair, Render, DuckDNS, a Mac proxy, or the stock
YouTube framework. After installation the phone talks directly to YouTube.

## Current flow

1. Search is sent directly from the phone to YouTube's InnerTube `search` endpoint.
2. Selecting a video sends a direct InnerTube `player` request.
3. The client tries current WEB and MWEB client identities.
4. It looks specifically for **itag 18**, the legacy progressive MP4 containing
   H.264 video and AAC audio in one file.
5. The returned `googlevideo.com` HTTPS URL is handed directly to
   `MPMoviePlayerController`.

There is no server-side video conversion and no computer needs to remain on.

## Why format 18

As of September 2026, current yt-dlp reports show WEB/MWEB can still expose format
18 even when YouTube requires PO tokens or SABR for most other formats. It is a
single progressive MP4 rather than separate audio/video streams, which is much
better suited to iPhone OS 3.

YouTube can change this behavior at any time, so this is intentionally isolated
from the existing TubeRepair branch.

## Requirements

- Jailbroken original iPhone / iPhone 2G
- iPhone OS 3.1.3
- TLSFix / modern root certificates, so native HTTPS requests can reach current
  YouTube and Googlevideo hosts
- Theos capable of producing armv6 binaries
- An iPhone OS 3.x SDK in `$THEOS/sdks`

The source intentionally avoids ARC, blocks, `NSJSONSerialization`, modern
Objective-C collection literals, and newer media APIs.

## Build

The Makefile currently targets armv6 and iPhone OS 3.1.

```sh
cd youtube-direct-ios3
make package
```

The generated `.deb` can be copied to the jailbroken phone and installed with:

```sh
dpkg -i com.aydre.youtubedirect_*.deb
killall SpringBoard
```

## First test

Before worrying about search, paste this known video URL into the search field:

`https://www.youtube.com/watch?v=jNQXAC9IVRw`

The app recognizes the video ID, requests the player response directly from
YouTube, extracts itag 18, and opens the returned media URL.

If this first direct playback works, the architecture is proven: no TubeRepair
or external backend is required. Search/result polish can then be improved
without changing the playback design.

## Current limitations

- Anonymous playback only.
- Itag 18 must be available for the video.
- Live streams are not supported.
- Age-restricted, members-only, paid, or other restricted videos may fail.
- Search parsing is deliberately small and iOS-3-compatible rather than a full
  modern JSON framework.
- YouTube may change InnerTube client versions or access requirements.

## Branch

`youtube-direct-ios3`
