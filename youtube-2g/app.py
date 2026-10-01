"""Stock iPhone OS 3 TubeRepair backend; GPL-3.0, see NOTICE.md."""
import concurrent.futures
import functools
import json
import logging
import plistlib
from urllib.parse import urlsplit
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from flask import Flask, Response, abort, jsonify, render_template, request, send_file
from jinja2 import Environment, FileSystemLoader, select_autoescape

ROOT = Path(__file__).resolve().parent
STATE = Path(os.environ.get('STATE_DIR', str(ROOT / 'state')))
STATE.mkdir(parents=True, exist_ok=True)
MEDIA = STATE / 'media'
MEDIA.mkdir(exist_ok=True)
VIDEO_ID = re.compile(r'^[A-Za-z0-9_-]{11}$')
MAX_SECONDS = int(os.environ.get('MAX_VIDEO_SECONDS', '1200'))
MAX_CACHE_BYTES = int(os.environ.get('MAX_CACHE_BYTES', str(1024 * 1024 * 1024)))
app = Flask(__name__, static_folder=str(ROOT / 'static'))
app.config['MAX_CONTENT_LENGTH'] = 128 * 1024
env = Environment(loader=FileSystemLoader(ROOT / 'templates'), autoescape=select_autoescape(default=True))
log = logging.getLogger('youtube2g')
logging.basicConfig(level=logging.INFO)
metadata_lock = threading.Lock()
metadata_cache = {}
jobs_lock = threading.Lock()
jobs = {}
worker = concurrent.futures.ThreadPoolExecutor(max_workers=1)


def validate(video_id):
    if not VIDEO_ID.fullmatch(video_id):
        abort(404)
    return video_id


def base_url():
    # Render terminates HTTPS before forwarding HTTP to the container.
    return (os.environ.get('PUBLIC_BASE_URL') or
            os.environ.get('RENDER_EXTERNAL_URL') or request.url_root).rstrip('/')


def run_ytdlp(args, timeout=90):
    # No shell, arbitrary URLs, credentials, or external Invidious dependencies.
    cmd = [sys.executable, '-m', 'yt_dlp', '--ignore-config', '--no-warnings',
           '--no-playlist', '--socket-timeout', '15', '--retries', '1',
           '--extractor-retries', '1', *args]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr[-1200:] or 'YouTube request failed')
    return result.stdout


def normalize(item):
    vid = item.get('id', '')
    if not VIDEO_ID.fullmatch(vid):
        return None
    published = item.get('timestamp') or item.get('release_timestamp')
    if not published and item.get('upload_date'):
        try:
            published = datetime.strptime(item['upload_date'], '%Y%m%d').replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            pass
    return dict(videoId=vid, title=item.get('title') or vid,
                author=item.get('channel') or item.get('uploader') or 'YouTube',
                authorId=item.get('channel_id') or 'unknown',
                description=item.get('description') or '', published=published or 0,
                lengthSeconds=int(item.get('duration') or 0),
                viewCount=min(int(item.get('view_count') or 0), 2147483647))


def cached(key, fetch, ttl=600):
    with metadata_lock:
        record = metadata_cache.get(key)
        if record and time.monotonic() - record[0] < ttl:
            return record[1]
    value = fetch()
    with metadata_lock:
        if len(metadata_cache) >= 256:
            metadata_cache.pop(next(iter(metadata_cache)))
        metadata_cache[key] = (time.monotonic(), value)
    return value


def info(vid):
    validate(vid)
    def fetch():
        item = json.loads(run_ytdlp(['--skip-download', '--dump-single-json',
                                    'https://www.youtube.com/watch?v=' + vid]))
        if item.get('is_live'):
            raise RuntimeError('Live streams are not supported')
        return normalize(item)
    return cached('video:' + vid, fetch, 3600)


def search(query, count=15, start=1):
    query = query.strip()[:160]
    count = min(max(count, 1), 25)
    start = min(max(start, 1), 76)
    def fetch():
        raw = run_ytdlp(['--flat-playlist', '--skip-download', '--dump-single-json',
                         'ytsearch' + str(start + count - 1) + ':' + query])
        items = json.loads(raw).get('entries') or []
        return [v for item in items[start - 1:start + count - 1]
                if (v := normalize(item))]
    return cached(f'search:{query}:{start}:{count}', fetch)


