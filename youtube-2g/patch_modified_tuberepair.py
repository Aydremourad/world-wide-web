"""Cloud compatibility patch for pinned Modified TubeRepair upstream.

Keeps upstream application behavior, but adapts its playback path for a
datacenter-hosted Render instance and the stock iPhone OS 3 movie player.
"""
from pathlib import Path

p = Path("/app/tuberepair/api/video.py")
s = p.read_text()

# The stock iOS 3 player is happier when the final MP4 is the response itself,
# not a redirect to Flask's static route. send_file(..., conditional=True)
# also gives us proper Range / Content-Range handling.
s = s.replace(
    "from flask import Blueprint, Flask, request, redirect, render_template, Response",
    "from flask import Blueprint, Flask, request, redirect, render_template, Response, send_file",
)
s = s.replace(
    'return redirect(f"/static/{video_id}.mp4", 302)',
    'return send_file(temp_output, mimetype="video/mp4", conditional=True)',
)

# Give every yt-dlp invocation a JS runtime before modifying its YouTube client.
s = s.replace(
    '"yt-dlp",',
    '"yt-dlp", "--ignore-config", "--js-runtimes", "node", "--socket-timeout", "15",',
)

# Upstream's local-server recipe uses the Android client directly. That often
# works from a home IP but gets restricted from cloud/datacenter IPs. Route
# all of its yt-dlp calls through the same PO-token-capable client mix that
# previously worked on this Render deployment.
old = '"--extractor-args", "youtube:player_client=android",'
new = (
    '"--extractor-args", "youtube:player_client=mweb,web_embedded,android_vr,default",\n'
    '                "--extractor-args", "youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416",'
)
if old not in s:
    raise SystemExit("Modified TubeRepair yt-dlp client anchor not found")
s = s.replace(old, new)

# Make the finished compatibility encode maximally conservative for the
# original iPhone hardware decoder. Upstream already uses Baseline L3.0,
# yuv420p and AAC-LC; these flags add the constraints that were proven on
# this device while retaining the upstream 320x240 picture.
s = s.replace(
    '"-pix_fmt", "yuv420p",',
    '"-pix_fmt", "yuv420p",\n'
    '                "-r", "15",\n'
    '                "-refs", "1",\n'
    '                "-bf", "0",\n'
    '                "-coder", "0",',
)

p.write_text(s)
print("Applied Modified TubeRepair Render/iOS3 playback patch")
