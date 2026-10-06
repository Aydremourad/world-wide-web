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

RUN git clone --filter=blob:none --no-checkout \
      https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4.git \
      /app/modified-tuberepair \
    && cd /app/modified-tuberepair \
    && git checkout "${MODIFIED_TUBEREPAIR_COMMIT}" \
    && cp requirements.txt /app/upstream-requirements.txt \
    && python -c 'from pathlib import Path; p=Path("/app/modified-tuberepair/tuberepair/api/video.py"); s=p.read_text(); s=s.replace("print(\\n    \\"TEST CHANNEL ID:\\",\\n    get_channel_id_from_name(\\"MrBeast\\")\\n)\\n", ""); p.write_text(s)'

RUN python -m pip install --no-cache-dir \
    -r /app/upstream-requirements.txt \
    yt-dlp

WORKDIR /app/modified-tuberepair/tuberepair

EXPOSE 10000
CMD ["python", "main.py"]
