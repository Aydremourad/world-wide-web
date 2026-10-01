FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PORT=10000 STATE_DIR=/app/state DENO_DIR=/app/state/deno \
    MAX_CACHE_BYTES=262144000 SERVER_THREADS=2 MAX_VIDEO_SECONDS=600

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg fonts-dejavu-core ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL --retry 3 https://github.com/denoland/deno/releases/download/v2.9.7/deno-x86_64-unknown-linux-gnu.zip -o /tmp/deno.zip \
    && unzip -q /tmp/deno.zip -d /usr/local/bin \
    && rm /tmp/deno.zip \
    && deno --version

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py make_clips.py NOTICE.md LICENSE ./
COPY templates ./templates
COPY static/categories.cat ./static/categories.cat
RUN python make_clips.py \
    && useradd --create-home --uid 10001 youtube2g \
    && mkdir -p /app/state \
    && chown -R youtube2g:youtube2g /app/state

USER youtube2g
EXPOSE 10000
CMD ["python", "app.py"]
