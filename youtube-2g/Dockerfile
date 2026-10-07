FROM node:24-bookworm-slim AS token-builder

WORKDIR /opt/bgutil

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl python3 make g++ \
       libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL --retry 3 \
       https://codeload.github.com/Brainicism/bgutil-ytdlp-pot-provider/tar.gz/refs/tags/2.0.0 \
       -o /tmp/provider.tar.gz \
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
    USE_REDIS=false

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates ffmpeg git \
       libcairo2 libpango-1.0-0 libpangocairo-1.0-0 \
       libjpeg62-turbo libgif7 librsvg2-2 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=token-builder /usr/local/bin/node /usr/local/bin/node
COPY --from=token-builder /opt/bgutil /opt/bgutil

# Validate the exact runtime path used by yt-dlp's bgutil script provider.
# This catches Node/native-module/provider packaging problems at image build
# time instead of crashing the Render service during startup.
RUN node --version \
    && node /opt/bgutil/server/build/generate_once.js --version

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
    "yt-dlp[default,curl-cffi]" \
    "bgutil-ytdlp-pot-provider==2.0.0" \
    && mv /usr/local/bin/yt-dlp /usr/local/bin/yt-dlp-real

COPY invidious_failover.py /app/modified-tuberepair/tuberepair/modules/invidious_failover.py

COPY yt_dlp_render.py /usr/local/bin/yt-dlp
RUN chmod 0755 /usr/local/bin/yt-dlp


WORKDIR /app/modified-tuberepair/tuberepair

EXPOSE 10000
CMD ["python", "main.py"]
