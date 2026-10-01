from pathlib import Path
import subprocess
import textwrap
from PIL import Image, ImageDraw, ImageFont
root = Path(__file__).resolve().parent / 'static'
font_path = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
font = ImageFont.truetype(font_path, 18)
messages = {
 'test': 'YouTube 2G\nPlayback test\n\nIf you can see this,\nMP4 playback works.',
 'preparing': 'Preparing video\n\nClose this clip.\nWait 30-90 seconds.\nTap the video again.',
 'failed': 'Video unavailable\n\nTry another video.\nYouTube may be blocking\nthe server request.',
 'too-long': 'Video is too long\n\nTry a video under\n20 minutes.',
 'busy': 'Server is busy\n\nWait a minute, then\ntap the video again.'}
for name, text in messages.items():
    im = Image.new('RGB', (320, 240), '#122637')
    draw = ImageDraw.Draw(im)
    draw.multiline_text((160, 120), text, font=font, fill='white', anchor='mm', align='center', spacing=8)
    png = root / (name + '.png')
    im.save(png)
    subprocess.run(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-loop', '1', '-i', str(png),
                    '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo', '-t', '8', '-r', '24',
                    '-c:v', 'libx264', '-threads', '1', '-preset', 'ultrafast', '-profile:v', 'baseline', '-level:v', '3.0',
                    '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-profile:a', 'aac_low', '-b:a', '80k',
                    '-movflags', '+faststart', str(root / (name + '.mp4'))], check=True)
    png.unlink()
