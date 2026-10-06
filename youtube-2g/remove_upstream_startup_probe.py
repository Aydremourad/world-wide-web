from pathlib import Path

# 1) Remove the upstream import-time network/debug probe so startup cannot
#    block on Invidious before the web server binds its port.
video_path = Path("/app/modified-tuberepair/tuberepair/api/video.py")
video_text = video_path.read_text()

probe = '''print(
    "TEST CHANNEL ID:",
    get_channel_id_from_name("MrBeast")
)

'''

if probe not in video_text:
    raise SystemExit("Expected upstream TEST CHANNEL ID block not found")

video_path.write_text(video_text.replace(probe, "", 1))
print("Removed upstream import-time TEST CHANNEL ID probe")

# 2) Keep Render's existing /healthz setting compatible with pure upstream.
#    This is infrastructure-only: it does not touch playback, feeds, login,
#    yt-dlp, ffmpeg, or any TubeRepair response used by the iPhone.
static_path = Path("/app/modified-tuberepair/tuberepair/api/static.py")
static_text = static_path.read_text()

if '@static.route("/healthz")' not in static_text:
    static_text += '''

@static.route("/healthz")
def render_healthz():
    return "ok", 200
'''
    static_path.write_text(static_text)

print("Ensured /healthz route exists for Render")
