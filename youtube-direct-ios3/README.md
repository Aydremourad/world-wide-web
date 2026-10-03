# YouTube for iPhone OS 3

Version 1.2.0 keeps the prepared 144p HLS video and its embedded AAC together.
An unavailable adaptive URL can no longer force this route back to 360p CPU
decoding. AAC access units go through the existing native AudioQueue pump,
including its PCM fallback, buffering recovery, pause and seek handling.
The network worker maintains three segments ahead instead of downloading the
entire movie during playback. Small video retains every picture while in sync;
measured lag may discard only non-reference pictures. A compatible Baseline
HLS rendition outranks a same-size Main rendition and uses Apple's player.

Navigation, layout and controls are unchanged. The fixture checks native AAC
decoding and seeking from fragmented MPEG-TS input, all 240 pictures from an
eight-second 144p/30-fps Main-profile movie, and a working HLS route with no
adaptive URLs. Build/emulator checks do not establish physical iPhone FPS.

This experimental branch replaces full download and conversion with a native
player for the original iPhone / iPhone 2G on iPhone OS 3.1.3. Once installed,
playback uses only the phone's Wi-Fi connection.

## Playback

The phone requests YouTube's Android player response using the existing client
identity. A prepared 144p AVC/AAC MPEG-TS HLS rendition is usable even when
separate adaptive URLs fail. Compatible Baseline HLS goes to Apple's player;
Main-profile HLS uses the static ARMv6 H.264 decoder and native AAC audio from
the same cached segments. Three segments are buffered ahead of the readers.

When HLS is unavailable, the resolver also tries tiny H.264 formats 597 or 160
with AAC format 140, and direct combined MP4 format 18. These readers use
bounded HTTP ranges and share their disk cache for a combined movie. MP4
metadata can be read from either end of the file. Format 18 still requires
decoding at its source resolution; reducing its displayed size does not remove
that CPU cost.

OpenGL ES 1 displays RGB565 frames, and audio provides the playback clock.
144p retains every picture while in sync. Measured lag may discard
non-reference pictures; reference B pictures remain intact. Audio packet
reads and HTTP requests run outside the audio callback, which only returns
used buffers. The existing pump handles buffering recovery, pause and seek.

Navigation, Done, Pause/Resume, seeking and rotation are unchanged. The app
does not encode videos or wait for a complete download. Sustained speed and
sync still require a physical iPhone 2G test.

## Installation

