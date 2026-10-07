FROM denoland/deno:bin-2.9.2 AS deno-bin

FROM debian:13-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=deno-bin /deno /usr/bin/deno
RUN git clone https://github.com/iv-org/invidious-companion.git .
RUN git checkout bb3b37f
COPY oauth-no-pot.patch.py /tmp/oauth-no-pot.patch.py
RUN python3 /tmp/oauth-no-pot.patch.py
ENV DENO_DIR=/deno-dir
RUN mkdir -p /var/tmp/youtubei.js /deno-dir
RUN deno task compile

FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --create-home appuser && mkdir -p /var/tmp/youtubei.js && chown -R appuser:appuser /var/tmp/youtubei.js
WORKDIR /app
COPY --from=builder /app/invidious_companion /app/invidious_companion
COPY --from=builder /app/config /app/config
ENV SERVER_BASE_PATH=/companion HOST=127.0.0.1 PORT=8282
USER appuser
ENTRYPOINT ["/app/invidious_companion"]
