FROM python:3.11-slim-bookworm

ARG MODIFIED_TUBEREPAIR_COMMIT=f94cea890ba94b8e92eccc02317f10b8439be144

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=10000 \
    DEBUG=false \
    SPYING=false \
    COMPRESS=true \
    MEDIUM_QUALITY=true \
    USE_REDIS=false \
    TUBEREPAIR_DATA_DIR=/var/data \
    SERVER_THREADS=8 \
    MODIFIED_TUBEREPAIR_COMMIT=${MODIFIED_TUBEREPAIR_COMMIT}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates ffmpeg git nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY patch_video_proxy.py /tmp/patch_video_proxy.py

# Run the actual Modified TubeRepair source, pinned to a known upstream commit.
RUN git clone --filter=blob:none --no-checkout \
      https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4.git \
      /tmp/modified-tuberepair \
    && cd /tmp/modified-tuberepair \
    && git checkout "${MODIFIED_TUBEREPAIR_COMMIT}" \
    && cp -a tuberepair /app/tuberepair \
    && cp requirements.txt /app/upstream-requirements.txt \
    && cp LICENSE /app/UPSTREAM-GPL-3.0-LICENSE \
    && find /app/tuberepair -maxdepth 1 -type f -name '*.mp4' -delete \
    && find /app/tuberepair -maxdepth 1 -type f -name '*.mp4.part' -delete \
    && rm -rf /tmp/modified-tuberepair

RUN python /tmp/patch_video_proxy.py && rm /tmp/patch_video_proxy.py

# Upstream README requires yt-dlp + FFmpeg but its Dockerfile does not install
# yt-dlp. Use the same current nightly that was already proven on this service.
RUN python -m pip install --no-cache-dir -r /app/upstream-requirements.txt \
    "yt-dlp[default] @ https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/2026.09.27.232945/yt-dlp.tar.gz#sha256=895f2e80f60a9e54ca8ee40328c0e788794481444bd17698521cfafc4b318afc"

COPY modified_main.py /app/modified_main.py

# /var/data works as an ephemeral directory on Free and becomes persistent
# automatically when a paid Render disk is mounted there.
RUN mkdir -p /var/data

EXPOSE 10000
CMD ["python", "/app/modified_main.py"]
