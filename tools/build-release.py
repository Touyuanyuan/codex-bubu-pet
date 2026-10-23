#!/usr/bin/env python3
"""Build a reproducible, allowlisted release using only Python's standard library."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
from urllib.parse import parse_qs, urlsplit
import zipfile

VERSION = "1.0.0"
IMAGE_SHA256 = "4c86cc31e3ccc9be7628ca6db8f8bde45c34b2b74fb14e94aa874306eaf80a91"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
# Deliberately enumerate every distributed file. Never recursively package a workspace.
FILES = (
    ".gitattributes",
    ".gitignore",
    "ASSET-NOTICE.md",
    "CHANGELOG.md",
    "CREDITS.md",
    "LICENSE",
    "README.md",
    "docs/contact-sheet.png",
    "install.cmd",
    "install.ps1",
    "install-link.txt",
    "install-in-codex.url",
    "install.html",
    "pet/pet.json",
    "pet/spritesheet.webp",
    "preview.html",
    "tests/test-install.ps1",
    "tools/build-release.py",
    "tools/make-install-link.ps1",
)
BINARY_SUFFIXES = {".png", ".webp"}
SENSITIVE_PATTERNS = (
    ("personal Windows path", re.compile(r"[A-Za-z]:[\\/]Users[\\/](?!Public\b|Default\b)[^\s<>\"']+", re.I)),
    ("personal Unix path", re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/")),
    ("local session path", re.compile(r"\.codex[\\/](?:sessions|visualizations|memories)[\\/]", re.I)),
    ("private key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b")),
    ("API token", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}\b")),
    ("authorization credential", re.compile(r"Authorization\s*[:=]\s*[\"']?(?:Bearer|Basic)\s+[A-Za-z0-9+/_.=-]{16,}", re.I)),
    ("credential assignment", re.compile(r"(?:api[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*[\"'][A-Za-z0-9+/_.=-]{20,}[\"']", re.I)),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def webp_size(data: bytes) -> tuple[int, int]:
    """Read the canvas dimensions from RIFF/WEBP without third-party decoders."""
    if len(data) < 20 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError("The sprite sheet is not a RIFF/WEBP image.")
    if struct.unpack_from("<I", data, 4)[0] + 8 != len(data):
        raise ValueError("The sprite sheet has an invalid RIFF length.")
    offset = 12
    while offset + 8 <= len(data):
        kind = data[offset : offset + 4]
        length = struct.unpack_from("<I", data, offset + 4)[0]
        chunk = data[offset + 8 : offset + 8 + length]
        if len(chunk) != length:
            raise ValueError("The sprite sheet has a truncated WEBP chunk.")
        if kind == b"VP8X" and length >= 10:
            return int.from_bytes(chunk[4:7], "little") + 1, int.from_bytes(chunk[7:10], "little") + 1
        if kind == b"VP8L" and length >= 5 and chunk[0] == 0x2F:
            bits = int.from_bytes(chunk[1:5], "little")
            return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if kind == b"VP8 " and length >= 10 and chunk[3:6] == b"\x9d\x01\x2a":
            return struct.unpack_from("<H", chunk, 6)[0] & 0x3FFF, struct.unpack_from("<H", chunk, 8)[0] & 0x3FFF
        offset += 8 + length + (length % 2)
    raise ValueError("The sprite sheet has no recognized WEBP dimensions.")


def read_package_files() -> dict[str, bytes]:
    missing = [name for name in FILES if not (PROJECT_ROOT / name).is_file()]
    if missing:
        raise ValueError("Missing release files: " + ", ".join(missing))
    contents = {}
    for name in sorted(FILES):
        path = PROJECT_ROOT / name
        if path.is_symlink() or not path.resolve().is_relative_to(PROJECT_ROOT):
            raise ValueError(f"Refusing a symlink or external path: {name}")
        data = path.read_bytes()
        if path.suffix.lower() not in BINARY_SUFFIXES:
            text = data.decode("utf-8-sig")
            for label, pattern in SENSITIVE_PATTERNS:
                if pattern.search(text):
                    # Report the file and category, never echo a matched credential.
                    raise ValueError(f"Pre-publication scan found {label} in {name}.")
            if "\x00" in text:
                raise ValueError(f"Unexpected NUL byte in text file: {name}")
        contents[name] = data
    return contents


def validate_payload(contents: dict[str, bytes]) -> dict:
    manifest = json.loads(contents["pet/pet.json"].decode("utf-8"))
    required = {
        "id": "bubu-camera",
        "displayName": "相机布布",
        "spriteVersionNumber": 2,
        "spritesheetPath": "spritesheet.webp",
    }
    for key, expected in required.items():
        if manifest.get(key) != expected:
            raise ValueError(f"Unexpected pet manifest value for {key}.")
    if not isinstance(manifest.get("description"), str) or not manifest["description"].strip():
        raise ValueError("The pet description is missing.")
    sprite = contents["pet/spritesheet.webp"]
    if sha256(sprite) != IMAGE_SHA256:
        raise ValueError("Sprite SHA-256 differs from the approved v1.0.0 image.")
    if webp_size(sprite) != (1536, 2288):
        raise ValueError("Sprite dimensions must be 1536 x 2288 pixels.")
    uri = contents["install-link.txt"].decode("utf-8-sig").strip()
    parsed = urlsplit(uri)
    if (parsed.scheme, parsed.netloc, parsed.path, parsed.fragment) != ("codex", "pets", "/install", ""):
        raise ValueError("Unexpected Codex install URI.")
    query = parse_qs(parsed.query, strict_parsing=True)
    if set(query) != {"name", "imageUrl", "description", "spriteVersionNumber"} or any(len(v) != 1 for v in query.values()):
        raise ValueError("Install URI must contain exactly the four documented parameters.")
    if query["name"][0] != manifest["displayName"] or query["description"][0] != manifest["description"] or query["spriteVersionNumber"] != ["2"]:
        raise ValueError("Install URI metadata differs from pet.json.")
    image_url = urlsplit(query["imageUrl"][0])
    if image_url.scheme != "https" or image_url.netloc != "raw.githubusercontent.com" or image_url.query or image_url.fragment:
        raise ValueError("Install image URL must use HTTPS raw.githubusercontent.com.")
    if not re.fullmatch(r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/v" + re.escape(VERSION) + r"/pet/spritesheet\.webp", image_url.path):
        raise ValueError("Install image URL must be pinned to the matching release tag.")
    if "URL=" + uri not in contents["install-in-codex.url"].decode("utf-8-sig"):
        raise ValueError("Internet shortcut differs from install-link.txt.")
    return manifest


def build() -> Path:
    contents = read_package_files()
    validate_payload(contents)
    dist = PROJECT_ROOT / "dist"
    if dist.is_symlink():
        raise ValueError("Refusing a symlinked dist directory.")
    dist.mkdir(exist_ok=True)
    archive_name = f"codex-bubu-pet-v{VERSION}-windows.zip"
    prefix = f"codex-bubu-pet-v{VERSION}"
    destination = dist / archive_name
    temporary = dist / (archive_name + ".tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in contents.items():
            info = zipfile.ZipInfo(f"{prefix}/{name}", date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    with zipfile.ZipFile(temporary) as archive:
        if archive.testzip() is not None:
            raise ValueError("ZIP integrity check failed.")
        expected = [f"{prefix}/{name}" for name in contents]
        if archive.namelist() != expected:
            raise ValueError("ZIP file list differs from the allowlist.")
        for name, data in contents.items():
            if archive.read(f"{prefix}/{name}") != data:
                raise ValueError(f"ZIP readback differs for {name}.")
    temporary.replace(destination)
    report = {
        "project": "codex-bubu-pet",
        "version": VERSION,
        "archive": archive_name,
        "archiveSha256": sha256(destination.read_bytes()),
        "sprite": {"version": 2, "width": 1536, "height": 2288, "sha256": IMAGE_SHA256},
        "checks": {"allowlist": "passed", "sensitiveTextScan": "passed", "spriteHashAndHeader": "passed", "zipReadback": "passed"},
        "files": [{"path": name, "size": len(data), "sha256": sha256(data)} for name, data in contents.items()],
    }
    report_path = dist / "package-file-manifest.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    sums = "".join(f"{sha256(path.read_bytes())}  {path.name}\n" for path in (destination, report_path))
    (dist / "SHA256SUMS.txt").write_text(sums, encoding="ascii")
    print(f"Built {archive_name}: {len(contents)} allowlisted files, {destination.stat().st_size:,} bytes")
    print(f"SHA-256: {report['archiveSha256']}")
    print("Local validation passed. This build does not publish or verify online URLs.")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate source files without writing a ZIP.")
    args = parser.parse_args()
    try:
        if args.check:
            contents = read_package_files()
            validate_payload(contents)
            print(f"Local pre-publication checks passed for {len(contents)} files.")
        else:
            build()
        return 0
    except (OSError, UnicodeError, ValueError, zipfile.BadZipFile) as error:
        print(f"Build stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
