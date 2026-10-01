YouTube 2G, version 1.0 release candidate, prepared 2026-10-01.

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
TubeRepair client is a separate project and is installed from Skyglow in Cydia.

Not yet tested on a physical iPhone 2G or an Oracle VM. Cloud YouTube access may
be blocked or change. Compatibility tests and mocked route tests do not establish
live YouTube playback. Google sign-in and live streaming are not implemented.
Browse tabs use search-backed suggestions, not official YouTube rankings.
