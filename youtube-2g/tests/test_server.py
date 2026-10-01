import importlib.util
import json
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path
import pytest

spec = importlib.util.spec_from_file_location('server', Path(__file__).parents[1] / 'app.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
VID='abcdefghijk'

def test_private_cookie_copy_cleanup(client, monkeypatch, tmp_path):
    secret = tmp_path / 'secret.txt'
    secret.write_text('# Netscape HTTP Cookie File\n')
    monkeypatch.setenv('YOUTUBE_COOKIES_FILE', str(secret))
    copies = []
    def run(cmd, **kwargs):
        jar = Path(cmd[cmd.index('--cookies') + 1])
        copies.append(jar)
        assert jar != secret and jar.read_text() == secret.read_text()
        assert jar.stat().st_mode & 0o777 == 0o600
        jar.write_text('changed by downloader')
        return subprocess.CompletedProcess(cmd, 0, 'ok', '')
    monkeypatch.setattr(s.subprocess, 'run', run)
    assert s.run_ytdlp(['--skip-download', 'https://www.youtube.com/watch?v='+VID]) == 'ok'
    assert not copies[0].exists()
    assert secret.read_text() == '# Netscape HTTP Cookie File\n'

def test_cookie_copy_cleanup_on_timeout(client, monkeypatch, tmp_path):
    secret = tmp_path / 'secret.txt'; secret.write_text('# Netscape HTTP Cookie File\n')
    monkeypatch.setenv('YOUTUBE_COOKIES_FILE', str(secret))
    copies = []
    def run(cmd, **kwargs):
        copies.append(Path(cmd[cmd.index('--cookies')+1]))
        raise subprocess.TimeoutExpired(cmd, 1)
    monkeypatch.setattr(s.subprocess, 'run', run)
    with pytest.raises(subprocess.TimeoutExpired): s.run_ytdlp([])
    assert not copies[0].exists()
ITEM=dict(videoId=VID,title='A & B <test> "quotes"',author='Name & Name',authorId='unknown',description='Text <tag> & symbols',published=0,lengthSeconds=12,viewCount=123)

@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.delenv('PUBLIC_BASE_URL', raising=False)
    monkeypatch.delenv('RENDER_EXTERNAL_URL', raising=False)
    monkeypatch.delenv('PLAYBACK_MODE', raising=False)
    monkeypatch.setenv('PREFETCH_SECONDS', '0')
    monkeypatch.setenv('PLAYBACK_WAIT_SECONDS', '0')
    monkeypatch.setattr(s, 'MEDIA', tmp_path)
    monkeypatch.setattr(s, 'STATE', tmp_path)
    monkeypatch.setattr(s, 'HLS', tmp_path / 'hls')
    s.HLS.mkdir()
    s.jobs.clear()
    s.job_errors.clear()
    s.metadata_cache.clear()
    return s.app.test_client()

def test_public_failure_status_does_not_expose_credentials(client, monkeypatch):
    monkeypatch.setattr(s, 'info', lambda v: (_ for _ in ()).throw(
        s.DownloadError('ERROR: Sign in to confirm you are not a bot; cookie-secret-value')))
    s.convert(VID)
    r = client.get('/status/' + VID)
    assert r.json == {'status': 'failed', 'error': 'youtube-bot-check'}
    assert b'cookie-secret-value' not in r.data

def test_mobile_client_uses_local_token_provider(client, monkeypatch, tmp_path):
    monkeypatch.setenv('YOUTUBE_POT_ENABLED', '1')
    monkeypatch.setenv('YOUTUBE_COOKIES_FILE', str(tmp_path / 'secret'))
    (tmp_path / 'secret').write_text('# Netscape HTTP Cookie File\n')
    def run(cmd, **kwargs):
        assert 'youtube:player_client=mweb,web_embedded' in cmd
        assert 'youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416' in cmd
        assert '--cookies' in cmd
        return subprocess.CompletedProcess(cmd, 0, '{}', '')
    monkeypatch.setattr(s.subprocess, 'run', run)
    assert s.run_ytdlp(['--skip-download', 'https://www.youtube.com/watch?v=' + VID]) == '{}'

def test_diagnostics_exposes_readiness_only(client, monkeypatch, tmp_path):
    secret = tmp_path / 'cookie-secret'; secret.write_text('PRIVATE_COOKIE_VALUE')
    monkeypatch.setenv('YOUTUBE_COOKIES_FILE', str(secret))
    monkeypatch.setenv('YOUTUBE_POT_ENABLED', '1')
    class Ready:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *args): pass
    monkeypatch.setattr(s.urllib.request, 'urlopen', lambda *args, **kwargs: Ready())
    r = client.get('/diagnostics')
    assert r.json['token_provider_ready'] is True
    assert r.json['cookies_loaded'] is True
    assert b'PRIVATE_COOKIE_VALUE' not in r.data and str(secret).encode() not in r.data

