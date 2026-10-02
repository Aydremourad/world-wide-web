# YouTube Direct: streaming player for iPhone OS 3

This experimental branch replaces full download and conversion with a native
player for the original iPhone / iPhone 2G on iPhone OS 3.1.3. Once installed,
playback uses only the phone's Wi-Fi connection.

## Playback

The phone requests YouTube's Android player response using the previous app's
client identity. It prefers tiny H.264 format 597 or 160, plus AAC audio format
140. When those tracks have no usable URL, it selects direct combined MP4
format 18 instead. Both readers use bounded 64 KiB HTTP ranges; each reader
caches at most eight chunks. MP4 metadata can be read from either end of a file.

FFmpeg's static ARMv6 decoder decodes H.264 directly. OpenGL ES 1 displays
RGB565 frames; AudioQueue plays AAC audio. Audio is the playback clock. Late
video displays are dropped while H.264 reference frames are preserved. Format
18 is decoded directly at its source resolution and displayed at up to
256x144. Non-reference pictures and loop filtering are skipped for larger
sources to reduce decoder work. AAC is read from the combined MP4 through
Audio File Services with automatic container detection.

The app has Done, Pause/Resume and rotation. It does not encode videos or wait
for a complete download. Performance and sync still require a physical iPhone
2G test. A successful build does not establish smooth playback on that CPU.
The stock YouTube player's hardware decoder cannot provide this software path.

## Installation

The [Actions build](https://github.com/Aydremourad/world-wide-web/actions/workflows/ios3-native-player.yml)
produces `com.aydre.youtubedirect_0.7.2_iphoneos-arm.deb` in the
`YouTubeDirect-iOS3-armv6` artifact. Install with iFile, or from a phone terminal:

```sh
dpkg -i com.aydre.youtubedirect_0.7.2_iphoneos-arm.deb
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

- Direct H.264/AAC combined format 18 and tiny separate tracks are supported.
  Other codecs and sources above 640 pixels per side or 307200 pixels per
  frame are rejected. Decoding format 18 may be too slow for smooth playback
  on a physical 2G; source resolution still determines H.264 decoding work.
- No seek control, offline downloads, sign-in or live streams yet.
- Restricted videos can fail, and YouTube can change client access.
- Googlevideo must honor byte ranges. Whole-file and non-media responses are
  rejected before they can fill the phone's memory.
- Network delays can interrupt audio. Smooth performance is unverified.

Branch: `youtube-native-player-ios3`. The converter version remains on
`youtube-direct-ios3`.

## Regression checks

The resolver tests reproduce an OK Android response with format 18's direct
URL and unavailable adaptive formats. The combined-player test reads native
AAC packets and decodes/scales Main-profile H.264 from a synthetic combined
MP4 using the production reader, audio-file opener, video decoder and FFmpeg
2.8.22. It runs on macOS; it does not verify iPhone OS 3's audio parser,
AudioQueue playback or the original iPhone's speed.
