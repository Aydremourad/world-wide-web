from pathlib import Path

p = Path("/app/deno.jsonc")
s = p.read_text()

old = "v18.0.0-deno"
new = "v18.1.0-deno"

if old not in s:
    raise SystemExit("Expected YouTube.js 18.0.0 dependency not found")

s = s.replace(old, new)
p.write_text(s)
print("Updated Companion YouTube.js dependency to 18.1.0")
