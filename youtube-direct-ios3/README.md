# YouTube for iPhone OS 3

This experimental branch replaces full download and conversion with a native
player for the original iPhone / iPhone 2G on iPhone OS 3.1.3. Once installed,
playback uses only the phone's Wi-Fi connection.

## Playback

The phone requests YouTube's Android player response using the previous app's
client identity. It prefers tiny H.264 format 597 or 160, plus AAC audio format
140. When those tracks have no usable URL, it selects direct combined MP4
format 18 instead. Both readers use bounded 64 KiB HTTP ranges; each reader
shares at most sixteen chunks for a combined movie. MP4 metadata can be read from either end of a file.

FFmpeg's static ARMv6 decoder decodes H.264 directly. OpenGL ES 1 displays
RGB565 frames; AudioQueue plays AAC audio. Audio is the playback clock. Late
video displays are dropped while H.264 reference frames are preserved. Format
18 is decoded directly at its source resolution and displayed at up to
256x144. Non-reference pictures and loop filtering are skipped for larger
sources to reduce decoder work. AAC is read from the combined MP4 through
Audio File Services with automatic container detection.

Audio packet reads and HTTP requests run on a background producer. The audio
callback only returns used buffers; it never fetches data. Six buffers provide
a bounded cushion, and the producer restarts a starved queue after refilling.

The app has Done, Pause/Resume and rotation. It does not encode videos or wait
for a complete download. Performance and sync still require a physical iPhone
2G test. A successful build does not establish smooth playback on that CPU.
The stock YouTube player's hardware decoder cannot provide this software path.

## Installation

The [Actions build](https://github.com/Aydremourad/world-wide-web/actions/workflows/ios3-native-player.yml)
produces `com.aydre.youtubedirect_0.9.0_iphoneos-arm.deb` in the
`YouTubeDirect-iOS3-armv6` artifact. Install with iFile, or from a phone terminal:

```sh
dpkg -i com.aydre.youtubedirect_0.9.0_iphoneos-arm.deb
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
- Offline downloads, sign-in and live streams are not implemented.
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

0.7.3 sends byte ranges in either the HTTP header or the URL query, never both
at once. It remembers a working method and tries the alternative after a
rejected range or an ignored header. Successful Content-Range responses
correct the source's byte length. A 416 with `bytes */N` can correct a stale
length and retry within the real file bounds; reads beyond the real EOF
return EOF. Any unrecovered 416 includes the requested offset, length and
range method without exposing signed URLs.

0.7.4 moves refills out of the AudioQueue callback. Its regression test reads
native AAC from a 36-second combined MP4 through delayed HTTP ranges, forces
queue underruns, checks that every packet reaches the simulated output, and
checks cancellation while fetching. This uses native macOS Audio File Services
and a simulated output queue; actual iPhone AudioQueue behavior and sustained
playback still require device verification. The user confirmed initial playback
on the physical iPhone with 0.7.3, followed by a freeze.

0.8.0 presents late video frames periodically instead of dropping them forever.
When large video decoding falls more than a second behind audio, it skips to
the next keyframe and flushes the stale decoder state. Audio uses eight 64 KiB
buffers. A producer watchdog pauses and resumes a queue whose clock stalls
with packets still queued, including when IsRunning remains true. Persistent
stall recovery failure reports an audio error instead of waiting indefinitely.

The player now has black full-screen controls, native Play/Pause, elapsed time,
duration, playback progress, volume, Fit/Fill and tap-to-show controls. It is
named YouTube, without the introductory description. Installation copies the
stock iOS 3 icon from /Applications/YouTube.app/icon.png, preserving the original
app. Refresh SpringBoard after installation if its old icon/name is cached.

0.9.0 inspects actual AVC profile and uses iOS 3's MPMoviePlayerController
for compatible combined Baseline H.264/AAC-LC MP4s. A loopback-only server
bridges the existing bounded HTTPS reader to HTTP byte ranges consumed by
Apple's player, including HEAD, suffix ranges, seeks and progressive GETs.
It performs no transcoding and no complete download before playback. Main-
profile or separate-track sources retain the software player. The source
profile is checked rather than inferred from its format number.

The software fallback converts AAC to 16-bit PCM using AudioConverter on the
producer thread before enqueueing audio. AudioQueue receives fixed PCM
frames, avoiding its compressed AAC queue and packet-boundary handling.
Twelve bounded buffers provide about 4.5 seconds at stereo 44.1 kHz. The
AAC magic cookie is applied to the converter. The screen and branding remain
unchanged; compatible streams use Apple's native player controls.

Combined audio/video readers now share a synchronized 1 MiB chunk cache. The
loopback bridge shares this cache across native player requests too, avoiding
duplicate downloads while retaining separate file positions and cancellation.


## 0.9.2 playback and seeking

The software player has a draggable timeline and native UIKit rewind/forward
buttons (15 seconds per tap), remaining time and replay after the end. A seek
cancels the old readers, joins the old audio producer and monitor, disposes the
old queue, and starts fresh video/AAC decoders at the same requested media time.
The video decoder seeks to the preceding keyframe and suppresses preroll; the
AAC reader selects a packet and trims PCM to the requested sample. User pause
is preserved, including a preview of the sought frame while paused. Rapid seeks
replace pending targets and reject frames from earlier sessions.

Playback cache storage survives seeks; each session has independent reader
cancellation. Main-thread drawing coalesces into one pending frame, so decoding
no longer waits for every OpenGL presentation. Late pictures can update at up
to 15 fps instead of the previous hard four-fps limit. Main-profile decoding
omits non-reference pictures and deblocking, including for small streams.
The static decoder is rebuilt with FFmpeg speed optimization (-O3,
CONFIG_SMALL=0); the previous size build selected -Os. Normal late playback
no longer skips entire groups to their keyframes. More
than three seconds of drift permits a video-only reposition, no more than once
in five seconds; audio remains on its current queue.

Native stream selection examines compatible combined formats regardless of
itag, and can recognize MPEG-4 Simple Profile with AAC-LC as well as Baseline
H.264. Actual codec headers still determine eligibility. MPEG-4 support is also
linked into the fallback decoder. These changes do not convert Main-profile
H.264 into Baseline, establish live availability of format 17, or prove smooth
playback on the physical 2G. The Home Screen installer fix from 0.9.1-1 remains.

The regression suite exercises bidirectional MP4 seeks, sought AAC PCM lengths
and media-clock origins, continuing non-key pictures under ordinary lateness,
reader cancellation isolation, and the native MPEG-4 Simple Profile probe.
