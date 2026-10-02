#!/usr/bin/env python3
"""Make a Debian 2.0 package using gzip and ustar for old iPhone dpkg."""
import gzip
import io
from pathlib import Path
import sys
import tarfile

stage, output = map(Path, sys.argv[1:])


def archive(directory, paths):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for path in paths:
            info = tar.gettarinfo(str(path), arcname="./" + str(path.relative_to(directory)))
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            info.mode = 0o755 if path.is_dir() or path.name == "YouTubeDirect" else 0o644
            if path.is_file():
                with path.open("rb") as data:
                    tar.addfile(info, data)
            else:
                tar.addfile(info)
    return gzip.compress(stream.getvalue(), mtime=0)


control = archive(stage / "DEBIAN", sorted((stage / "DEBIAN").rglob("*")))
data = archive(stage, sorted(path for path in stage.rglob("*") if "DEBIAN" not in path.parts))
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("wb") as package:
    package.write(b"!<arch>\n")
    for name, content in [("debian-binary", b"2.0\n"), ("control.tar.gz", control), ("data.tar.gz", data)]:
        header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(content):<10}`\n"
        package.write(header.encode("ascii"))
        package.write(content)
        if len(content) % 2:
            package.write(b"\n")
