# Phone installer

Download [YT Direct 0.7.4](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.7.4_iphoneos-arm.deb)
on the jailbroken iPhone. Close YT Direct, open the package in iFile, and
choose Install. Reopen the app and play the same song.

Playback uses only the phone's Wi-Fi. No computer or conversion service
needs to remain on.

## What changed

0.7.3 produced actual playback on the user's iPhone 2G, but stopped after the
initial buffered audio. 0.7.4 moves AAC packet reading and network fetching
out of the AudioQueue callback and onto a background producer. The callback
only returns consumed buffers. Six bounded buffers provide a cushion; the
producer refills and restarts a starved queue. Video continues to follow the
audio clock. Buffering is shown while the queue waits for more audio.

Closing playback cancels the producer's media request and joins it before
releasing the audio file and output queue.

The format 18 fallback and the HTTP 416 range fixes remain included.
No full download or on-phone conversion is required.

## Verified checks and limits

Build and regression checks:
https://github.com/Aydremourad/world-wide-web/actions/runs/36963498506

- ARMv6 build against iPhone OS 3.1.3, legacy startup, static decoder linkage,
  and old-dpkg-compatible gzip packaging passed.
- Bounded range requests, HTTP 416 recovery, resolver fallback, native AAC
  reading and Main-profile video decoding passed.
- The delayed-chunk audio test delivered all 1,563 AAC packets across 19
  network chunks, with nine queue starts after forced underruns. Callback
  duration stayed below the 0.1-second test limit.
- Cancellation during fetching and producer cleanup passed.

The delayed-chunk test uses native macOS Audio File Services and a simulated
output queue. It does not verify iPhone AudioQueue behavior or decoding speed.
Initial physical-device playback was confirmed with 0.7.3; sustained playback
with 0.7.4 still needs a device check. This is an experimental build.

SHA256:
`14cf5dc796f945172455bccb183e2d2d737ce5c012ac8c0c6c8ab6377e7427dc`

Compiled source commit:
`601299623d5c49efdc3f0bc77d7331c4c96cd9d0`
