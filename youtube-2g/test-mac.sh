#!/bin/zsh
set -e

BASE="$1"
VIDEO="$2"
if [ -z "$BASE" ]; then BASE="http://127.0.0.1:10000"; fi
if [ -z "$VIDEO" ]; then VIDEO="jNQXAC9IVRw"; fi

echo "Diagnostics:"
curl -fsS "$BASE/diagnostics"
echo
echo
echo "Triggering test video $VIDEO ..."
curl -fL --max-time 240 -o "/tmp/youtube2g-test-$VIDEO.mp4" "$BASE/getvideo/$VIDEO"

echo
echo "Downloaded:"
ls -lh "/tmp/youtube2g-test-$VIDEO.mp4"
echo
echo "Codec check:"
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,width,height,level,refs,pix_fmt -of default=noprint_wrappers=1 "/tmp/youtube2g-test-$VIDEO.mp4"
ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,profile,sample_rate,channels -of default=noprint_wrappers=1 "/tmp/youtube2g-test-$VIDEO.mp4"
