# Phone installer

Download [YouTube 0.9.0](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.9.0_iphoneos-arm.deb)
on the jailbroken iPhone. Close the previous app, open the package in iFile,
and choose Install. Open YouTube and try the same video. This upgrades the
existing package. Respring if the Home Screen name or icon needs refreshing.
Playback uses only the phone's Wi-Fi; no computer needs to remain on.

This is an intermediate release before 1.0. Sustained playback on the physical
iPhone 2G remains unverified.

## Apple's built-in player

The app now checks the actual MP4 metadata before choosing a player. Combined
H.264 Baseline/AAC-LC streams within the original iPhone's playback limits use
MPMoviePlayerController from the iPhone OS 3.1.3 SDK. That route uses Apple's
own full-screen player and controls.

A streaming bridge runs inside the app, listening only on 127.0.0.1. It supplies
Apple's player with a continuous MP4 response and standard byte-range requests
while fetching bounded HTTPS chunks upstream. It requires no external proxy,
computer, browser, full-file download or conversion before playback.

Main-profile H.264 and separate video/audio tracks use the software player.
If a native playback failure is reported, the app falls back to that player.
The native route is selected from actual codec metadata, not the format number.

## Audio and video refinements

The software player now decodes AAC to 16-bit PCM on its background producer
before sending audio to Audio Queue. Twelve 64 KiB PCM buffers provide bounded
room for network delays. The audio callback only returns buffers and signals
the producer; it does no networking or decoding.

The watchdog checks both the audio clock and returned-buffer callbacks. It
restarts a stalled queue even when the queue reports that it is running, handles
clock resets, and reports persistent failure after repeated unsuccessful
restarts. User pause is respected.

Audio and video readers for a combined stream share a synchronized 1 MiB chunk
cache. Concurrent native-player requests share the same cache too, preventing
duplicate downloads while retaining independent read positions.

The software video player retains keyframe catch-up and periodic picture
updates when decoding falls behind audio. Its controls remain available for
streams requiring software decoding. Smooth decoding speed on the original
iPhone has not been established by the tests.

## Appearance

The app name is YouTube. Installation copies the exact stock icon from
/Applications/YouTube.app/icon.png (or Icon.png). The stock application's files
are preserved; the icon copy requires the stock app to remain installed.
Search and the rest of the application retain the existing interface.

## Verified checks

Final build and tests:
https://github.com/Aydremourad/world-wide-web/actions/runs/36969407774

- ARMv6, iPhone OS 3.1.3 SDK, legacy startup, static decoder linkage,
  MediaPlayer framework linkage and old-dpkg-compatible packaging passed.
- Native routing accepted the Baseline fixture and rejected the Main-profile
  fixture. The loopback bridge delivered a complete 36-second MP4 byte-for-byte,
  including HEAD, ordinary/suffix ranges, EOF responses, concurrent shared-cache
  requests and prompt shutdown.
- The combined Main-profile fixture decoded 46 pictures and read 131 AAC packets
  through two bounded upstream range requests shared by audio and video.
- Native Audio Converter produced all 1,600,512 PCM frames from the longer audio
  fixture across 19 network chunks. Simulated queue underruns and a queue that
  reported running while its clock and callbacks stopped recovered without
  losing decoded audio. Producer cancellation and cleanup passed.
- H.264 catch-up produced 35 pictures through 35.2 seconds while discarding
  826 stale packets. Clock restart continuity and periodic display passed.

The tests use macOS native Audio File Services and Audio Converter, the actual
FFmpeg decoder, and a simulated audio output queue. They do not verify Apple's
full-screen player, hardware decoding, audio output, or sustained playback on
a physical iPhone 2G. Device testing is required before calling this 1.0.

SHA256:
`52f8dae129c118105c3e2b14566b3332e91aea79e948047cdaccd0b687ca1eb7`

Compiled source commit:
`cedc7c3d18b7dd8778f6bd9ad6ebf5bf732a709a`
