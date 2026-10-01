FROM node:24-bookworm-slim AS token-builder
WORKDIR /opt/bgutil
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl python3 make g++ libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL --retry 3 https://codeload.github.com/Brainicism/bgutil-ytdlp-pot-provider/tar.gz/refs/tags/2.0.0 -o /tmp/provider.tar.gz \
    && echo '47038f7e0556a3d689044460f1b6d78381212e1bd04723a27358e1a42279f866  /tmp/provider.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/provider.tar.gz --strip-components=1 \
    && rm /tmp/provider.tar.gz
WORKDIR /opt/bgutil/server
RUN npm ci --no-audit --no-fund && npx tsc && npm prune --omit=dev --no-audit --no-fund

FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PORT=10000 STATE_DIR=/app/state DENO_DIR=/app/state/deno \
    MAX_CACHE_BYTES=262144000 SERVER_THREADS=4 MAX_VIDEO_SECONDS=600 YOUTUBE_POT_ENABLED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg fonts-dejavu-core ca-certificates curl unzip libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libjpeg62-turbo libgif7 librsvg2-2 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL --retry 3 https://github.com/denoland/deno/releases/download/v2.9.7/deno-x86_64-unknown-linux-gnu.zip -o /tmp/deno.zip \
    && unzip -q /tmp/deno.zip -d /usr/local/bin \
    && rm /tmp/deno.zip \
    && deno --version

COPY --from=token-builder /usr/local/bin/node /usr/local/bin/node
COPY --from=token-builder /opt/bgutil /opt/bgutil

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py start.py make_clips.py NOTICE.md LICENSE ./
COPY templates ./templates
COPY static/categories.cat ./static/categories.cat
RUN python make_clips.py \
    && useradd --create-home --uid 10001 youtube2g \
    && mkdir -p /app/state \
    && chown -R youtube2g:youtube2g /app/state

USER youtube2g
EXPOSE 10000
CMD ["python", "start.py"]
