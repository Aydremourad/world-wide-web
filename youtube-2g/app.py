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
import shutil
import tempfile
import sys
import threading
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from flask import Flask, Response, abort, jsonify, redirect, render_template, request, send_file
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
downloads = threading.BoundedSemaphore(1)
job_errors = {}
playback_waiters = threading.BoundedSemaphore(2)
STREAM_TEST_ID = 'STREAMTEST1'
PLAYBACK_TEST_ID = 'MP4TEST0002'
LOCAL_TEST_IDS = {PLAYBACK_TEST_ID, STREAM_TEST_ID}
PLAYBACK_TEST_ITEM = dict(videoId=PLAYBACK_TEST_ID, title='Playback test',
    author='YouTube 2G', authorId='unknown', description='A local playback test.',
    published=0, lengthSeconds=8, viewCount=0)
VERSION = '2g-1.3'


def media_ready(vid):
    if vid in LOCAL_TEST_IDS:
        return (ROOT / 'static' / 'test.mp4').is_file()
    return (MEDIA / (vid + '.mp4')).is_file()


class DownloadError(RuntimeError):
    def __init__(self, message):
        super().__init__(message)
        lower = message.lower()
        self.code = ('youtube-bot-check' if 'confirm' in lower and 'bot' in lower else
                     'cookies-expired' if 'cookies' in lower and ('expired' in lower or 'no longer valid' in lower) else
                     'youtube-forbidden' if '403' in lower else
                     'no-playable-format' if 'requested format' in lower else
                     'download-failed')


def validate(video_id):
    if not VIDEO_ID.fullmatch(video_id):
        abort(404)
    return video_id


def base_url():
    # Render terminates HTTPS before forwarding HTTP to the container.
    return (os.environ.get('PUBLIC_BASE_URL') or
            os.environ.get('RENDER_EXTERNAL_URL') or request.url_root).rstrip('/')


def run_ytdlp(args, timeout=90):
    # Credentials are read only from a private, operator-managed secret file.
    cmd = [sys.executable, '-m', 'yt_dlp', '--ignore-config', '--no-warnings',
           '--no-playlist', '--socket-timeout', '15', '--retries', '1',
           '--extractor-retries', '1']
    if os.environ.get('YOUTUBE_POT_ENABLED') == '1':
        cmd += ['--extractor-args', 'youtube:player_client=mweb,web_embedded',
                '--extractor-args', 'youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416']
    cmd += args
    configured = os.environ.get('YOUTUBE_COOKIES_FILE')
    secret = Path(configured or '/etc/secrets/youtube-cookies.txt')
    if configured and not secret.is_file():
        raise RuntimeError('Configured YouTube cookie file is missing')
    # yt-dlp writes its cookie jar. Give each request its own writable copy,
    # leaving the mounted secret untouched and deleting the copy on all exits.
    with tempfile.TemporaryDirectory(prefix='cookies-', dir=STATE) as work:
        if secret.is_file():
            jar = Path(work) / 'cookies.txt'
            shutil.copyfile(secret, jar)
            jar.chmod(0o600)
            cmd[4:4] = ['--cookies', str(jar)]
        with downloads:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise DownloadError(result.stderr[-1200:] or 'YouTube request failed')
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
    if vid in LOCAL_TEST_IDS:
        return {**PLAYBACK_TEST_ITEM, 'videoId': vid}
    def fetch():
        item = json.loads(run_ytdlp(['--skip-download', '--dump-single-json',
                                    'https://www.youtube.com/watch?v=' + vid]))
        if item.get('is_live'):
            raise RuntimeError('Live streams are not supported')
        return normalize(item)
    return cached('video:' + vid, fetch, 3600)


def search(query, count=15, start=1):
    query = query.strip()[:160]
    if query.lower() in ('playback test', 'stock test', 'stream test', 'streaming test'):
        return [dict(PLAYBACK_TEST_ITEM)]
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
    warm_results(data)
    return Response(xml, mimetype='application/atom+xml')


def warm_results(data):
    # Only speculate on the top short result, and only while the queue is idle.
    # Do not download every visible video or fill the queue ahead of a selection.
    limit = min(int(os.environ.get('PREFETCH_SECONDS', '60')), MAX_SECONDS)
    if data and limit > 0:
        first = data[0]
        if first['videoId'] not in LOCAL_TEST_IDS and 0 < first.get('lengthSeconds', 0) <= limit:
            schedule(first['videoId'], hint=first, prefetch=True)


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
    return jsonify(status='ok', version=VERSION)


