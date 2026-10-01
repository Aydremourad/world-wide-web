"""Run the private token provider and legacy YouTube server together."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.request


def main():
    root = Path(__file__).resolve().parent
    provider_dir = Path(os.environ.get('YOUTUBE_TOKEN_SERVER_DIR', '/opt/bgutil/server'))
    provider = subprocess.Popen([
        'node', '--max-old-space-size=160', str(provider_dir / 'build/main.js'),
        '--host', '127.0.0.1', '--port', '4416',
    ], cwd=provider_dir)
    app = None

    def stop(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if provider.poll() is not None:
                raise RuntimeError('Token provider stopped during startup')
            try:
                with urllib.request.urlopen('http://127.0.0.1:4416/ping', timeout=1) as r:
                    if r.status == 200:
                        break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError('Token provider did not become ready')
        print('Private YouTube token provider is ready', flush=True)
        app = subprocess.Popen([sys.executable, str(root / 'app.py')])
        while True:
            if provider.poll() is not None:
                raise RuntimeError('Token provider stopped; restarting service is required')
            if app.poll() is not None:
                return app.returncode
            time.sleep(0.25)
    finally:
        for child in (app, provider):
            if child is not None and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == '__main__':
    sys.exit(main())
