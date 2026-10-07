import os
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

APP_DIR = Path("/app/modified-tuberepair/tuberepair")
PROVIDER_DIR = Path("/opt/bgutil/server")

provider = None
app = None


def terminate_child(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def shutdown(signum=None, frame=None):
    terminate_child(app)
    terminate_child(provider)
    raise SystemExit(0)


signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

try:
    provider = subprocess.Popen(
        [
            "node",
            str(PROVIDER_DIR / "build/main.js"),
            "--host", "127.0.0.1",
            "--port", "4416",
        ],
        cwd=PROVIDER_DIR,
    )

    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if provider.poll() is not None:
            raise RuntimeError("PO-token provider exited during startup")
        try:
            with urllib.request.urlopen("http://127.0.0.1:4416/ping", timeout=1) as response:
                if response.status == 200:
                    print("PO-token provider ready", flush=True)
                    break
        except Exception:
            time.sleep(0.25)
    else:
        raise RuntimeError("PO-token provider did not become ready")

    app = subprocess.Popen([sys.executable, "main.py"], cwd=APP_DIR)
    return_code = app.wait()
    raise SystemExit(return_code)
finally:
    terminate_child(app)
    terminate_child(provider)
