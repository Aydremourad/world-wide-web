from pathlib import Path

# Keep the upstream TubeRepair feed/templates untouched. We only patch
# deployment/runtime infrastructure and server-side YouTube/Invidious access.

root = Path("/app/modified-tuberepair/tuberepair")
video_path = root / "api" / "video.py"
get_path = root / "modules" / "get.py"
static_path = root / "api" / "static.py"
main_path = root / "main.py"

# 1) Remove upstream's import-time MrBeast network probe so Render can bind
#    promptly even if an external metadata service is slow.
video_text = video_path.read_text()
probe = '''print(
    "TEST CHANNEL ID:",
    get_channel_id_from_name("MrBeast")
)

'''
if probe not in video_text:
    raise SystemExit("Expected upstream TEST CHANNEL ID block not found")
video_text = video_text.replace(probe, "", 1)

# 2) Route the direct Invidious calls in video.py through our failover helper.
old_related = '''        r = requests.get(
            f"{config.URL}/api/v1/videos/{video_id}",
            timeout=10
        )

        data = r.json()
'''
new_related = '''        data = get.fetch_api(f"/api/v1/videos/{video_id}") or {}
'''
if old_related not in video_text:
    raise SystemExit("Related-video direct Invidious request anchor not found")
video_text = video_text.replace(old_related, new_related, 1)

old_channel_name = '''        r = requests.get(
            f"{config.URL}/api/v1/channels/{channel_id}",
            timeout=10,
        )
        print("GET_CHANNEL_NAME_FROM_ID status:", channel_id, r.status_code, flush=True)
        if not r.ok:
            print("GET_CHANNEL_NAME_FROM_ID body:", r.text[:300], flush=True)
            return None
        data = r.json()
'''
new_channel_name = '''        data = get.fetch_api(f"/api/v1/channels/{channel_id}") or {}
        print("GET_CHANNEL_NAME_FROM_ID fetched:", channel_id, bool(data), flush=True)
        if not data or data.get("error"):
            return None
'''
if old_channel_name not in video_text:
    raise SystemExit("Channel-name direct Invidious request anchor not found")
video_text = video_text.replace(old_channel_name, new_channel_name, 1)

old_channel_id = '''        r = requests.get(
            f"{config.URL}/api/v1/search",
            params={
                "q": name,
                "type": "channel"
            },
            timeout=10
        )

        data = r.json()
'''
new_channel_id = '''        data = get.fetch_api(
            "/api/v1/search",
            params={
                "q": name,
                "type": "channel"
            }
        ) or []
'''
if old_channel_id not in video_text:
    raise SystemExit("Channel-ID direct Invidious request anchor not found")
video_text = video_text.replace(old_channel_id, new_channel_id, 1)

old_search = '''        r = requests.get(
            f"{config.URL}/api/v1/search",
            params={
                "q": raw_search_keyword,
                "type": "video",
                "page": invidious_page
            },
            headers={
                "User-Agent": "Mozilla/5.0",
                "Accept": "application/json"
            },
            timeout=10
        )

        r.raise_for_status()
        json_data = r.json()
'''
new_search = '''        json_data = get.fetch_api(
            "/api/v1/search",
            params={
                "q": raw_search_keyword,
                "type": "video",
                "page": invidious_page
            }
        ) or []

        if not isinstance(json_data, list) or not json_data:
            print("INVIDIOUS SEARCH POOL FAILED; USING YT-DLP SEARCH", flush=True)
            result = subprocess.run(
                [
                    "yt-dlp",
                    "--flat-playlist",
                    "--dump-json",
                    "--ignore-errors",
                    "--no-warnings",
                    f"ytsearch20:{raw_search_keyword}",
                ],
                capture_output=True,
                text=True,
                timeout=60,
            )

            fallback_items = []
            for line in result.stdout.splitlines():
                try:
                    info = json.loads(line)
                except Exception:
                    continue

                vid_id = info.get("id") or info.get("videoId")
                if not vid_id:
                    continue

                fallback_items.append({
                    "type": "video",
                    "title": info.get("title") or "Untitled",
                    "videoId": vid_id,
                    "author": info.get("uploader") or info.get("channel") or "Unknown",
                    "authorId": info.get("uploader_id") or info.get("channel_id") or "unknown",
                    "lengthSeconds": int(info.get("duration") or 0),
                    "viewCount": int(info.get("view_count") or 0),
                    "published": int(info.get("timestamp") or 0),
                    "description": info.get("description") or "",
                })

            json_data = fallback_items
            print("YT-DLP SEARCH COUNT:", len(json_data), flush=True)
'''
if old_search not in video_text:
    raise SystemExit("Search direct Invidious request anchor not found")
video_text = video_text.replace(old_search, new_search, 1)

old_playlist = '''    url = f"{config.URL}/api/v1/playlists/{playlist_id}"

    try:
        r = requests.get(url, timeout=10, headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "application/json"
        })

        print("PLAYLIST URL:", url)
        print("STATUS:", r.status_code)
        print("TEXT:", r.text[:500])

        if not r.text.strip():
            raise Exception("Invidious returned blank playlist")

        playlist = r.json()
'''
new_playlist = '''    try:
        playlist = get.fetch_api(f"/api/v1/playlists/{playlist_id}") or {}
        print("PLAYLIST FAILOVER RESULT:", playlist_id, bool(playlist), flush=True)
        if not playlist or playlist.get("error"):
            raise Exception("All Invidious instances failed playlist lookup")
'''
if old_playlist not in video_text:
    raise SystemExit("Playlist direct Invidious request anchor not found")
video_text = video_text.replace(old_playlist, new_playlist, 1)

