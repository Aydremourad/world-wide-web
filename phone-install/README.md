# Phone installer

Download [YT Direct 0.7.0](https://raw.githubusercontent.com/Aydremourad/world-wide-web/youtube-native-player-ios3/phone-install/com.aydre.youtubedirect_0.7.0_iphoneos-arm.deb)
on the jailbroken iPhone and open it in iFile, then choose Install. This updates
the existing YT Direct app. Restart SpringBoard if the app does not appear.

Open YT Direct and paste `jNQXAC9IVRw` as the first test. It uses the phone's
Wi-Fi connection for playback; a computer does not need to stay on.

This is an experimental software-video player, not a stock YouTube patch.
It removes whole-video conversion. Smooth playback and AAC audio/container
compatibility still need confirmation on a physical iPhone 2G.

Build and streaming checks:
https://github.com/Aydremourad/world-wide-web/actions/runs/36954714661

SHA256:
`5e86edf326923aa777838126cfb158290505b4d9ffa5035aa466f5a60ddfc2ac`

The package was compiled from commit
`4ec1b7cb411acc401ef140761065175309cf9e22` against the iPhone OS 3.1.3 SDK.
ARMv6, legacy Mach-O startup, the static decoder, bounded HTTP ranges and
prompt cancellation checks passed. The source and build scripts are in
`youtube-direct-ios3` on this branch.
