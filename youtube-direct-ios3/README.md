# YouTube Direct: streaming player for iPhone OS 3

This experimental branch replaces full download and conversion with a native
player for the original iPhone / iPhone 2G on iPhone OS 3.1.3. Once installed,
playback uses only the phone's Wi-Fi connection.

## Playback

The phone requests YouTube's Android player response using the previous app's
client identity. It selects tiny H.264 format 597 (preferred) or 160, plus AAC
audio format 140. Both tracks are read in bounded 64 KiB HTTP ranges; each track
caches at most eight chunks. MP4 metadata can be read from either end of a file.

FFmpeg's static ARMv6 decoder decodes H.264 directly. OpenGL ES 1 displays
RGB565 frames; AudioQueue plays AAC audio. Audio is the playback clock. Late
video displays are dropped while H.264 reference frames are preserved.

The app has Done, Pause/Resume and rotation. It does not encode videos or wait
for a complete download. Performance and sync still require a physical iPhone
2G test. A successful build does not establish smooth playback on that CPU.
The stock YouTube player's hardware decoder cannot provide this software path.

## Installation

The [Actions build](https://github.com/Aydremourad/world-wide-web/actions/workflows/ios3-native-player.yml)
produces `com.aydre.youtubedirect_0.7.0_iphoneos-arm.deb` in the
`YouTubeDirect-iOS3-armv6` artifact. Install with iFile, or from a phone terminal:

```sh
dpkg -i com.aydre.youtubedirect_0.7.0_iphoneos-arm.deb
killall SpringBoard
```

This updates the existing YT Direct app (`com.aydre.youtubedirect`). It requires a
jailbreak and the same working HTTPS/certificate setup as the previous direct
downloader. No additional decoder dylibs are needed.

## First device test

Paste `jNQXAC9IVRw` or `https://www.youtube.com/watch?v=jNQXAC9IVRw` in YT Direct.
Check time to first picture, audio/video sync, Pause/Resume and Done during a
media request. Then try a longer video; startup should require initial chunks
rather than a conversion of the entire video.

## One-time local build

Use a Mac with Theos, an iPhone OS 3.x SDK, an ARMv6-capable cctools-port linker
and `ldid`:

```sh
cd youtube-direct-ios3
sh ./build.sh
```

`build.sh` compiles static decoder libraries and packages through Theos.
`ci-build.sh` compiles and packages without Theos makefiles. The checks require
ARMv6, classic `LC_UNIXTHREAD` startup, no PIE and no modern `LC_BUILD_VERSION`.
`package-deb.py` uses Debian 2.0, gzip and ustar for old dpkg compatibility.

Both builds use upstream LGPL FFmpeg 2.8.22. Its exact build configuration and
source download are in `build-decoder.sh`. The application avoids ARC, blocks,
modern collection literals and `NSJSONSerialization`.

## Limits

- Only tiny H.264 streams are accepted. Higher resolutions and modern codecs
  are not supported.
- No seek control, offline downloads, sign-in or live streams yet.
- Restricted videos can fail, and YouTube can change client access.
- Googlevideo must honor byte ranges. Whole-file and non-media responses are
  rejected before they can fill the phone's memory.
- Network delays can interrupt audio. Smooth performance is unverified.

Branch: `youtube-native-player-ios3`. The converter version remains on
`youtube-direct-ios3`.