featured_anchor = '''        entries = get_playlist_from_invidious(fallback_playlist_id)

    random.shuffle(entries)
'''
featured_replacement = '''        entries = get_playlist_from_invidious(fallback_playlist_id)

    if not entries:
        print("INVIDIOUS PLAYLIST POOL FAILED; USING YT-DLP FEATURED FALLBACK", flush=True)
        result = subprocess.run(
            [
                "yt-dlp",
                "--flat-playlist",
                "--dump-json",
                "--ignore-errors",
                "--no-warnings",
                "--playlist-end", "30",
                playlist_url,
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        entries = []
        for line in result.stdout.splitlines():
            try:
                entries.append(json.loads(line))
            except Exception:
                pass
        print("YT-DLP FEATURED COUNT:", len(entries), flush=True)

    random.shuffle(entries)
'''
if featured_anchor not in video_text:
    raise SystemExit("Featured fallback anchor not found")
video_text = video_text.replace(featured_anchor, featured_replacement, 1)


# 2b) Add an asynchronous preparation endpoint for iOS 3. The stock
# MPMoviePlayerController initializer blocks while probing a remote URL, so
# feeding it /getvideo/<id> freezes YouTube while yt-dlp/ffmpeg are still
# working. /prepare/<id> starts the existing conversion in a daemon thread
# and returns immediately; the phone only opens /static/<id>.mp4 once ready.
prepare_anchor = '''@video.route("/feeds/api/videos/<video_id>/related")
'''
prepare_code = r'''
_prepare_states = {}
_prepare_states_lock = threading.Lock()

def _prepare_video_worker(video_id):
    print("PREPARE VIDEO WORKER START:", video_id, flush=True)
    try:
        # Reuse the exact existing conversion/cache path. This function does
        # not depend on request data and is protected by the same per-video
        # lock and global download semaphore as normal playback.
        getvideo(video_id)

        ready_path = f"static/{video_id}.mp4"
        ready = os.path.exists(ready_path) and os.path.getsize(ready_path) > 0

        with _prepare_states_lock:
            _prepare_states[video_id] = "ready" if ready else "error"

        print("PREPARE VIDEO WORKER END:", video_id, "ready=", ready, flush=True)
    except Exception as e:
        with _prepare_states_lock:
            _prepare_states[video_id] = "error"
        print("PREPARE VIDEO WORKER ERROR:", video_id, repr(e), flush=True)

@video.route("/prepare/<video_id>")
def prepare_video(video_id):
    if video_id == "login_prompt":
        return Response(
            json.dumps({"status": "error"}),
            status=400,
            mimetype="application/json",
        )

    ready_path = f"static/{video_id}.mp4"
    if os.path.exists(ready_path) and os.path.getsize(ready_path) > 0:
        with _prepare_states_lock:
            _prepare_states[video_id] = "ready"
        return Response(
            json.dumps({
                "status": "ready",
                "url": f"/static/{video_id}.mp4",
            }),
            mimetype="application/json",
        )

    with _prepare_states_lock:
        state = _prepare_states.get(video_id)
        if state != "preparing":
            _prepare_states[video_id] = "preparing"
            threading.Thread(
                target=_prepare_video_worker,
                args=(video_id,),
                daemon=True,
            ).start()
            state = "preparing"

    status_code = 202 if state == "preparing" else 500
    return Response(
        json.dumps({"status": state or "preparing"}),
        status=status_code,
        mimetype="application/json",
    )

'''
if prepare_anchor not in video_text:
    raise SystemExit("Prepare route insertion anchor not found")
video_text = video_text.replace(prepare_anchor, prepare_code + prepare_anchor, 1)

video_path.write_text(video_text)
print("Patched video.py backend access only; feed XML remains exact upstream")

# 3) Replace get.fetch() with resilient instance failover. Existing callers
#    can keep constructing URLs using config.URL; only the path/query is used.
get_text = get_path.read_text()
if "from modules import invidious_failover" not in get_text:
    get_text = get_text.replace(
        "from modules import helpers\n",
        "from modules import helpers\nfrom modules import invidious_failover\n",
        1
    )

fetch_start = get_text.find("# simplify requests")
fetch_end = get_text.find("# If error logging is enable")
if fetch_start < 0 or fetch_end < 0 or fetch_end <= fetch_start:
    raise SystemExit("Could not locate upstream get.fetch block")

new_fetch_block = '''# simplify requests
def fetch(url):
    data = invidious_failover.fetch_url(
        url,
        session=session,
        proxies=helpers.proxies,
        timeout=5,
    )
    if data is None:
        print_with_seperator('ALL INVIDIOUS INSTANCES FAILED!', 'red')
    return data

def fetch_api(path, params=None):
    return invidious_failover.fetch_path(
        path,
        params=params,
        session=session,
        proxies=helpers.proxies,
        timeout=5,
    )

'''
get_text = get_text[:fetch_start] + new_fetch_block + get_text[fetch_end:]
get_path.write_text(get_text)
print("Installed Invidious failover in modules/get.py")

# 4) Render health route.
static_text = static_path.read_text()
if '@static.route("/healthz")' not in static_text:
    static_text += '''

@static.route("/healthz")
def render_healthz():
    return "ok", 200
'''
    static_path.write_text(static_text)
print("Ensured /healthz route exists")

# 5) Terse request tracing, useful for confirming whether a tap reaches Render.
main_text = main_path.read_text()
if "IPHONE REQUEST:" not in main_text:
    anchor = 'app = Flask(__name__)\n'
    if anchor not in main_text:
        raise SystemExit("Expected Flask app creation anchor not found")
    main_text = main_text.replace(
        anchor,
        '''app = Flask(__name__)

@app.before_request
def _log_request_path():
    from flask import request
    print("IPHONE REQUEST:", request.method, request.path, flush=True)
''',
        1,
    )
    main_path.write_text(main_text)
print("Enabled request-path tracing")
