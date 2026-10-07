from pathlib import Path

p = Path("/src/src/lib/helpers/youtubePlayerReq.ts")
s = p.read_text()

s = s.replace(
    "    tokenMinter: TokenMinter,\n",
    "    tokenMinter?: TokenMinter,\n",
)

s = s.replace(
    "    const contentPoToken = await tokenMinter(videoId);\n",
    """    const contentPoToken = typeof tokenMinter === "function"
        ? await tokenMinter(videoId)
        : "";
""",
)

s = s.replace(
"""            serviceIntegrityDimensions: {
                poToken: contentPoToken,
            },
""",
"""            ...(contentPoToken
                ? {
                    serviceIntegrityDimensions: {
                        poToken: contentPoToken,
                    },
                }
                : {}),
""",
)

if 'tokenMinter?: TokenMinter' not in s:
    raise SystemExit("tokenMinter optional patch did not apply")
if 'typeof tokenMinter === "function"' not in s:
    raise SystemExit("tokenMinter guard patch did not apply")

p.write_text(s)
print("Patched Companion OAuth path to allow no PO-token minter")