def test_short_job_starts_without_preparing_clip(client, monkeypatch):
    monkeypatch.setenv('PLAYBACK_WAIT_SECONDS', '1')
    video = b'actual-video-' * 100
    def prepare(vid):
        def finish():
            time.sleep(0.1)
            # Match the converter's atomic publication rather than exposing an
            # empty file between creation and the first write.
            temporary = s.MEDIA / (vid + '.tmp')
            temporary.write_bytes(video)
            temporary.replace(s.MEDIA / (vid + '.mp4'))
        threading.Thread(target=finish).start()
        return 'preparing'
    monkeypatch.setattr(s, 'schedule', prepare)
    r = client.get('/getvideo/' + VID)
    assert r.data == video

def test_only_top_short_result_is_prefetched(client, monkeypatch):
    monkeypatch.setenv('PREFETCH_SECONDS', '60')
    scheduled = []
    monkeypatch.setattr(s, 'schedule', lambda vid, **kw: scheduled.append(vid))
    s.warm_results([ITEM, {**ITEM, 'videoId': 'abcdefghij1'}])
    assert scheduled == [VID]
    scheduled.clear()
    s.warm_results([{**ITEM, 'lengthSeconds': 300}, ITEM])
    assert scheduled == []

def test_prefetch_does_not_fill_active_queue(client, monkeypatch):
    class FakeWorker:
        def submit(self, *args): pytest.fail('prefetch occupied queue')
    monkeypatch.setattr(s, 'worker', FakeWorker())
    s.jobs['abcdefghij1'] = ('preparing', time.monotonic())
    assert s.schedule(VID, prefetch=True) == 'busy'

def test_stream_test_is_local_and_uses_hls(client, monkeypatch):
    monkeypatch.setattr(s, 'run_ytdlp', lambda *a, **kw: pytest.fail('contacted YouTube'))
    r = client.get('/feeds/api/videos?q=stream+test')
    assert r.status_code == 200 and b'Streaming test' in r.data
    r = client.get('/getvideo/' + s.STREAM_TEST_ID)
    assert r.status_code == 302 and r.location == '/stream-test/index.m3u8'
    playlist = client.get(r.location)
    assert playlist.status_code == 200 and b'#EXT-X-VERSION:2' in playlist.data
    names = [v for v in playlist.data.decode().splitlines() if v.endswith('.ts')]
    assert names
    chunk = client.get('/stream-test/' + names[0])
    assert chunk.mimetype == 'video/mp2t' and chunk.data[0] == 0x47

