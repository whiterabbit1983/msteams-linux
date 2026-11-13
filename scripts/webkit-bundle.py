#!/usr/bin/env python3
"""Version, validate and transfer the installed WebKit without executing it."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    "lib/libwebkit2gtk-4.1.so",
    "lib/libjavascriptcoregtk-4.1.so",
    "lib/webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so",
    "libexec/webkit2gtk-4.1/WebKitWebProcess",
    "libexec/webkit2gtk-4.1/WebKitNetworkProcess",
)
MANIFEST = ".msteams-webkit.json"


def profile(root=ROOT):
    config = json.loads((root / "scripts/webkit-profile.json").read_text())
    if config["format"] != 1 or config["platform"] != "ubuntu-24.04-x86_64":
        raise ValueError("Unsupported WebKit profile format or platform")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", config["source_version"]):
        raise ValueError("Invalid WebKit source version")
    if not re.fullmatch(r"[0-9a-f]{64}", config["source_sha256"]):
        raise ValueError("Invalid WebKit source SHA256")
    options = config["cmake_options"]
    if not isinstance(options, list) or not all(isinstance(option, str) and re.fullmatch(r"-D[A-Z0-9_]+=[A-Za-z0-9_/.-]+", option) for option in options):
        raise ValueError("Invalid WebKit CMake options")
    effective = dict(option[2:].split("=", 1) for option in options)
    required = {"ENABLE_WEB_RTC": "ON", "ENABLE_MEDIA_STREAM": "ON", "USE_GSTREAMER_WEBRTC": "ON", "USE_GTK4": "OFF", "USE_SOUP2": "OFF"}
    if any(effective.get(key) != value for key, value in required.items()):
        raise ValueError("WebKit profile must preserve GTK3/Soup3 and WebRTC")
    return config


def identity(root=ROOT):
    # Build drivers, comments and CI changes do not invalidate the binary ABI.
    # Runtime-affecting changes outside these files must bump build_revision.
    digest = hashlib.sha256()
    digest.update(json.dumps(profile(root), sort_keys=True).encode())
    for name in ("webkitgtk-relocatable.patch", "webrtc-packages.sh"):
        digest.update((root / "scripts" / name).read_bytes())
    config = profile(root)
    return f"webkitgtk-{config['source_version']}-{config['platform']}-{digest.hexdigest()[:16]}"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check(prefix):
    prefix = prefix.resolve()
    for name in REQUIRED:
        path = prefix / name
        if not path.resolve().is_relative_to(prefix):
            raise ValueError(f"WebKit file escapes the install prefix: {name}")
        with path.open("rb") as source:
            header = source.read(20)
        if header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\x3e\x00":
            raise ValueError(f"Not an x86-64 Linux ELF file: {path}")


def pack(prefix, destination, root=ROOT):
    check(prefix)
    tag = identity(root)
    metadata = {
        "identity": tag,
        "profile": profile(root),
        "source_commit": os.environ.get("GITHUB_SHA", "unknown"),
        "bootstrap_cache_key": os.environ.get("BOOTSTRAP_CACHE_KEY", ""),
    }
    (prefix / MANIFEST).write_text(json.dumps(metadata, indent=2) + "\n")
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / f"{tag}.tar.gz"
    # Fast compression: the installed prefix is small compared with the build tree.
    with tarfile.open(archive, "w:gz", compresslevel=1) as bundle:
        for entry in sorted(prefix.iterdir()):
            bundle.add(entry, arcname=entry.name)
    archive.with_suffix(archive.suffix + ".sha256").write_text(f"{sha256(archive)}  {archive.name}\n")
    return archive


def unpack(archive, prefix, root=ROOT):
    checksum = archive.with_suffix(archive.suffix + ".sha256").read_text().split()
    if len(checksum) != 2 or checksum[1] != archive.name or checksum[0] != sha256(archive):
        raise ValueError("WebKit archive checksum mismatch")
    if prefix.exists():
        raise FileExistsError(f"Refusing to replace an existing WebKit install: {prefix}")
    prefix.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=prefix.parent) as directory:
        temporary = Path(directory) / "install"
        temporary.mkdir()
        with tarfile.open(archive, "r:gz") as bundle:
            # Reject escaping links, devices and traversal before installing.
            bundle.extractall(temporary, filter="data")
        metadata = json.loads((temporary / MANIFEST).read_text())
        if metadata.get("identity") != identity(root) or metadata.get("profile") != profile(root):
            raise ValueError("WebKit build profile mismatch")
        check(temporary)
        shutil.move(str(temporary), str(prefix))


def parallel_jobs(cpus, memory_bytes):
    # Leave 1 GiB for the OS; allow 3 GiB per memory-heavy unified compilation.
    gib = 1024 ** 3
    return max(1, min(cpus, max(1, (memory_bytes - gib) // (3 * gib))))


def available_jobs():
    cpus = len(os.sched_getaffinity(0))
    memory = int(next(line.split()[1] for line in Path("/proc/meminfo").read_text().splitlines()
                      if line.startswith("MemTotal:"))) * 1024
    limit = Path("/sys/fs/cgroup/memory.max")
    if limit.exists() and limit.read_text().strip().isdigit():
        memory = min(memory, int(limit.read_text()))
    quota = Path("/sys/fs/cgroup/cpu.max")
    if quota.exists():
        maximum, period = quota.read_text().split()
        if maximum != "max":
            cpus = min(cpus, max(1, int(maximum) // int(period)))
    return parallel_jobs(cpus, memory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("identity", "options", "version", "source-sha256", "check", "pack", "unpack", "jobs"))
    parser.add_argument("--prefix", type=Path, default=ROOT / ".webrtc-webkit/install")
    parser.add_argument("--directory", type=Path, default=ROOT / ".webrtc-webkit/bundle")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    if args.command == "identity":
        print(identity())
    elif args.command == "options":
        print("\n".join(profile()["cmake_options"]))
    elif args.command == "version":
        print(profile()["source_version"])
    elif args.command == "source-sha256":
        print(profile()["source_sha256"])
    elif args.command == "check":
        check(args.prefix)
        print("WebKit installed ELF files: OK")
    elif args.command == "pack":
        print(pack(args.prefix, args.directory))
    elif args.command == "unpack":
        if args.archive is None:
            parser.error("unpack requires --archive")
        unpack(args.archive, args.prefix)
        print("WebKit archive checksum, profile and ELF files: OK")
    elif args.command == "jobs":
        print(available_jobs())


if __name__ == "__main__":
    main()
