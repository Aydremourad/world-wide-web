YouTube 2G, version 1.1 release candidate, prepared 2026-10-01.

The GData XML templates and categories.cat are adapted from:
https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4
Source commit f94cea890ba94b8e92eccc02317f10b8439be144.
That project includes TubeRepair work by its original contributors.
See the original repository for attribution and history.

The backend in app.py is a focused implementation for the stock iPhone OS 3 app.
It uses the upstream classic feed templates and ARMv6 MP4 compatibility approach,
with direct yt-dlp metadata, background jobs, validated video IDs, bounded cache,
byte ranges, XML escaping, and automatically installed cloud dependencies.
All project source and adapted templates are provided under GPL-3.0, see LICENSE.
Generated test/preparing/error clips contain only original text and silent audio.
TubeRepair client is a separate project. A compatible installed client is preferred;
the currently checked Skyglow package index does not list TubeRepair. The supplied
ConfiguredServiceHost preference is an experimental fallback, not a proven substitute
for all TubeRepair client hooks. TLSFix 1.1 is currently available from Skyglow.

The original version was deployed on Render. The user confirmed stock-app search
and playback of generated clips on the iPhone 2G. Live YouTube downloads remain
blocked by a bot check. Version 1.1 adds the upstream BgUtils token provider and
updated yt-dlp; local startup and compatibility tests pass, but this version must
still be tested against the actual Render outgoing IP. Cloud YouTube access may
remain blocked or change. Compatibility tests and mocked route tests do not establish
live YouTube playback. Google sign-in and live streaming are not implemented.
Browse tabs use search-backed suggestions, not official YouTube rankings.

The Docker image builds BgUtils PO-token provider 2.0.0 from its upstream source:
https://github.com/Brainicism/bgutil-ytdlp-pot-provider
Its source and GPL-3.0 license are retained at /opt/bgutil in the image.
The provider runs on loopback only. It may help with upstream bot checks, but
its maintainer does not guarantee successful downloads from blocked IP addresses.
