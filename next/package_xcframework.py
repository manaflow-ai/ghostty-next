#!/usr/bin/env python3
"""Package GhosttyNextKit.xcframework for a ghostty-next release.

Writes three files into --out:

  GhosttyNextKit.xcframework.zip  deterministic zip (sorted entries, fixed
                              timestamps and modes), usable as a SwiftPM
                              binaryTarget(url:checksum:)
  SHA256SUMS                  sha256 of the zip and of the manifest
  manifest.json               source commit, upstream base, toolchain,
                              flags, and the sha256 of every slice library

The zip sha256 equals what `swift package compute-checksum` prints, so the
iOS app pins one value for both download verification and SwiftPM.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import stat
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = "GhosttyNextKit.xcframework"
FIXED_DATE = (1980, 1, 1, 0, 0, 0)
# Slices the ios target must produce (Info.plist LibraryIdentifier).
REQUIRED_SLICES = {"ios-arm64", "ios-arm64-simulator", "macos-arm64_x86_64"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def collect(xcframework: Path) -> list[Path]:
    entries: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(xcframework):
        dirnames.sort()
        base = Path(dirpath)
        entries.append(base)
        for name in sorted(filenames):
            path = base / name
            if path.is_symlink():
                raise SystemExit(f"symlink in xcframework: {path}")
            if name.startswith("._") or name == ".DS_Store":
                raise SystemExit(f"unexpected metadata file: {path}")
            entries.append(path)
    return sorted(entries, key=lambda p: p.relative_to(xcframework.parent).as_posix())


def write_zip(xcframework: Path, archive: Path) -> None:
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in collect(xcframework):
            rel = path.relative_to(xcframework.parent).as_posix()
            if path.is_dir():
                info = zipfile.ZipInfo(rel + "/", date_time=FIXED_DATE)
                info.create_system = 3
                info.external_attr = (stat.S_IFDIR | 0o755) << 16
                zf.writestr(info, b"")
                continue
            mode = 0o755 if os.access(path, os.X_OK) else 0o644
            info = zipfile.ZipInfo(rel, date_time=FIXED_DATE)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with path.open("rb") as handle:
                zf.writestr(info, handle.read(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def slices(xcframework: Path) -> list[dict]:
    with (xcframework / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    result = []
    for lib in info.get("AvailableLibraries", []):
        ident = lib["LibraryIdentifier"]
        library = xcframework / ident / lib["LibraryPath"]
        headers = xcframework / ident / lib.get("HeadersPath", "Headers")
        for required in ("ghostty.h", "module.modulemap"):
            if not (headers / required).is_file():
                raise SystemExit(f"{ident}: missing {required}")
        if "module GhosttyNextKit" not in (headers / "module.modulemap").read_text():
            raise SystemExit(f"{ident}: module map does not declare GhosttyNextKit")
        # SwiftPM refuses a binary target's static archive without the lib
        # prefix ("Static libraries should be prefixed with lib").
        if not Path(lib["LibraryPath"]).name.startswith("lib"):
            raise SystemExit(f"{ident}: {lib['LibraryPath']} must start with lib for SwiftPM")
        result.append({
            "identifier": ident,
            "platform": lib.get("SupportedPlatform"),
            "variant": lib.get("SupportedPlatformVariant"),
            "architectures": lib.get("SupportedArchitectures", []),
            "library": f"{ident}/{lib['LibraryPath']}",
            "sha256": sha256_file(library),
            "bytes": library.stat().st_size,
        })
    found = {s["identifier"] for s in result}
    if found != REQUIRED_SLICES:
        raise SystemExit(f"slices {sorted(found)} != required {sorted(REQUIRED_SLICES)}")
    return sorted(result, key=lambda s: s["identifier"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcframework", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--flavor", required=True)
    parser.add_argument("--zig-version", required=True)
    parser.add_argument("--zig-sha256", required=True)
    parser.add_argument("--flags", required=True)
    args = parser.parse_args()

    xcframework = args.xcframework.resolve()
    if xcframework.name != ROOT:
        raise SystemExit(f"expected {ROOT}, got {xcframework.name}")
    repo = Path(__file__).resolve().parent.parent
    args.out.mkdir(parents=True, exist_ok=True)

    archive = args.out / f"{ROOT}.zip"
    write_zip(xcframework, archive)
    archive_sha = sha256_file(archive)

    commit = run("git", "-C", str(repo), "rev-parse", "HEAD")
    manifest = {
        "schema": 1,
        "name": "GhosttyNextKit",
        "repository": "manaflow-ai/ghostty-next",
        "commit": commit,
        "upstream_base": (repo / "next" / "UPSTREAM_BASE").read_text().strip(),
        "flavor": args.flavor,
        "release_tag": f"xcframework-{commit}-{args.flavor}",
        "archive": {"name": archive.name, "sha256": archive_sha, "bytes": archive.stat().st_size},
        "toolchain": {
            "zig": args.zig_version,
            "zig_sha256": args.zig_sha256,
            "xcode": run("xcodebuild", "-version").replace("\n", " "),
            "iphoneos_sdk": run("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
            "iphonesimulator_sdk": run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
            "macosx_sdk": run("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        },
        "flags": args.flags.split(),
        "slices": slices(xcframework),
    }
    manifest_path = args.out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (args.out / "SHA256SUMS").write_text(
        f"{archive_sha}  {archive.name}\n{sha256_file(manifest_path)}  manifest.json\n"
    )
    print(json.dumps({"archive_sha256": archive_sha, "release_tag": manifest["release_tag"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
