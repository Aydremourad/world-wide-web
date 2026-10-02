# Phone installer

Download [YT Direct 0.7.1](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.7.1_iphoneos-arm.deb)
on the jailbroken iPhone and open it in iFile, then choose Install. This updates
the existing YT Direct app. Restart SpringBoard if the app does not appear.

Open YT Direct and paste `jNQXAC9IVRw` as the first test. It uses the phone's
Wi-Fi connection for playback; a computer does not need to stay on.

This is an experimental software-video player, not a stock YouTube patch.
It removes whole-video conversion. Smooth playback and AAC audio/container
compatibility still need confirmation on a physical iPhone 2G.

0.7.1 fixes rejection of streams with omitted `contentLength`, recovers lengths
from URLs or HTTP headers, skips encrypted candidates when a usable URL is
available, and tries Android, VisionOS and TV clients. Both media URLs are
checked before playback opens. Failure messages now preserve the client and
YouTube response instead of guessing that the video requires sign-in.

Build, resolver and streaming checks:
https://github.com/Aydremourad/world-wide-web/actions/runs/36956860648

These checks verify code behavior and the ARMv6 package, not current YouTube
playback on a phone. The live YouTube probe on the datacenter build machine
returned `LOGIN_REQUIRED: Sign in to confirm you're not a bot` for Android
and VisionOS. A separate read-only probe of the public TubeRepair service and
its Invidious API returned HTTP 403. No public relay has been added to this
release. The phone's Wi-Fi connection may receive a different response; that
has not been verified.

SHA256:
`6c646ccd9e07cdc6901fd67b56cb3ae628b706523adb2871e943a898fda437c6`

The package was compiled from commit
`95d5ca07c8d4b06626830f0a5c11c4412523716f` against the iPhone OS 3.1.3 SDK.
ARMv6, legacy Mach-O startup, the static decoder, bounded HTTP ranges and
prompt cancellation checks passed. The source and build scripts are in
`youtube-direct-ios3` on this branch.
