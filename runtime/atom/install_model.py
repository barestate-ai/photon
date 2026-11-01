#!/usr/bin/env python3
"""Install a frozen Atom package from HTTPS or file://, verifying every byte."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import signal
import sys
import tempfile
from urllib.parse import quote, urlparse, unquote
from urllib.request import urlopen


def verify_directory(directory: Path, manifest: dict):
    total = 0
    for entry in manifest["files"]:
        relative = PurePosixPath(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe model manifest path")
        path = directory / relative
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Missing model file: {entry['path']}")
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(block)
                digest.update(block)
        if size != entry["bytes"] or digest.hexdigest() != entry["sha256"]:
            raise ValueError(f"Model checksum mismatch: {entry['path']}")
        total += size
    if total != manifest["bytesTotal"]:
        raise ValueError("Model total bytes do not match manifest")
    return total


def install(manifest_path: Path, source: str, destination: Path):
    manifest = json.loads(manifest_path.read_text())
    if not source:
        raise ValueError("No model host configured. Import a local Atom package or configure a release source.")
    parsed = urlparse(source)
    if parsed.scheme not in ("https", "file"):
        raise ValueError("Model source must use HTTPS or file://")
    destination = destination.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Keep an existing valid install intact; concurrent installers share a lock.
    with (destination.parent / ".atom-install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.exists():
            return {"installed": True, "bytes": verify_directory(destination, manifest),
                    "directory": str(destination), "reused": True}
        if shutil.disk_usage(destination.parent).free < manifest["hardware"]["minFreeBytes"]:
            raise ValueError("At least 400 MB of free disk space is required")
        with tempfile.TemporaryDirectory(prefix=".atom-download-", dir=destination.parent) as temporary:
            staging = Path(temporary) / "model"
            staging.mkdir()
            complete = 0
            for entry in manifest["files"]:
                relative = PurePosixPath(entry["path"])
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError("Unsafe model manifest path")
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                if parsed.scheme == "file":
                    source_path = Path(unquote(parsed.path)) / relative
                    if source_path.is_symlink():
                        raise ValueError("Model source symlinks are not accepted")
                    shutil.copyfile(source_path, target)
                else:
                    url = source.rstrip("/") + "/" + quote(str(relative))
                    with urlopen(url, timeout=60) as response, target.open("wb") as output:
                        if urlparse(response.url).scheme != "https":
                            raise ValueError("Model source redirected away from HTTPS")
                        downloaded = 0
                        while block := response.read(1024 * 1024):
                            downloaded += len(block)
                            if downloaded > entry["bytes"]:
                                raise ValueError("Model download exceeds manifest size")
                            output.write(block)
                complete += entry["bytes"]
                print(json.dumps({"event": "progress", "bytes": complete,
                                  "total": manifest["bytesTotal"], "file": entry["path"]}),
                      file=sys.stderr, flush=True)
            verify_directory(staging, manifest)
            notices = Path(__file__).resolve().parent / "licenses/atom"
            shutil.copytree(notices, staging / "licenses/atom")
            staging.rename(destination)
        return {"installed": True, "bytes": manifest["bytesTotal"], "directory": str(destination), "reused": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parent / "model-manifest.json")
    parser.add_argument("--source", default="")
    parser.add_argument("--destination", type=Path, default=Path.home() / "Library/Application Support/Barestate/models/atom/tinyclick-4bit-v1/tinyclick-4bit")
    args = parser.parse_args()
    # Settings cancel and quit send TERM; exiting through SystemExit removes the staging directory.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    try:
        result = install(args.manifest, args.source, args.destination)
        print(json.dumps({"ok": True, "result": result}))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
