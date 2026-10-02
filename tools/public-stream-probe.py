"""Check public relay availability without downloading complete videos."""
import gzip
import json
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

video_id = "jNQXAC9IVRw"
host = "https://inv.uptimetrackers.com"
summary = []
try:
    with urlopen(Request(host + "/api/v1/videos/" + video_id + "?local=true",
                         headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"}), timeout=8) as response:
        raw = response.read(2 * 1024 * 1024)
        if response.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
        metadata = json.loads(raw)
    formats = metadata.get("adaptiveFormats", [])
    summary.append({"metadata": "OK", "error": metadata.get("error"),
                    "formats": [{k: f.get(k) for k in ("itag", "type", "clen", "resolution", "size", "fps")}
                                for f in formats if str(f.get("itag")) in ("597", "160", "140")]})
    for itags in [("597", "160"), ("140",)]:
        media = next((f for itag in itags for f in formats if str(f.get("itag")) == itag and f.get("url")), None)
        if not media:
            continue
        url = media["url"]
        if url.startswith("/"):
            url = host + url
        record = {"itag": media["itag"], "host": urlsplit(url).netloc}
        try:
            with urlopen(Request(url, headers={"User-Agent": "Mozilla/5.0", "Range": "bytes=0-31"}), timeout=8) as response:
                data = response.read(32)
                record.update(http=response.status, mime=response.headers.get("Content-Type"),
                              contentRange=response.headers.get("Content-Range"),
                              bytes=len(data), mp4=b"ftyp" in data, host=urlsplit(response.url).netloc)
        except HTTPError as error:
            record["http"] = error.code
        except Exception as error:
            record["error"] = type(error).__name__
        summary.append(record)
except HTTPError as error:
    summary.append({"metadataHTTP": error.code})
except Exception as error:
    summary.append({"metadataError": type(error).__name__})
try:
    with urlopen(Request("https://tuberepair.uptimetrackers.com/getvideo/" + video_id,
                         headers={"User-Agent": "Mozilla/5.0", "Range": "bytes=0-31"}), timeout=8) as response:
        data = response.read(32)
        summary.append({"TubeRepairHTTP": response.status, "mime": response.headers.get("Content-Type"),
                        "bytes": len(data), "mp4": b"ftyp" in data, "host": urlsplit(response.url).netloc})
except HTTPError as error:
    summary.append({"TubeRepairHTTP": error.code})
except Exception as error:
    summary.append({"TubeRepairError": type(error).__name__})
print(json.dumps(summary, indent=2))
