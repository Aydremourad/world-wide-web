# Phone installer

Download [YT Direct 0.7.2](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.7.2_iphoneos-arm.deb)
on the jailbroken iPhone. Close YT Direct, open the package in iFile, and
choose Install. Reopen the app. This updates the existing YT Direct package.
Restart SpringBoard if the app does not appear.

The phone uses its own Wi-Fi connection during playback. A computer does not
need to remain on. This release adds no proxy or conversion service.

## What changed

The reported Android response contained a direct combined format 18 MP4 URL,
while the separate 144p video and AAC formats were unavailable to the app.
0.7.1 rejected that response before playback. 0.7.2 accepts the combined MP4
when separate tracks are unavailable. It reads video and AAC audio from that
file in bounded ranges, without downloading and converting the whole movie.

The decoder now accepts H.264 sources up to 640 pixels per side and 307200
pixels per frame, including format 18's usual 360p/480p sizes. It scales the
display to at most 256x144 and omits non-reference pictures and loop filtering
for larger sources to reduce work. Actual speed on the original iPhone has
not been measured. Scaling does not remove the work of decoding the original
source resolution.

Audio File Services detects the combined MP4 container automatically instead
of using a fixed M4A file hint. Error messages now distinguish encrypted
signatures from formats with no URL.

## Verified checks and limits

Build and regression checks:
https://github.com/Aydremourad/world-wide-web/actions/runs/36960281347

- The resolver accepts an OK Android response with a direct format 18 URL
  and unavailable separate tracks, checks bounded media reads, and avoids
  further blocked clients when this route succeeds.
- The app was built and signed for ARMv6 using the iPhone OS 3.1.3 SDK.
  Legacy startup, static decoder linkage and gzip package checks passed.
- On macOS, the production reader, audio-file opener and video decoder read
  131 AAC packets and decoded/scaled 46 Main-profile H.264 frames from a
  synthetic combined MP4 using FFmpeg 2.8.22. The test used four bounded
  range requests.
- Range boundaries, seeks, short responses, rejection of ignored ranges and
  cancellation checks passed.

These checks do not establish playback speed, AudioQueue output or the old
OS's container behavior on a physical iPhone 2G. Live YouTube API probes from
the datacenter runner still returned a bot-check error. The user's phone did
return Android format 18, but the new player's actual phone playback remains
unverified. This is an experimental build.

Try the same video that produced the reported error. If the new error says
`Video server returned HTTP 403`, the metadata request succeeded but the
media URL was denied. If it mentions `AAC` or `H.264`, playback reached the
audio reader or video decoder.

SHA256:
`f832a0c2696194bd2bd5d55814407e1965a7eb3fed31cfe36b6b09b5b0364cc2`

Compiled source commit:
`dfb2cb6ab20af2f38e4e8c13e826b8e948ebf9f9`
