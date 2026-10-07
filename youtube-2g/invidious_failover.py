import os
import threading
from urllib.parse import urlsplit

import requests

DEFAULT_INSTANCES = [
    "https://inv.nadeko.net",
    "https://invidious.nerdvpn.de",
    "https://yt.chocolatemoo53.com",
    "https://invidious.tiekoetter.com",
    "https://invidious.f5.si",
]

_raw = os.environ.get("INVIDIOUS_INSTANCES", "")
if _raw.strip():
    INSTANCES = [x.strip().rstrip("/") for x in _raw.split(",") if x.strip()]
else:
    INSTANCES = DEFAULT_INSTANCES[:]

_active_index = 0
_lock = threading.Lock()

HEADERS = {
    "User-Agent": "Mozilla/5.0",
    "Accept": "application/json",
}


def _ordered_instances():
    with _lock:
        start = _active_index % len(INSTANCES)
    return [(start + i) % len(INSTANCES) for i in range(len(INSTANCES))]


def _remember(index):
    global _active_index
    with _lock:
        _active_index = index


def fetch_path(path, params=None, session=None, proxies=None, timeout=5):
    requester = session or requests
    last_json_error = None

    if not path.startswith("/"):
        path = "/" + path

    for index in _ordered_instances():
        base = INSTANCES[index]
        url = base + path

        try:
            response = requester.get(
                url,
                params=params,
                headers=HEADERS,
                proxies=proxies,
                timeout=timeout,
            )

            content_type = (response.headers.get("content-type") or "").lower()

            if response.status_code < 200 or response.status_code >= 300:
                print(
                    "INVIDIOUS FAILOVER:",
                    base,
                    "HTTP",
                    response.status_code,
                    flush=True,
                )
                continue

            if "json" not in content_type:
                print(
                    "INVIDIOUS FAILOVER:",
                    base,
                    "non-JSON response",
                    content_type,
                    flush=True,
                )
                continue

            try:
                data = response.json()
            except Exception as exc:
                print(
                    "INVIDIOUS FAILOVER:",
                    base,
                    "bad JSON",
                    repr(exc),
                    flush=True,
                )
                continue

            if isinstance(data, dict) and data.get("error"):
                last_json_error = data
                print(
                    "INVIDIOUS FAILOVER:",
                    base,
                    "API error:",
                    str(data.get("error"))[:180],
                    flush=True,
                )
                continue

            _remember(index)
            print("INVIDIOUS ACTIVE:", base, flush=True)
            return data

        except requests.RequestException as exc:
            print(
                "INVIDIOUS FAILOVER:",
                base,
                type(exc).__name__,
                flush=True,
            )
        except Exception as exc:
            print(
                "INVIDIOUS FAILOVER:",
                base,
                repr(exc),
                flush=True,
            )

    if last_json_error is not None:
        return last_json_error

    return None


def fetch_url(url, session=None, proxies=None, timeout=5):
    parsed = urlsplit(url)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    return fetch_path(
        path,
        session=session,
        proxies=proxies,
        timeout=timeout,
    )
