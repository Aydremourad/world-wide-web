from pathlib import Path

p = Path("/app/src/lib/helpers/youtubePlayerReq.ts")
s = p.read_text()

# No-op compatibility patch file retained so Dockerfile stays simple.
# Normal Companion PO-token flow is intentionally used.
p.write_text(s)
print("Using stock Companion player request path (PO-token enabled)")
