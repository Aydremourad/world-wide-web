#!/usr/bin/env python3
import os
import sys

REAL_YTDLP = "/usr/local/bin/yt-dlp-real"

args = sys.argv[1:]
rewritten = []
has_youtube_client = False

i = 0
while i < len(args):
    arg = args[i]

    if arg == "--extractor-args" and i + 1 < len(args):
        value = args[i + 1]

        if value.startswith("youtube:"):
            body = value[len("youtube:"):]
            parts = body.split(";") if body else []
            out_parts = []
            saw_client = False

            for part in parts:
                key = part.split("=", 1)[0].strip().replace("-", "_")
                if key == "player_client":
                    out_parts.append("player_client=mweb")
                    saw_client = True
                    has_youtube_client = True
                else:
                    out_parts.append(part)

            if not saw_client:
                out_parts.append("player_client=mweb")
                has_youtube_client = True

            rewritten.extend(["--extractor-args", "youtube:" + ";".join(out_parts)])
            i += 2
            continue

    rewritten.append(arg)
    i += 1

if not has_youtube_client:
    rewritten = ["--extractor-args", "youtube:player_client=mweb"] + rewritten

# Current yt-dlp guidance for YouTube:
# - mweb client
# - external PO-token provider for GVS
# - supported JS runtime/EJS
# - browser impersonation for TLS-level client fingerprinting
prefix = [
    "--ignore-config",
    "--js-runtimes", "node",
    "--impersonate", "chrome",
    "--extractor-args", "youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416",
]

os.execv(REAL_YTDLP, [REAL_YTDLP, *prefix, *rewritten])
