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


# 3) Fix stale/dead playback URLs shipped in upstream templates.
#    Several feeds advertise /video/sd/<id>, but upstream has no route for it.
#    The real playback endpoint is /getvideo/<id>.
templates_root = Path("/app/modified-tuberepair/tuberepair/templates")
patched_templates = []
for template in templates_root.rglob("*.jinja2"):
    text = template.read_text()
    if "/video/sd/" not in text:
        continue
    new_text = text.replace("/video/sd/", "/getvideo/")
    # Classic search's top-level content element claims 3GPP even though
    # getvideo() creates an MP4. Match the declared MIME to the real output.
    if template.as_posix().endswith("/classic/search.jinja2"):
        new_text = new_text.replace(
            '<content type="video/3gpp" src="{{url}}/getvideo/',
            '<content type="video/mp4" src="{{url}}/getvideo/'
        )
    template.write_text(new_text)
    patched_templates.append(str(template.relative_to(templates_root)))

print("Fixed dead /video/sd playback URLs in:", ", ".join(patched_templates))
