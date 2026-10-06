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
RUN npm ci --no-audit --no-fund \
    && npx tsc \
    && npm prune --omit=dev --no-audit --no-fund


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
    YOUTUBE_POT_ENABLED=1 \
    YOUTUBE_TOKEN_SERVER_DIR=/opt/bgutil/server \
    TUBEREPAIR_DATA_DIR=/var/data \
    SERVER_THREADS=8 \
    MODIFIED_TUBEREPAIR_COMMIT=${MODIFIED_TUBEREPAIR_COMMIT}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates ffmpeg git curl \
       libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libjpeg62-turbo libgif7 librsvg2-2 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=token-builder /usr/local/bin/node /usr/local/bin/node
COPY --from=token-builder /opt/bgutil /opt/bgutil

WORKDIR /app

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

RUN python -m pip install --no-cache-dir \
    -r /app/upstream-requirements.txt \
    "yt-dlp[default] @ https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/2026.09.27.232945/yt-dlp.tar.gz#sha256=895f2e80f60a9e54ca8ee40328c0e788794481444bd17698521cfafc4b318afc" \
    "bgutil-ytdlp-pot-provider==2.0.0"

COPY patch_modified_tuberepair.py /app/patch_modified_tuberepair.py
RUN python /app/patch_modified_tuberepair.py

COPY modified_main.py /app/modified_main.py

RUN mkdir -p /var/data

EXPOSE 10000
CMD ["python", "/app/modified_main.py"]
