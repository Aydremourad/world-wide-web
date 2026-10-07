from pathlib import Path

p = Path("/app/src/lib/helpers/youtubePlayerReq.ts")
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

old = """    const youtubePlayerResponse = await callWatchEndpoint(
        videoId,
        innertubeClient,
        innertubeClientUsed,
        contentPoToken,
    );
"""

new = """    let youtubePlayerResponse = await callWatchEndpoint(
        videoId,
        innertubeClient,
        innertubeClientUsed,
        contentPoToken,
    );

    if (innertubeClientOauthEnabled) {
        const oauthFallbackClients = [
            "TV_SIMPLY",
            "ANDROID_VR",
            "MWEB",
        ];

        const playable = (response: ApiResponse) =>
            response.data?.playabilityStatus?.status === "OK" &&
            !!response.data?.streamingData &&
            (
                (response.data.streamingData.formats?.length ?? 0) > 0 ||
                (response.data.streamingData.adaptiveFormats?.length ?? 0) > 0
            );

        if (!playable(youtubePlayerResponse)) {
            for (const client of oauthFallbackClients) {
                console.log(
                    `[OAUTH] Client ${innertubeClientUsed} not playable; trying ${client}`,
                );
                try {
                    const candidate = await callWatchEndpoint(
                        videoId,
                        innertubeClient,
                        client,
                        contentPoToken,
                    );
                    if (playable(candidate)) {
                        console.log(`[OAUTH] Playback accepted by client ${client}`);
                        youtubePlayerResponse = candidate;
                        innertubeClientUsed = client;
                        break;
                    }
                    console.log(
                        `[OAUTH] Client ${client} responded but was not playable: ${candidate.data?.playabilityStatus?.status ?? "unknown"} / ${candidate.data?.playabilityStatus?.reason ?? "no reason"}`,
                    );
                    youtubePlayerResponse = candidate;
                    innertubeClientUsed = client;
                } catch (err) {
                    console.log(
                        `[OAUTH] Client ${client} request failed; continuing to next client:`,
                        err,
                    );
                    innertubeClientUsed = client;
                }
            }
        }
    }
"""

if old not in s:
    raise SystemExit("OAuth fallback insertion point not found")

s = s.replace(old, new)

if 'tokenMinter?: TokenMinter' not in s:
    raise SystemExit("tokenMinter optional patch did not apply")
if 'typeof tokenMinter === "function"' not in s:
    raise SystemExit("tokenMinter guard patch did not apply")
if 'oauthFallbackClients' not in s:
    raise SystemExit("OAuth fallback client patch did not apply")

p.write_text(s)
print("Patched Companion OAuth path: optional PO-token plus multi-client fallback")
