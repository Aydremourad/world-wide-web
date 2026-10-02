# Phone installer

Download [YouTube 0.9.2](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.9.2_iphoneos-arm.deb)
on the jailbroken iPhone. Open it in iFile and choose Install, then open
YouTube. The installer closes the old backgrounded copy. Tap Info on the search
screen to confirm version 0.9.2. If its Home Screen icon is missing, fully power
the phone off and on once.

Playback uses the phone's Wi-Fi, without a computer, browser, external streaming
proxy or full-movie conversion. The YouTube name and stock icon are retained,
along with the corrected mobile-account Home Screen registration command.

## Changes from 0.9.1

- The fallback player has a draggable timeline, 15-second rewind and forward
  buttons, remaining time and replay after finishing. Seeking restarts both
  tracks at the requested time, removes video/AAC preroll, preserves user pause
  and replaces older pending seeks. A paused seek can show a preview frame.
- Ordinary late playback preserves reference pictures instead of skipping
  whole groups to their keyframes. Late-frame display no longer has a hard
  four-fps cap. Drawing keeps only one pending frame and no longer blocks the
  decoder on every screen update. Severe drift permits a bounded video-only
  reposition; the independent audio queue and recovery monitor remain active.
- The ARMv6 decoder is rebuilt for speed (-O3, CONFIG_SMALL=0), replacing the
  earlier size-optimized build. Main-profile decoding omits non-reference
  pictures and deblocking for small streams as well as large ones.
- Native selection examines compatible combined formats regardless of itag.
  Actual headers can route Baseline H.264 or MPEG-4 Simple Profile with AAC-LC
  to Apple's own full-screen player. A bounded metadata probe fills dimensions
  omitted by the legacy MPEG-4 demuxer. Unsupported profiles stay in the
  fallback; no profile relabeling or transcoding is used.

## Verification

Application build and regression run: https://github.com/Aydremourad/world-wide-web/actions/runs/37010970340

- ARMv6, iPhone OS 3.1.3 SDK, legacy startup, static decoder linkage,
  MediaPlayer linkage and old-dpkg-compatible gzip packaging.
- Cached and uncached audio reads during a blocked video request; bounded
  ranges, corrected lengths, 416 recovery and independent reader cancellation.
- Native format preference and optional low-resolution resolver fixtures.
- AAC seeks forwards and backwards: remaining PCM lengths and clock origins
  checked after 22.25, 4.75 and 31.15 seconds. Queue starvation, stalled output,
  recovery while HTTPS is blocked, pause/resume and final drain checks retained.
- The 36-second Main-profile fixture preserves non-key pictures under ordinary
  lateness. Video seeks at 22.25, 4.75, 31.15, 0 and 15.5 seconds reach the
  requested position within one retained frame.
- Native Baseline and MPEG-4 Simple Profile accepted; Main and Advanced Simple
  rejected. Complete loopback MP4 delivery, HEAD/ranges/suffix/EOF and
  simultaneous shared-cache requests checked.

These checks use the actual FFmpeg decoder and native macOS Audio File
Services/AudioConverter, with simulated audio output. They do not measure the
physical iPhone 2G's frame rate or establish that YouTube exposes a native-
compatible format on its connection. Large Main-profile streams can remain
CPU-bound. Device playback remains the release gate for 1.0.

SHA256: `a2bb44442d7358bc4ea1ececcb9064c79d5c90af528868160c43ec12f59cbabd`

Compiled source commit: `972800e9f7b4cec63e672ecc9cff133510a5b9fc`

Previous installer: [YouTube 0.9.1-1](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.9.1-1_iphoneos-arm.deb)