@app.get('/diagnostics')
def diagnostics():
    from importlib.metadata import version
    provider = False
    if os.environ.get('YOUTUBE_POT_ENABLED') == '1':
        try:
            with urllib.request.urlopen('http://127.0.0.1:4416/ping', timeout=1) as r:
                provider = r.status == 200
        except OSError:
            pass
    secret = Path(os.environ.get('YOUTUBE_COOKIES_FILE') or '/etc/secrets/youtube-cookies.txt')
    # Only readiness flags and versions; no tokens, file contents, or account data.
    return jsonify(version=VERSION, downloader=version('yt-dlp'),
                   token_provider_ready=provider, cookies_loaded=secret.is_file(),
                   playback_mode='mp4')


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
    item = info(vid)
    if vid not in LOCAL_TEST_IDS:
        schedule(vid, hint=item)
    return feed([item], 'batch_videos.jinja2')


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
    if vid in LOCAL_TEST_IDS:
        return send_file(ROOT / 'static' / 'playback-test.jpg', mimetype='image/jpeg')
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
    files = list(MEDIA.glob('*.mp4'))
    sizes = {p: p.stat().st_size for p in files}
    files.sort(key=lambda p: p.stat().st_mtime)
    total = sum(sizes.values())
    with jobs_lock:
        active = {vid for vid, record in jobs.items() if record[0] in ('preparing', 'queued')}
    for path in files:
        if path.stem in active:
            continue
        if total <= MAX_CACHE_BYTES and time.time() - path.stat().st_mtime < 86400:
            continue
        path.unlink(missing_ok=True)
        total -= sizes[path]


def convert(vid, hint=None):
    import tempfile
    try:
        item = hint or info(vid)
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
            prune_cache()
            output = Path(work) / 'converted.mp4'
            subprocess.run(ffmpeg_args(source, output), check=True, capture_output=True, timeout=600)
            if not output.exists() or output.stat().st_size < 1000:
                raise RuntimeError('Empty converted video')
            output.replace(MEDIA / (vid + '.mp4'))
        with jobs_lock:
            jobs[vid] = ('ready', time.monotonic())
            job_errors.pop(vid, None)
    except Exception as exc:
        log.warning('Conversion failed for %s: %s', vid, exc)
        with jobs_lock:
            jobs[vid] = ('too-long' if str(exc) == 'too-long' else 'failed', time.monotonic())
            job_errors[vid] = (exc.code if isinstance(exc, DownloadError) else
                               'timeout' if isinstance(exc, subprocess.TimeoutExpired) else
                               'conversion-failed' if isinstance(exc, subprocess.CalledProcessError) else
                               'too-long' if str(exc) == 'too-long' else 'download-failed')


def schedule(vid, hint=None, prefetch=False):
    with jobs_lock:
        if media_ready(vid):
            return 'ready'
        record = jobs.get(vid)
        if record and (record[0] in ('preparing', 'queued') or
                       (record[0] != 'ready' and time.monotonic() - record[1] < 120)):
            return record[0]
        if prefetch and any(s[0] in ('preparing', 'queued') for s in jobs.values()):
            return 'busy'
        if sum(s[0] in ('preparing', 'queued') for s in jobs.values()) >= 3:
            return 'busy'
        for key in list(jobs):
            if jobs[key][0] not in ('preparing', 'queued') and time.monotonic() - jobs[key][1] > 3600:
                del jobs[key]
                job_errors.pop(key, None)
        jobs[vid] = ('preparing', time.monotonic())
        job_errors.pop(vid, None)
        worker.submit(convert, vid, hint)
        return 'preparing'


@app.route('/getvideo/<vid>', methods=['GET', 'HEAD'])
@app.route('/video/sd/<vid>', methods=['GET', 'HEAD'])
@app.route('/video/hd/<vid>', methods=['GET', 'HEAD'])
def playback(vid):
    validate(vid)
    # The stock OS 3 player rejected HLS even after its server error was fixed.
    # Both sample IDs serve the exact known-compatible MP4, without a redirect.
    # PLAYBACK_MODE=hls from an earlier deployment is intentionally ignored.
    if vid in LOCAL_TEST_IDS:
        return send_file(ROOT / 'static' / 'test.mp4', mimetype='video/mp4', conditional=True)
    path = MEDIA / (vid + '.mp4')
    if path.exists():
        os.utime(path, None)
        return send_file(path, mimetype='video/mp4', conditional=True)
    status = schedule(vid)
    # Allow short jobs to finish under the normal loading spinner. Limit waiters
    # so health checks and feeds retain server threads, and retain the old fallback.
    wait = min(max(float(os.environ.get('PLAYBACK_WAIT_SECONDS', '8')), 0), 15)
    if request.method == 'GET' and status in ('preparing', 'queued') and wait and playback_waiters.acquire(False):
        try:
            deadline = time.monotonic() + wait
            while time.monotonic() < deadline and not media_ready(vid):
                with jobs_lock:
                    status = jobs.get(vid, ('preparing', 0))[0]
                if status in ('failed', 'too-long'):
                    break
                time.sleep(0.1)
        finally:
            playback_waiters.release()
    if media_ready(vid):
        os.utime(path, None)
        return send_file(path, mimetype='video/mp4', conditional=True)
    clip = {'failed': 'failed', 'too-long': 'too-long', 'busy': 'busy'}.get(status, 'preparing')
    return send_file(ROOT / 'static' / (clip + '.mp4'), mimetype='video/mp4', conditional=True)


@app.route('/stream-test/index.m3u8', methods=['GET', 'HEAD'])
def retired_stream_test():
    # Recover saved Safari links to the retired experiment.
    return redirect('/test.mp4')


@app.get('/status/<vid>')
def status(vid):
    validate(vid)
    with jobs_lock:
        state = jobs.get(vid, ('not-requested', 0))[0]
        code = job_errors.get(vid)
    result = dict(status='ready' if media_ready(vid) else state)
    if code and result['status'] == 'failed':
        result['error'] = code
    return jsonify(result)


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
