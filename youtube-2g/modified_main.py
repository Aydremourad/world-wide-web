import os
import sys
import shutil
import threading
from pathlib import Path

APP_ROOT = Path("/app/tuberepair")
DATA_ROOT = Path(os.environ.get("TUBEREPAIR_DATA_DIR", "/var/data"))
DATA_ROOT.mkdir(parents=True, exist_ok=True)

# Persist the pieces Modified TubeRepair otherwise keeps beside its source.
def persist_dir(name):
    local = APP_ROOT / name
    target = DATA_ROOT / name
    target.mkdir(parents=True, exist_ok=True)
    if local.exists() and not local.is_symlink():
        # Preserve seed/static files such as categories.cat.
        for item in local.iterdir():
            dest = target / item.name
            if not dest.exists():
                if item.is_dir():
                    shutil.copytree(item, dest)
                else:
                    shutil.copy2(item, dest)
        shutil.rmtree(local)
    elif local.is_symlink():
        local.unlink()
    local.symlink_to(target, target_is_directory=True)

def persist_file(name):
    local = APP_ROOT / name
    target = DATA_ROOT / name
    if local.exists() and not local.is_symlink() and not target.exists():
        shutil.copy2(local, target)
    if local.exists() or local.is_symlink():
        local.unlink()
    local.symlink_to(target)

for directory in ("data", "cache", "static"):
    persist_dir(directory)
for filename in ("serverID.txt", "metadata_cache.json"):
    persist_file(filename)

os.chdir(APP_ROOT)
sys.path.insert(0, str(APP_ROOT))

import config
from main import app
from api.video import cleanup_old_files
from waitress import serve

@app.get("/healthz")
def healthz():
    return {
        "status": "ok",
        "server": "Modified TubeRepair",
        "upstream_commit": os.environ.get("MODIFIED_TUBEREPAIR_COMMIT", "unknown"),
        "version": getattr(config, "VERSION", "unknown"),
        "playback_backend": "invidious-range-proxy-v1",
    }

@app.get("/diagnostics")
def diagnostics():
    token_file = DATA_ROOT / "data" / "tokens.json"
    return {
        "server": "Modified TubeRepair for iOS 3",
        "upstream_commit": os.environ.get("MODIFIED_TUBEREPAIR_COMMIT", "unknown"),
        "version": getattr(config, "VERSION", "unknown"),
        "playback_backend": "invidious-range-proxy-v1",
        "medium_quality": bool(getattr(config, "MEDIUM_QUALITY", True)),
        "hls_resolution": int(getattr(config, "HLS_RESOLUTION", 720)),
        "persistent_data_root": str(DATA_ROOT),
        "login_storage_present": token_file.exists(),
    }

if __name__ == "__main__":
    threading.Thread(target=cleanup_old_files, daemon=True).start()
    serve(
        app,
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "10000")),
        threads=int(os.environ.get("SERVER_THREADS", "8")),
    )
