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
ITEM=dict(videoId=VID,title='A & B <test> "quotes"',author='Name & Name',authorId='unknown',description='Text <tag> & symbols',published=0,lengthSeconds=12,viewCount=123)

@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(s, 'MEDIA', tmp_path)
    monkeypatch.setattr(s, 'STATE', tmp_path)
    s.jobs.clear()
    s.metadata_cache.clear()
    return s.app.test_client()

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
