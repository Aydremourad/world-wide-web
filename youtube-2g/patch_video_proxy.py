#!/usr/bin/env python3
from pathlib import Path

p = Path("/app/tuberepair/api/video.py")
s = p.read_text()

# Make every yt-dlp subprocess use a persistent Netscape cookie jar when present.
# TubeRepair's /var/data is already a persistent Docker volume on Oracle.
cookie_helper = r'''
_YTDLP_COOKIE_FILE = os.environ.get(
    "YTDLP_COOKIE_FILE",
    "/var/data/youtube-cookies.txt",
)

def _yt_dlp_auth_args():
    if _YTDLP_COOKIE_FILE and os.path.exists(_YTDLP_COOKIE_FILE) and os.path.getsize(_YTDLP_COOKIE_FILE) > 0:
        return ["--cookies", _YTDLP_COOKIE_FILE]
    return []
'''

route_anchor = '@video.route("/getvideo/<video_id>")\n'
if route_anchor not in s:
    raise SystemExit("Could not find getvideo route anchor")

s = s.replace(route_anchor, cookie_helper + "\n" + route_anchor, 1)

# Inject cookie args after every yt-dlp executable in list-form subprocess calls.
s = s.replace(
    '"yt-dlp",\n',
    '"yt-dlp",\n                *_yt_dlp_auth_args(),\n',
)

# Current yt-dlp recommended YouTube path: mweb + external PO-token provider.
# bgutil's HTTP plugin auto-discovers its provider at 127.0.0.1:4416.
s = s.replace(
    '["--extractor-args", "youtube:player_client=android"]',
    '["--extractor-args", "youtube:player_client=mweb"]'
)
s = s.replace(
    '"--extractor-args", "youtube:player_client=android",',
    '"--extractor-args", "youtube:player_client=mweb",'
)

route_anchor = '@video.route("/getvideo/<video_id>")\n'
if route_anchor not in s:
    raise SystemExit("Could not find getvideo route anchor")

helper = r'''
# ---- iPhone 2G server-only playback proxy ---------------------------------
# Keep Modified TubeRepair's feeds/login/UI contract unchanged.  When the
# stock app requests /getvideo/<id>, first try a small set of current public
# Invidious instances with local=true so the instance/Companion obtains and
# proxies the YouTube media rather than Render doing YouTube extraction.
#
# The incoming Range header is forwarded because MPMoviePlayerController on
# iPhone OS 3 probes MP4s with byte-range requests.
_LOCAL_COMPANION_URL = os.environ.get("LOCAL_COMPANION_URL", "").rstrip("/")

_INVIDIOUS_VIDEO_PROXIES = [
    host.strip()
    for host in os.environ.get(
        "INVIDIOUS_VIDEO_PROXIES",
        "invidious.tiekoetter.com,invidious.nerdvpn.de,inv.nadeko.net,yt.chocolatemoo53.com",
    ).split(",")
    if host.strip()
]

def _proxy_invidious_video(video_id):
    source_headers = {
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 3_1_3 like Mac OS X)",
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "Connection": "keep-alive",
    }

    incoming_range = request.headers.get("Range")
    if incoming_range:
        source_headers["Range"] = incoming_range

    candidates = []
    if _LOCAL_COMPANION_URL:
        candidates.append(("local-companion", _LOCAL_COMPANION_URL + "/latest_version"))
    candidates.extend(
        (host, f"https://{host}/latest_version")
        for host in _INVIDIOUS_VIDEO_PROXIES
    )

    for host, base_url in candidates:
        source_url = f"{base_url}?id={video_id}&itag=18&local=true"

        upstream = None
        try:
            print(
                "VIDEO PROXY TRY:",
                video_id,
                host,
                "range=",
                incoming_range or "none",
                flush=True,
            )

            upstream = requests.get(
                source_url,
                headers=source_headers,
                stream=True,
                allow_redirects=True,
                timeout=(6, 20),
            )

            content_type = (upstream.headers.get("Content-Type") or "").lower()
            if upstream.status_code not in (200, 206):
                print(
                    "VIDEO PROXY REJECT:",
                    host,
                    "status=",
                    upstream.status_code,
                    "type=",
                    content_type,
                    flush=True,
                )
                upstream.close()
                continue

            if (
                "video/" not in content_type
                and "application/octet-stream" not in content_type
            ):
                print(
                    "VIDEO PROXY REJECT:",
                    host,
                    "unexpected type=",
                    content_type,
                    flush=True,
                )
                upstream.close()
                continue

            response_headers = {
                "Content-Type": upstream.headers.get("Content-Type", "video/mp4"),
                "Accept-Ranges": upstream.headers.get("Accept-Ranges", "bytes"),
                "Cache-Control": "no-store",
            }

            for header_name in ("Content-Length", "Content-Range", "ETag", "Last-Modified"):
                value = upstream.headers.get(header_name)
                if value:
                    response_headers[header_name] = value

            status = upstream.status_code
            print(
                "VIDEO PROXY OK:",
                video_id,
                host,
                "status=",
                status,
                "length=",
                upstream.headers.get("Content-Length", "unknown"),
                flush=True,
            )

            def generate():
                try:
                    for chunk in upstream.iter_content(chunk_size=64 * 1024):
                        if chunk:
                            yield chunk
                finally:
                    upstream.close()

            return Response(
                generate(),
                status=status,
                headers=response_headers,
                direct_passthrough=True,
            )

        except Exception as e:
            print(
                "VIDEO PROXY ERROR:",
                video_id,
                host,
                repr(e),
                flush=True,
            )
            if upstream is not None:
                try:
                    upstream.close()
                except Exception:
                    pass

    print("VIDEO PROXY EXHAUSTED:", video_id, "falling back to upstream yt-dlp", flush=True)
    return None

'''

s = s.replace(route_anchor, helper + route_anchor, 1)

body_anchor = '''def getvideo(video_id, res=None):
    if video_id == "login_prompt":
        return "This isn't a real video — check its description for the login link.", 200
'''
body_replacement = '''def getvideo(video_id, res=None):
    # YouTube IDs contain only A-Z, a-z, 0-9, "_" and "-".
    # Strip accidental shell/URL escaping (notably a trailing backslash)
    # before using the ID in filenames or redirects.
    video_id = re.sub(r"[^A-Za-z0-9_-]", "", video_id)

    if video_id == "login_prompt":
        return "This isn't a real video — check its description for the login link.", 200

    proxied = _proxy_invidious_video(video_id)
    if proxied is not None:
        return proxied
'''

if body_anchor not in s:
    raise SystemExit("Could not find getvideo function body anchor")

s = s.replace(body_anchor, body_replacement, 1)
p.write_text(s)
print("Installed server-only Invidious video proxy fallback")