def unix(value):
    return datetime.fromtimestamp(float(value or 0), timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def feed(data, template='classic/search.jinja2'):
    xml = env.get_template(template).render(data=data, unix=unix, url=base_url(), next_page=None)
    return Response(xml, mimetype='application/atom+xml')


@app.after_request
def response_headers(response):
    # Prevent a player or intermediary from caching a preparing/error clip as the video.
    if not request.path.startswith('/thumb/'):
        response.headers['Cache-Control'] = 'no-store'
    return response


@app.get('/')
def home():
    return render_template('home.html', server_url=base_url(), max_minutes=MAX_SECONDS // 60)


@app.get('/setup/com.apple.youtubeframework.plist')
def phone_preferences():
    # The same preference key set by the open-source TubeRepair client.
    host = urlsplit(base_url()).netloc
    data = plistlib.dumps({'ConfiguredServiceHost': host}, fmt=plistlib.FMT_XML)
    response = Response(data, mimetype='application/octet-stream')
    response.headers['Content-Disposition'] = 'attachment; filename=com.apple.youtubeframework.plist'
    return response


@app.get('/healthz')
def health():
    return jsonify(status='ok', version='2g-1.0-rc1')


@app.get('/feeds/api/videos')
@app.get('/feeds/api/videos/')
def video_search():
    try:
        data = search(request.args.get('q') or 'recent videos',
                      min(int(request.args.get('max-results', 15)), 25),
                      int(request.args.get('start-index', 1)))
        return feed(data)
    except (RuntimeError, subprocess.TimeoutExpired, ValueError) as exc:
        log.warning('Search unavailable: %s', exc)
        return feed([]), 503


@app.get('/feeds/api/standardfeeds/<popular>')
@app.get('/feeds/api/standardfeeds/<region>/<popular>')
def frontpage(popular, region='US'):
    # Search-backed browsing; these are not the defunct official rankings.
    query = {'most_viewed': 'popular music videos', 'top_rated': 'popular videos',
             'most_recent': 'recent videos', 'recently_featured': 'science technology music'}.get(popular, 'popular videos')
    try:
        return feed(search(query), 'classic/featured.jinja2')
    except (RuntimeError, subprocess.TimeoutExpired):
        return feed([], 'classic/featured.jinja2'), 503


@app.get('/feeds/api/videos/<vid>')
def single(vid):
    return feed([info(vid)], 'batch_videos.jinja2')


@app.route('/feeds/api/videos/batch', methods=['POST', 'GET'])
def batch():
    text = request.get_data(as_text=True) + ' ' + request.query_string.decode(errors='replace')
    # Extract IDs only; never fetch arbitrary URLs supplied by a caller.
    ids = list(dict.fromkeys(re.findall(r'(?:videos/|video:)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])', text)))[:15]
    items = []
    for vid in ids:
        try:
            items.append(info(vid))
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
    return feed(items, 'batch_videos.jinja2')


@app.get('/feeds/api/videos/<vid>/related')
def related(vid):
    item = info(vid)
    return feed(search(item['title'][:100]))


@app.get('/feeds/api/users/<channel>/uploads')
def uploads(channel):
    if not re.fullmatch(r'UC[A-Za-z0-9_-]{22}', channel):
        return feed([])
    try:
        raw = run_ytdlp(['--flat-playlist', '--playlist-end', '15', '--skip-download',
                         '--dump-single-json', 'https://www.youtube.com/channel/' + channel + '/videos'])
        return feed([v for i in json.loads(raw).get('entries', []) if (v := normalize(i))])
    except (RuntimeError, subprocess.TimeoutExpired):
        return feed([]), 503


@app.get('/feeds/api/users/<channel>/<kind>')
def local_only_feeds(channel, kind):
    # Authentication, cloud subscriptions, and cloud playlists aren't implemented.
    return feed([])


@app.get('/feeds/api/videos/<vid>/comments')
@app.get('/api/videos/<vid>/comments')
def comments(vid):
    validate(vid)
    return Response('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Comments</title></feed>', mimetype='application/atom+xml')


@app.post('/youtube/accounts/applelogin1')
def applelogin1():
    return Response('r2=legacy\nhmackr2=legacy', mimetype='text/plain')


@app.post('/youtube/accounts/applelogin2')
def applelogin2():
    return Response('Auth=legacy', mimetype='text/plain')


@app.get('/schemas/2007/categories.cat')
def categories():
    return send_file(ROOT / 'static' / 'categories.cat', mimetype='application/xml')


@app.get('/thumb/<vid>')
def thumbnail(vid):
    validate(vid)
    try:
        with urllib.request.urlopen('https://i.ytimg.com/vi/' + vid + '/default.jpg', timeout=12) as upstream:
            data = upstream.read(256 * 1024)
        response = Response(data, mimetype='image/jpeg')
        response.headers['Cache-Control'] = 'public, max-age=3600'
        return response
    except OSError:
        abort(502)


def ffmpeg_args(source, destination):
    return ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source),
            '-map', '0:v:0', '-map', '0:a:0?', '-vf',
            'scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2,setsar=1',
            '-r', '24', '-c:v', 'libx264', '-threads', '1', '-preset', 'ultrafast',
            '-profile:v', 'baseline', '-level:v', '3.0', '-pix_fmt', 'yuv420p',
            '-b:v', '400k', '-maxrate', '600k', '-bufsize', '1200k',
            '-c:a', 'aac', '-profile:a', 'aac_low', '-b:a', '80k', '-ar', '44100', '-ac', '2',
            '-movflags', '+faststart', str(destination)]


