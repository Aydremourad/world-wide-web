FROM python:3.11-slim-bookworm

ARG MODIFIED_TUBEREPAIR_COMMIT=f94cea890ba94b8e92eccc02317f10b8439be144

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=10000 \
    DEBUG=false \
    SPYING=false \
    COMPRESS=true \
    MEDIUM_QUALITY=true \
    USE_REDIS=false

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ffmpeg git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY remove_upstream_startup_probe.py /tmp/remove_upstream_startup_probe.py

RUN git clone --filter=blob:none --no-checkout \
      https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4.git \
      /app/modified-tuberepair \
    && cd /app/modified-tuberepair \
    && git checkout "${MODIFIED_TUBEREPAIR_COMMIT}" \
    && cp requirements.txt /app/upstream-requirements.txt \
    && python /tmp/remove_upstream_startup_probe.py \
    && rm /tmp/remove_upstream_startup_probe.py

RUN python -m pip install --no-cache-dir \
    -r /app/upstream-requirements.txt \
    yt-dlp \
    && mv /usr/local/bin/yt-dlp /usr/local/bin/yt-dlp-real

COPY yt-dlp-proxy-wrapper.sh /usr/local/bin/yt-dlp
RUN chmod 0755 /usr/local/bin/yt-dlp

WORKDIR /app/modified-tuberepair/tuberepair

EXPOSE 10000
CMD ["python", "main.py"]
