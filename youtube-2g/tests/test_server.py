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

def test_local_playback_sample_never_contacts_youtube(client, monkeypatch):
    monkeypatch.setattr(s, 'run_ytdlp', lambda *a, **kw: pytest.fail('contacted YouTube'))
    for query in ['playback+test', 'stream+test']:
        r = client.get('/feeds/api/videos?q=' + query)
        assert r.status_code == 200 and b'Playback test' in r.data
        assert s.PLAYBACK_TEST_ID.encode() in r.data
    for vid in s.LOCAL_TEST_IDS:
        r = client.get('/feeds/api/videos/' + vid)
        assert r.status_code == 200
        r = client.get('/getvideo/' + vid)
        assert r.status_code == 200 and r.mimetype == 'video/mp4'
        assert 'Location' not in r.headers
        assert r.data == (s.ROOT / 'static/test.mp4').read_bytes()
        assert client.get('/status/' + vid).json == {'status': 'ready'}
    assert client.get('/thumb/' + s.PLAYBACK_TEST_ID).mimetype == 'image/jpeg'

def test_local_sample_works_with_read_only_build_files(client, monkeypatch):
    original_utime = s.os.utime
    def read_only_sample(path, *args, **kwargs):
        if Path(path).is_relative_to(s.ROOT / 'static'):
            raise PermissionError('build-generated sample files are read-only')
        return original_utime(path, *args, **kwargs)
    monkeypatch.setattr(s.os, 'utime', read_only_sample)
    path = '/getvideo/' + s.PLAYBACK_TEST_ID
    chunk = client.get(path, headers={'Range': 'bytes=0-31'})
    assert chunk.status_code == 206 and len(chunk.data) == 32
    assert chunk.mimetype == 'video/mp4' and chunk.data[4:8] == b'ftyp'
    head = client.head(path)
    assert head.status_code == 200 and not head.data
    assert int(head.headers['Content-Length']) == (s.ROOT / 'static/test.mp4').stat().st_size

def test_old_hls_setting_cannot_replace_mp4_playback(client, monkeypatch):
    monkeypatch.setenv('PLAYBACK_MODE', 'hls')
    sample = (s.ROOT / 'static/test.mp4').read_bytes()
    (s.MEDIA / (VID + '.mp4')).write_bytes(sample)
    for route in ['/getvideo/', '/video/sd/', '/video/hd/']:
        r = client.get(route + VID)
        assert r.status_code == 200 and r.mimetype == 'video/mp4'
        assert r.data == sample and 'Location' not in r.headers
    assert client.get('/diagnostics').json['playback_mode'] == 'mp4'
    assert client.get('/status/' + VID).json == {'status': 'ready'}
    r = client.get('/stream-test/index.m3u8', follow_redirects=True)
    assert r.status_code == 200 and r.data == sample

def test_conversion_publishes_mp4_despite_old_hls_setting(client, monkeypatch):
    monkeypatch.setenv('PLAYBACK_MODE', 'hls')
    def download(args, **kwargs):
        source = Path(args[args.index('-o') + 1])
        source.write_bytes((s.ROOT / 'static/test.mp4').read_bytes())
        return ''
    monkeypatch.setattr(s, 'run_ytdlp', download)
    s.convert(VID, hint=ITEM)
    assert s.jobs[VID][0] == 'ready'
    r = client.get('/getvideo/' + VID)
    assert r.status_code == 200 and r.mimetype == 'video/mp4'
    assert r.data.index(b'moov') < r.data.index(b'mdat')
    assert not list(s.STATE.glob('source-*'))

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
