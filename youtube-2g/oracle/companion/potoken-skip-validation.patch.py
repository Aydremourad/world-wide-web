from pathlib import Path

p = Path("/app/src/lib/jobs/potoken.ts")
s = p.read_text()

old = """                // check token from minter
                await checkToken({
                    instantiatedInnertubeClient,
                    config,
                    integrityTokenBasedMinter: minter,
                    metrics,
                });
                console.log("[INFO] Successfully generated PO token");
"""

new = """                // Diagnostic mode for Oracle/iPhone 2G:
                // keep the freshly generated session + token minter even if
                // Companion's random-video validation path is currently broken.
                console.log("[INFO] PO token generated; skipping validation gate for direct playback test");
"""

if old not in s:
    raise SystemExit("PO-token validation block not found")

s = s.replace(old, new)
p.write_text(s)
print("Patched Companion to retain generated PO token without validation")