The [Actions build](https://github.com/Aydremourad/world-wide-web/actions/workflows/ios3-native-player.yml)
produces `com.aydre.youtubedirect_1.2.0_iphoneos-arm.deb` in the
`YouTubeDirect-iOS3-armv6` artifact. Install with iFile, or from a phone terminal:

```sh
dpkg -i com.aydre.youtubedirect_1.2.0_iphoneos-arm.deb
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

- Unencrypted MPEG-TS 144p HLS with AAC-LC, direct H.264/AAC combined format 18,
  and tiny separate tracks are supported.
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

The resolver tests cover 144p HLS without usable adaptive URLs, Baseline
selection, and an OK Android response with format 18's direct URL and
unavailable adaptive formats. The HLS audio test passes fragmented TS reads
through the production AAC reader and Apple's native converter, including
seeking. ARM11 checks compare decoded pictures and optimized DSP output.
These tests do not measure physical iPhone FPS or verify iPhone OS 3's native
audio decoder. The combined-player test reads native
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


## 1.0.0 refinement pass

1.0.0 is the first release-candidate-quality build based on the device-tested
0.9.2 player. The software player's controls now run an explicit layout pass
after full-screen presentation and rotation, fixing the iPhone OS 3 geometry
race that could leave the portrait volume slider off-screen until a landscape
round trip. Full-screen status-bar changes are immediate to avoid another
intermediate layout.

Video presentation is adaptive rather than all-or-nothing: near sync, every
decoded picture may be shown; once video starts falling behind, expensive
RGB conversion and OpenGL uploads are capped progressively at 20 or 15 fps.
This gives the ARMv6 decoder more CPU to recover without returning to the old
four-fps/keyframe-only behavior. The video worker receives a modest priority
increase while remaining below the audio producer. Audio buffering, PCM output,
seek behavior and the native Apple-player route are otherwise unchanged.

The search screen gets a small 1.0 polish pass with slightly roomier result
rows, tuned title/byline typography and the iPhone OS network activity
indicator during search and stream resolution. The playback diagnostic no
longer hard-codes a version string; the About sheet reads the bundle version.


## 1.0.0-debug1

This is a device-validation build, not the final 1.0 release. Full-screen ownership
moves ahead of modal presentation: the status bar is hidden before UIKit sizes the
player, the controller requests full-screen layout before presentation, and the
software player is presented without an animation that can preserve the old
460-point application frame. This targets the launch-in-portrait 20-point offset
that previously disappeared only after a landscape round trip.

The resolver now prefers itag 160 (normal 144p frame rate) over itag 597 (the
half-frame-rate poor-connectivity 144p stream). The selected itag and source FPS
are recorded in the About diagnostics. The debug player's center title also reports
measured displayed FPS once per second.

For low-resolution Main-profile H.264, the decoder starts with all pictures instead
of permanently discarding non-reference pictures. It falls back to non-reference
dropping only after more than one second of measured video lag, and returns to full
decoding after recovery. Severe drift is corrected sooner. The video loop no longer
calls sched_yield after every packet, and non-video packets in the video demuxer are
discarded because AAC is already handled by the independent audio reader.

A dedicated YUV420P-to-RGB565 conversion path avoids the generic swscale pipeline
for <=256x144 software video. Larger fallback sources retain swscale and conservative
frame dropping. If Apple's native player rejects a combined stream, the app now
resolves a 144p stream before entering the software player rather than decoding the
same large combined file in software.


## 1.0.0-debug2

Debug2 addresses two device findings from debug1: the main navigation UI could remain
under the restored status bar after closing a video, and software playback measured
about 4 displayed frames per second on the original iPhone.

The root controller now explicitly restores the visible status bar and the screen's
application frame when it reappears. The player restores the status bar before
dismissal, so UIKit never reveals the underlying navigation controller while it is
still laid out as a 320x480 fullscreen view.

The playback pipeline is tuned around the ARM1176JZF-S rather than asking it to
decode a 30 fps Main-profile stream it cannot sustain. Software playback prefers
itag 597 when available (144p, lower bitrate and nominally 15 fps), while itag 160
remains a fallback. The app build itself now uses -O3 and ARM1176-specific code
generation.

AAC first attempts direct compressed AudioQueue playback with the MP4 magic cookie.
If iPhone OS rejects that compressed queue, the existing AudioConverter-to-PCM path
remains the automatic fallback. Direct mode removes our PCM conversion work from
the application playback thread budget and tracks actual AAC frames per returned
queue buffer so the audio clock remains frame-based.

The video handoff is now zero-copy: converted RGB565 buffers are transferred into
NSData ownership rather than copied into a second 74 KiB allocation for every
presented 256x144 frame. The OpenGL drawable is RGB565 as well, matching the texture
and avoiding a 32-bit RGBA backbuffer. Video receives a higher worker priority;
direct AAC refill receives a lower one.

Debug2's player title reports two live rates: D is decoded video frames per second
and P is frames actually presented on screen. For example, "144p D13.8 P13.4"
means decoding and rendering are both near the 15 fps source rate; a high D with a
low P points to the render/handoff path instead.


## 1.1

1.1 is the polished release build after on-device debug1/debug2 validation.

The main screen keeps its original launch geometry. Status-bar/application-frame
repair is armed only when the custom player is actually presented and runs only
when returning from playback.

The player UI is release-clean again: the center title shows only the selected
resolution. Per-frame NSDictionary/NSNumber allocation was replaced with a
lightweight frame packet, OpenGL ES caches geometry and matrix state until layout
or Fit/Fill changes, and CPU frame data is released immediately after texture
upload. Hidden controls stop rebuilding playback labels until shown again.

Low-resolution H.264 disables the expensive loop filter, the AVIO reader uses a
64 KiB buffer, and FFmpeg decoder revision 4 is rebuilt with final -O3 and
ARM1176JZF-S-specific flags instead of allowing a trailing -O2 to win.

Direct AAC AudioQueue playback, RGB565 rendering, low-workload 144p selection,
adaptive catch-up, seeking, Fit/Fill, volume, rotation and Apple's native playback
route remain enabled.


## 1.1.1 playback refinement

Restores the navigation controller, navigation bar, and content view to their
exact pre-player frames after modal dismissal. Startup geometry stays under UIKit
control; applicationFrame is no longer applied as an extra status-bar inset.

Software video uses a bounded three-picture decode-ahead queue. CADisplayLink
selects the most recent due picture against the existing AudioQueue media clock;
future pictures stay queued, pause holds presentation, and seek/close flushes the
queue and wakes the producer. A timer supports systems without CADisplayLink.
The decoder no longer sleeps until each picture's presentation timestamp before
starting the next picture. Autoreleased network/demux objects drain per packet.

Decoder revision 5 adapts FFmpeg 2.8's existing ARM CABAC routine to ARMv6 A32.
Thumb IT and ARMv6T2 MOVW instructions are replaced; byte loads support unaligned
input. The original FFmpeg license headers remain. Low-resolution RGB565 conversion
uses ARM11 USAT for exact signed clipping. The stream selection and audio pump
are unchanged.

CI executes one million CABAC comparisons in each checked/unchecked mode and
18.8 million RGB565 pixel comparisons on an emulated ARM1176, plus queue timing
and the existing audio/seek/player regressions. Emulation verifies instructions
and output correctness, not real-device speed or UIKit layout. The info button
shows playback FPS and decode/conversion/read/display costs after closing a video;
the player controls remain clean. Actual 2G FPS and dismissal geometry still need
on-device validation.


## 1.1.2 video FPS

Decoder revision 6 adds ARM11 packed 16-bit H.264 luma/chroma motion compensation
and 4x4 inverse transforms. Interpolation, clipping, rounding, transform-block
clearing and decoded pixels are checked against FFmpeg's original C routines;
no approximate interpolation is substituted. Existing CABAC and RGB565 ARMv6
optimizations remain enabled. The ARM1176 emulator checks the actual ARM
instructions and compares every decoded frame from a 30 fps Main-profile clip.

High-rate H.264 begins with non-reference picture discard instead of first
building an audio/video backlog. Lower-rate sources keep all pictures until
adaptive hysteresis detects lateness. Reference pictures continue to be decoded;
this is not keyframe-only playback. Severe drift recovery seeks forward to a
future indexed keyframe with a six-second cooldown. It does not seek backward
and repeatedly decode the GOP behind the audio clock. Manual seeks retain their
existing exact-target preroll behavior.

A working 30 fps software stream now triggers one bounded check of the existing
lightweight client for a readable <=18 fps video representation. A successful
replacement changes only the video source and its metadata, preserving the
original AAC source and cache. Failure retains the working 30 fps source.
Native-compatible progressive streams do not incur this check.

Navigation restoration, player layout, controls and the audio pump are unchanged.
Real-device FPS still needs measurement; emulator CPU timing is diagnostic,
not an iPhone frame-rate claim.
