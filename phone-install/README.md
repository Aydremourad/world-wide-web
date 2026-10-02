# Phone installer

Download [YouTube 0.8.0](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.8.0_iphoneos-arm.deb)
on the jailbroken iPhone. Close the previous app, open the package in iFile,
and choose Install. Respring once to refresh its Home Screen name and icon.
Open YouTube and try the same video. This upgrades the existing package.
Playback uses only the phone's Wi-Fi; no computer needs to remain on.

## Playback changes

Late video frames no longer get discarded indefinitely. If large video
falls more than a second behind audio, the decoder catches up at the next
keyframe. Reordered H.264 keyframes are drained before dropping more stale
packets. This reduces work, with a lower frame rate when decoding cannot
keep pace. Smooth performance on the original iPhone is still unverified.

AAC reads remain on the background producer. Eight 64 KiB buffers provide
more room for network delays. A watchdog pauses and resumes the output queue
if its clock stops with packets queued, even if IsRunning is still true.
Repeated unsuccessful recovery reports an error instead of waiting forever.
The playback clock handles a sample timeline restarting at zero.

## Appearance

The app name is YouTube. The explanatory text is removed. Installation copies
the exact stock icon from /Applications/YouTube.app/icon.png (or Icon.png).
The stock application's files are preserved. The icon copy requires the stock
app to remain installed.

The full-screen player has native Play/Pause, elapsed time, duration, progress,
volume, Fit/Fill, and controls that hide during playback and return on tap.
The progress bar displays position; seeking is not implemented.

## Verified checks

Build and tests:
https://github.com/Aydremourad/world-wide-web/actions/runs/36967336376

- ARMv6, iPhone OS 3.1.3 SDK, legacy startup, static decoder linkage and
  old-dpkg-compatible packaging passed. The stock-icon postinst is executable.
- Native AAC reading, Main-profile decoding, range requests, 416 recovery,
  resolver fallback and cancellation passed.
- Delayed audio delivered all 1,563 packets across 19 network chunks, with
  six queue starts after underruns and responsive callbacks.
- A simulated queue that reported running but stopped its clock and callbacks
  recovered without losing AAC packets.
- H.264 catch-up produced 35 pictures through 35.2 seconds while discarding
  826 stale packets from a combined MP4.
- Clock restart continuity and periodic display under sustained lateness passed.

Audio output is simulated in the macOS tests; native Audio File Services and
the actual decoder are used. These checks do not establish sustained device
playback or iPhone decoding speed. The user confirmed initial playback in
0.7.4, then reported video and audio freezes. 0.8.0 needs a physical-device check.

SHA256:
`c4ea6c6b2376dd78b5f4e5843c789ad236c4060aa6d9f7c4c99726413e5c018c`

Compiled source commit:
`40c41c4935bc74e3fd860f933985457433d764d1`
