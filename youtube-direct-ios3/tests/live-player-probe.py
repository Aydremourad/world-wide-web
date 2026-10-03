"""Read-only availability probe. Log statuses only, never signed media URLs."""
import gzip
import json
import re
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError

clients = [
    (3, {"clientName": "ANDROID", "clientVersion": "21.26.364", "androidSdkVersion": 30,
         "userAgent": "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
         "osName": "Android", "osVersion": "11"}),
    (101, {"clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple",
           "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471",
           "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"}),
    (5, {"clientName": "IOS", "clientVersion": "21.26.4", "deviceMake": "Apple",
         "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82",
         "userAgent": "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"}),
    (1, {"clientName": "WEB", "clientVersion": "2.20260708.00.00",
         "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"}),
    (2, {"clientName": "MWEB", "clientVersion": "2.20260708.05.00",
         "userAgent": "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)"}),
    (75, {"clientName": "TVHTML5_SIMPLY", "clientVersion": "1.0",
          "userAgent": "Mozilla/5.0"}),
]
summary = []
for number, client in clients:
    record = {"client": client["clientName"]}
    try:
        body = {"context": {"client": dict(client, hl="en", gl="US")},
                "videoId": "jNQXAC9IVRw", "contentCheckOk": True, "racyCheckOk": True}
        request = Request("https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
                          data=json.dumps(body).encode(), headers={
                              "Content-Type": "application/json", "User-Agent": client["userAgent"],
                              "X-YouTube-Client-Name": str(number), "X-YouTube-Client-Version": client["clientVersion"]})
        with urlopen(request, timeout=7) as response:
            data = response.read(2 * 1024 * 1024)
            if response.headers.get("Content-Encoding") == "gzip":
                data = gzip.decompress(data)
        player = json.loads(data)
        status = player.get("playabilityStatus", {})
        record.update(status=status.get("status"), reason=status.get("reason"))
        streaming = player.get("streamingData", {})
        hls = streaming.get("hlsManifestUrl")
        record["hasHLS"] = bool(hls)
        if hls:
            try:
                with urlopen(Request(hls, headers={"User-Agent": client["userAgent"]}), timeout=7) as response:
                    manifest = response.read(512 * 1024).decode("utf-8", "replace")
                record["hlsVersion"] = next((line.split(":", 1)[1] for line in manifest.splitlines()
                                             if line.startswith("#EXT-X-VERSION:")), "1")
                record["hlsVariantCount"] = sum(line.startswith("#EXT-X-STREAM-INF:") for line in manifest.splitlines())
                record["hlsHasMap"] = "#EXT-X-MAP:" in manifest
                record["hlsHasTS"] = "seg.ts" in manifest or any(".ts" in line for line in manifest.splitlines() if not line.startswith("#"))
                record["hlsResolutions"] = re.findall(r"RESOLUTION=([0-9]+x[0-9]+)", manifest)[:12]
            except HTTPError as error:
                record["hlsHttp"] = error.code
            except Exception as error:
                record["hlsError"] = type(error).__name__
        formats = streaming.get("formats", []) + streaming.get("adaptiveFormats", [])
        selected = [f for f in formats if f.get("itag") in (17, 18, 597, 160, 140)]
        record["formats"] = [{"itag": f["itag"], "direct": bool(f.get("url")), "mime": f.get("mimeType"),
                              "width": f.get("width"), "height": f.get("height"), "fps": f.get("fps"),
                              "contentLength": f.get("contentLength"),
                              "urlLength": parse_qs(urlsplit(f.get("url", "")).query).get("clen", [None])[0]}
                             for f in selected]
        checks = []
        for itags in [(17, 597, 160), (140,)]:
            media = next((f for itag in itags for f in selected if f["itag"] == itag and f.get("url")), None)
            if not media:
                continue
            url = media["url"] + "&range=0-15"
            try:
                with urlopen(Request(url, headers={"User-Agent": client["userAgent"]}), timeout=7) as response:
                    checks.append({"itag": media["itag"], "http": response.status, "bytes": len(response.read(16))})
            except HTTPError as error:
                checks.append({"itag": media["itag"], "http": error.code})
            except Exception as error:
                checks.append({"itag": media["itag"], "error": type(error).__name__})
        record["mediaChecks"] = checks
    except HTTPError as error:
        record["http"] = error.code
    except Exception as error:
        record["error"] = type(error).__name__
    summary.append(record)
print(json.dumps(summary, indent=2))
print("This probes a datacenter connection, not iPhone playback or the phone's network.")