def prune_cache():
    files = sorted(MEDIA.glob('*.mp4'), key=lambda p: p.stat().st_mtime)
    total = sum(p.stat().st_size for p in files)
    for path in files:
        if total <= MAX_CACHE_BYTES and time.time() - path.stat().st_mtime < 86400:
            continue
        size = path.stat().st_size
        path.unlink(missing_ok=True)
        total -= size


def convert(vid):
    import tempfile
    try:
        item = info(vid)
        if item['lengthSeconds'] > MAX_SECONDS:
            raise ValueError('too-long')
        with tempfile.TemporaryDirectory(prefix='source-', dir=STATE) as work:
            source = Path(work) / 'source.mp4'
            run_ytdlp(['-f', 'best[height<=360]/bestvideo[height<=360]+bestaudio/best[height<=480]',
                       '--merge-output-format', 'mp4', '--max-filesize', '200M',
                       '--match-filters', f'!is_live & duration <= {MAX_SECONDS}',
                       '-o', str(source), 'https://www.youtube.com/watch?v=' + vid], timeout=600)
            if not source.exists():
                raise RuntimeError('Video exceeds source limit or is unavailable')
            output = Path(work) / 'converted.mp4'
            subprocess.run(ffmpeg_args(source, output), check=True, capture_output=True, timeout=600)
            if not output.exists() or output.stat().st_size < 1000:
                raise RuntimeError('Empty converted video')
            prune_cache()
            output.replace(MEDIA / (vid + '.mp4'))
        with jobs_lock:
            jobs[vid] = ('ready', time.monotonic())
    except Exception as exc:
        log.warning('Conversion failed for %s: %s', vid, exc)
        with jobs_lock:
            jobs[vid] = ('too-long' if str(exc) == 'too-long' else 'failed', time.monotonic())


def schedule(vid):
    with jobs_lock:
        record = jobs.get(vid)
        if record and (record[0] in ('preparing', 'queued') or time.monotonic() - record[1] < 120):
            return record[0]
        if sum(s[0] in ('preparing', 'queued') for s in jobs.values()) >= 3:
            return 'busy'
        for key in list(jobs):
            if jobs[key][0] not in ('preparing', 'queued') and time.monotonic() - jobs[key][1] > 3600:
                del jobs[key]
        jobs[vid] = ('preparing', time.monotonic())
        worker.submit(convert, vid)
        return 'preparing'


@app.route('/getvideo/<vid>', methods=['GET', 'HEAD'])
@app.route('/video/sd/<vid>', methods=['GET', 'HEAD'])
@app.route('/video/hd/<vid>', methods=['GET', 'HEAD'])
def playback(vid):
    validate(vid)
    path = MEDIA / (vid + '.mp4')
    if path.exists():
        os.utime(path, None)
        return send_file(path, mimetype='video/mp4', conditional=True)
    status = schedule(vid)
    # Return promptly. The original player has no progress/polling protocol.
    # A new tap after preparation serves the complete MP4 with byte-range support.
    clip = {'failed': 'failed', 'too-long': 'too-long', 'busy': 'busy'}.get(status, 'preparing')
    return send_file(ROOT / 'static' / (clip + '.mp4'), mimetype='video/mp4', conditional=True)


@app.get('/status/<vid>')
def status(vid):
    validate(vid)
    with jobs_lock:
        state = jobs.get(vid, ('not-requested', 0))[0]
    return jsonify(status='ready' if (MEDIA / (vid + '.mp4')).exists() else state)


@app.get('/test.mp4')
def test_clip():
    return send_file(ROOT / 'static' / 'test.mp4', mimetype='video/mp4', conditional=True)


@app.errorhandler(500)
def error500(exc):
    return Response('YouTube is unavailable. Try another video or check the server logs.', status=502)


if __name__ == '__main__':
    from waitress import serve
    serve(app, host='0.0.0.0', port=int(os.environ.get('PORT', '2000')),
          threads=int(os.environ.get('SERVER_THREADS', '8')))
