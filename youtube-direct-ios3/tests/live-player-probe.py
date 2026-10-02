"""Read-only availability probe. Log statuses only, never signed media URLs."""
import gzip
import json
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
        formats = player.get("streamingData", {}).get("adaptiveFormats", [])
        selected = [f for f in formats if f.get("itag") in (597, 160, 140)]
        record["formats"] = [{"itag": f["itag"], "direct": bool(f.get("url")),
                              "contentLength": f.get("contentLength"),
                              "urlLength": parse_qs(urlsplit(f.get("url", "")).query).get("clen", [None])[0]}
                             for f in selected]
        checks = []
        for itags in [(597, 160), (140,)]:
            media = next((f for itag in itags for f in selected if f["itag"] == itag and f.get("url")), None)
            if not media:
                continue
            url = media["url"] + "&range=0-15"
            try:
                with urlopen(Request(url, headers={"User-Agent": client["userAgent"], "Range": "bytes=0-15"}), timeout=7) as response:
                    checks.append({"itag": media["itag"], "http": response.status,
                                   "bytes": len(response.read(16))})
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