def test_partial_hls_can_play_before_conversion_finishes(client, monkeypatch):
    monkeypatch.setenv('PLAYBACK_MODE', 'hls')
    d = s.HLS / VID; d.mkdir()
    (d/'index.m3u8').write_text('#EXTM3U\n#EXT-X-VERSION:2\n#EXT-X-TARGETDURATION:2\n'+
        ''.join(f'#EXTINF:2,\npart-{i:05d}.ts\n' for i in range(3)))
    for i in range(3): (d/f'part-{i:05d}.ts').write_bytes(b'G' + b'x'*187)
    s.jobs[VID] = ('preparing', time.monotonic())
    r = client.get('/getvideo/' + VID)
    assert r.status_code == 302 and r.location == f'/stream/{VID}/index.m3u8'
    assert client.get('/status/' + VID).json == {'status': 'streaming'}
    assert client.get(r.location).status_code == 200
    assert client.get(f'/stream/{VID}/part-00000.ts', headers={'Range':'bytes=0-9'}).status_code == 206
    assert client.get(f'/stream/{VID}/cookies.txt').status_code == 404

def test_real_hls_is_available_while_encoder_is_running(client):
    d = s.HLS / VID; d.mkdir()
    cmd = s.hls_args(s.ROOT / 'static/test.mp4', d)
    cmd.insert(cmd.index('-i'), '-re')
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 15
        while not s.hls_ready(VID) and p.poll() is None and time.monotonic() < deadline:
            time.sleep(.1)
        assert s.hls_ready(VID)
        assert p.poll() is None, 'the stream only became available after full conversion'
        text = (d / 'index.m3u8').read_text()
        assert '#EXT-X-VERSION:2' in text
        assert '#EXT-X-ENDLIST' not in text
        assert '.000' not in text
        first = next(d.glob('part-*.ts'))
        probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error',
            '-show_streams', '-of', 'json', str(first)]))
        streams = probe['streams']
        video = next(v for v in streams if v['codec_type'] == 'video')
        audio = next(v for v in streams if v['codec_type'] == 'audio')
        assert video['profile'] == 'Constrained Baseline' and video['level'] == 30
        assert (video['width'], video['height']) == (320, 240)
        assert audio['codec_name'] == 'aac' and audio['profile'] == 'LC'
    finally:
        if p.poll() is None: p.terminate()
        p.wait(timeout=5)

def test_feed_valid_xml_and_http_urls(client, monkeypatch):
    monkeypatch.setattr(s, 'search', lambda *a, **k: [ITEM])
    for route in ['/feeds/api/videos?q=hello','/feeds/api/standardfeeds/US/recently_featured']:
        r=client.get(route, base_url='http://198.51.100.5')
        assert r.status_code==200
        root=ET.fromstring(r.data)
        assert root.find('.//{http://www.w3.org/2005/Atom}entry/{http://www.w3.org/2005/Atom}title').text==ITEM['title']
        assert b'http://198.51.100.5/getvideo/abcdefghijk' in r.data
        assert b'http://198.51.100.5/thumb/abcdefghijk' in r.data

def test_batch(client, monkeypatch):
    monkeypatch.setattr(s, 'info', lambda vid: ITEM)
    r=client.post('/feeds/api/videos/batch',data=f'<id>http://gdata.youtube.com/feeds/api/videos/{VID}</id>')
    assert r.status_code==200
    ET.fromstring(r.data)
    assert b'<batch:status code="200"' in r.data
    assert b'<name>Name &amp; Name</name>' in r.data

def test_range_and_head(client):
    path=s.MEDIA/(VID+'.mp4'); path.write_bytes(b'x'*1024)
    r=client.get('/getvideo/'+VID,headers={'Range':'bytes=100-199'})
    assert r.status_code==206
    assert r.headers['Content-Range']=='bytes 100-199/1024'
    assert len(r.data)==100
    assert r.headers['Cache-Control']=='no-store'
    r=client.head('/getvideo/'+VID)
    assert r.status_code==200 and not r.data and r.headers['Content-Length']=='1024'

