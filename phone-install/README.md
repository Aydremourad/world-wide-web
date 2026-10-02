# Phone installer

Download [YouTube 0.9.1-1](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.9.1-1_iphoneos-arm.deb)
on the jailbroken iPhone. Open the package in iFile and choose Install, then
fully power the phone off and on once to refresh the Home Screen. Open YouTube
and retry the same video. The Info button reports app version 0.9.1; the Debian
installer revision is 0.9.1-1.

This installer fixes the Home Screen registration command. Legacy `uicache`
locates its installation cache under the current user's home directory, so the
installer now invokes it with the `mobile` account's login context instead of
root. It also restores readable app metadata and executable permissions. The
application payload is byte-for-byte identical to the verified 0.9.1 package;
playback, the YouTube name and stock icon are preserved.

Playback uses only the phone's Wi-Fi. No computer, external streaming proxy,
browser, or full-movie conversion is required.

## Changes from 0.9.0

The shared media cache no longer holds its lock while a network request is in
progress. Cached audio and unrelated audio downloads remain available while a
video request is slow. Requests for the same chunk are still deduplicated.
Playback uses 256 KiB read-ahead instead of a separate HTTPS exchange every
64 KiB, retaining a 1 MiB cache limit.

Audio recovery runs on its own monitor thread, independently of a producer
waiting on HTTPS or AAC decoding. That monitor also owns user pause/resume,
preventing competing queue restart commands. Audio remains 16-bit PCM decoded
on the producer, with twelve bounded 64 KiB output buffers.

Video and the displayed progress now use media time bounded by consumed PCM.
A device clock continuing through silence can no longer advance video into
unheard audio. Queue timeline resets and paused playback are handled too.

When a compatible Baseline progressive stream and separate Main-profile video
are both exposed, stream selection now prefers the progressive candidate for
Apple's built-in full-screen player. Actual MP4 metadata still decides whether
the native route is eligible. If a large stream requires software decoding, the
app also tries direct 144p video through the Android VR client. It keeps the
already working stream if that optional request or its signed media URLs fail.
YouTube's availability on the phone's connection is not established by the CI
fixtures.

The software fallback runs its video thread at a lower priority than its audio
producer. Its controls take less space in landscape and show the selected
resolution. Keyframe catch-up remains available when CPU decoding falls behind.
The search interface, YouTube name and exact stock icon are retained. The Info
button supplies build and player diagnostics without signed media URLs.

## Verified checks

Installer checks passed with a simulated legacy cache command: the original
root invocation reproduces the cache error, while the corrected invocation uses
`mobile` and preserves the stock icon and app permissions. Debian version
ordering accepts 0.9.1-1 as an upgrade from 0.9.1. The new package retains the
original compressed application payload unchanged. Home Screen registration
on a physical phone has not been tested here.

Application build and tests (unchanged):
https://github.com/Aydremourad/world-wide-web/actions/runs/37001674325

- ARMv6, iPhone OS 3.1.3 SDK, legacy startup, static decoder linkage,
  MediaPlayer framework linkage and old-dpkg-compatible packaging passed.
- A blocked video download did not delay a cached audio read or an unrelated
  audio cache miss. Range validation, corrected lengths, 416 recovery and
  cancellation passed with both ordinary and larger bounded reads.
- Native stream preference and the optional low-resolution resolver passed
  with controlled API/media fixtures.
- Audio output recovered while its producer was still inside a five-second
  simulated HTTPS wait. A clock advancing without consumed PCM could not
  advance media time past the audible buffer. All 1,600,512 decoded PCM frames
  were consumed in the longer audio fixture.
- Single-owner user pause/resume, short-track prefill/final draining and
  cancellation passed.
- Main-profile decoding, keyframe catch-up and full native loopback delivery
  passed. The complete 36-second movie was delivered byte-for-byte, including
  repeated and concurrent byte-range requests without duplicate downloads.

These checks use native macOS Audio File Services and Audio Converter, the
actual FFmpeg decoder, and simulated audio output. They reproduce the new
contention, clock and recovery failure cases; they do not establish smooth
Main-profile decoding, Apple's full-screen UI, or sustained playback on a
physical iPhone 2G. Device playback remains the release gate for 1.0.

SHA256:
`4b0d6a994b5cdaca58082aa98027092392a146664ff0b0a772bdbc54a555ad9c`

Compiled source commit:
`1a4f1cfde3a712d358c29124102565bb4bdbee1b`
