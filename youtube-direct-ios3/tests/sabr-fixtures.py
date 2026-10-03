"""Independent protobuf/UMP fixture encoder; real fragmented H.264 payload."""
import sys,struct
from pathlib import Path
source=Path(sys.argv[1]).read_bytes();dest=Path(sys.argv[2]);dest.mkdir()
def var(n):
 out=bytearray()
 while n>127:out.append((n&127)|128);n>>=7
 out.append(n);return bytes(out)
def v(k,n):return var(k<<3)+var(n)
def b(k,s):return var(k<<3|2)+var(len(s))+s
def umpnum(n):
 if n<128:return bytes([n])
 if n<16384:return bytes([(n&63)|128,n>>6])
 if n<2097152:return bytes([(n&31)|192,(n>>5)&255,n>>13])
 if n<268435456:return bytes([(n&15)|224,(n>>4)&255,(n>>12)&255,n>>20])
 return b'\xf0'+struct.pack('<I',n)
def part(k,s):return umpnum(k)+umpnum(len(s))+s
pos=0;init=b'';segments=[];current=b''
while pos<len(source):
 size,typ=struct.unpack('>I4s',source[pos:pos+8]);assert size>=8 and pos+size<=len(source)
 box=source[pos:pos+size];pos+=size
 if typ in (b'ftyp',b'moov'):init+=box
 elif typ==b'moof':
  if current:segments.append(current)
  current=box
 elif typ==b'mdat':current+=box
if current:segments.append(current)
assert init[4:8]==b'ftyp' and len(segments)>=2
# Fixture has one-second GOPs, eight seconds of real 144p Main-profile video.
format_id=v(1,160)+v(2,1700000000000000)
metadata=b(1,b'jNQXAC9IVRw')+b(2,format_id)+v(3,8000)+v(4,len(segments))
for i,segment in enumerate(segments):
 out=part(42,metadata)
 if i==0:
  ih=v(1,5)+b(2,b'jNQXAC9IVRw')+b(13,format_id)+v(8,1)+v(14,len(init))
  out+=part(20,ih)+part(21,b'\x05'+init)+part(22,b'\x05')
  out+=part(35,b(7,b'\x08\x01'))
  out+=part(57,v(1,7)+v(2,1)+b(3,b'opaque-context')+v(4,1))
 h=v(1,6)+b(2,b'jNQXAC9IVRw')+b(13,format_id)+v(9,i+1)+v(11,i*1000)+v(12,1000)+v(14,len(segment))
 out+=part(20,h)
 # Split media between two UMP parts to exercise assembly and size checks.
 split=len(segment)//2
 out+=part(21,b'\x06'+segment[:split])+part(21,b'\x06'+segment[split:])+part(22,b'\x06')
 (dest/f'{i}.ump').write_bytes(out)
(dest/'count').write_text(str(len(segments)))
# All UMP integer widths including the uncommon five-byte encoding.
(dest/'varints').write_bytes(b''.join(umpnum(n) for n in (127,128,16383,16384,2097151,2097152,268435455,268435456,4294967295)))