def test_pending_returns_real_clip_promptly(client, monkeypatch):
    monkeypatch.setattr(s, 'schedule', lambda vid:'preparing')
    t=time.monotonic(); r=client.get('/getvideo/'+VID)
    assert time.monotonic()-t < 2
    assert r.status_code==200 and r.mimetype=='video/mp4'
    assert r.data[4:8]==b'ftyp'
    assert r.headers['Cache-Control']=='no-store'

def test_bad_ids_do_not_launch_processes(client, monkeypatch):
    monkeypatch.setattr(s, 'schedule', lambda *a: pytest.fail('process launched'))
    for vid in ['bad','..','not-valid-long-id']:
        assert client.get('/getvideo/'+vid).status_code==404

def test_deduplication_and_queue_bound(client, monkeypatch):
    class FakeWorker:
        calls=[]
        def submit(self,*args): self.calls.append(args)
    fake=FakeWorker(); monkeypatch.setattr(s,'worker',fake)
    assert s.schedule(VID)=='preparing'
    assert s.schedule(VID)=='preparing'
    s.schedule('abcdefghij1');s.schedule('abcdefghij2')
    assert s.schedule('abcdefghij3')=='busy'
    assert len(fake.calls)==3

def test_failed_conversion_does_not_publish_partial(client, monkeypatch):
    monkeypatch.setattr(s,'info', lambda v:ITEM)
    def fail(*a,**k):raise RuntimeError('YouTube blocked')
    monkeypatch.setattr(s,'run_ytdlp',fail)
    s.convert(VID)
    assert not (s.MEDIA/(VID+'.mp4')).exists()
    assert s.jobs[VID][0]=='failed'
    assert not list(s.STATE.glob('source-*'))

def test_synthetic_transcode_and_ffprobe(client, tmp_path):
    source=tmp_path/'input.mp4';output=tmp_path/'output.mp4'
    subprocess.run(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-y',
                    '-f','lavfi','-i','testsrc2=size=640x360:rate=30',
                    '-f','lavfi','-i','sine=frequency=440:sample_rate=48000',
                    '-t','2','-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-c:a','aac',str(source)],check=True)
    subprocess.run(s.ffmpeg_args(source,output),check=True,capture_output=True)
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(output)]))
    video,audio=probe['streams']
    assert video['codec_name']=='h264' and video['profile']=='Constrained Baseline'
    assert video['level']==30 and (video['width'],video['height'])==(320,240)
    assert video['pix_fmt']=='yuv420p' and video['r_frame_rate']=='24/1'
    assert audio['codec_name']=='aac' and audio['profile']=='LC' and audio['sample_rate']=='44100'
    assert audio['channels']==2
    raw=output.read_bytes();assert raw.index(b'moov')<raw.index(b'mdat')

def test_phone_plist_has_host_without_protocol(client):
    import plistlib
    r=client.get('/setup/com.apple.youtubeframework.plist',base_url='http://198.51.100.5')
    assert plistlib.loads(r.data)=={'ConfiguredServiceHost':'198.51.100.5'}
    assert r.headers['Content-Disposition'].endswith('com.apple.youtubeframework.plist')

def test_render_https_urls_behind_http_proxy(client, monkeypatch):
    import plistlib
    monkeypatch.setenv('RENDER_EXTERNAL_URL', 'https://youtube-2g-example.onrender.com')
    monkeypatch.setattr(s, 'search', lambda *a, **k: [ITEM])
    r=client.get('/feeds/api/videos?q=test', base_url='http://internal:10000')
    assert b'https://youtube-2g-example.onrender.com/getvideo/abcdefghijk' in r.data
    assert b'http://internal' not in r.data
    r=client.get('/setup/com.apple.youtubeframework.plist', base_url='http://internal:10000')
    assert plistlib.loads(r.data)=={'ConfiguredServiceHost':'youtube-2g-example.onrender.com'}
    monkeypatch.setenv('PUBLIC_BASE_URL', 'https://custom.example/')
    assert b'https://custom.example' in client.get('/feeds/api/videos?q=test').data
