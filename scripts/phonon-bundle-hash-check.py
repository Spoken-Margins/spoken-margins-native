#!/usr/bin/env python3
"""Checks a local copy of Gradium's phonon-31m-en-coreml.zip against the voice catalog (#2704).

The installer takes Phonon's files out of this zip by the members and SHA-256 values in
Contracts/voice-models/sources.json. This script reads the real 137 MB zip and confirms:
  - the zip's own size and SHA-256 match the catalog's upstream archive;
  - every catalog file's archive member exists, with the catalog's size and SHA-256;
  - the bundle's own bundle.json agrees with the catalog for every file it lists.

The host test VoiceModelZipArchiveTests covers the reader and installer on a small zip of the same shape.
This one is on demand only; run it whenever the catalog's Phonon entry or the upstream release changes.

    python3 scripts/phonon-bundle-hash-check.py ~/Downloads/phonon-31m-en-coreml.zip
"""
import hashlib
import json
import sys
import zipfile
from pathlib import Path

VOICE_ID = "phonon-31m-en"
ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Contracts" / "voice-models" / "sources.json"


def sha256_of(stream):
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1 << 20), b""):
        digest.update(chunk)
    return digest.hexdigest()


def find_voice(node):
    if isinstance(node, dict):
        if node.get("id") == VOICE_ID and "files" in node:
            return node
        node = list(node.values())
    if isinstance(node, list):
        for child in node:
            found = find_voice(child)
            if found:
                return found
    return None


def main():
    if len(sys.argv) != 2:
        print("usage: python3 scripts/phonon-bundle-hash-check.py <path to phonon-31m-en-coreml.zip>", file=sys.stderr)
        return 2
    zip_path = Path(sys.argv[1])
    voice = find_voice(json.loads(SOURCES.read_text()))
    if voice is None:
        print(f"{VOICE_ID} not found in {SOURCES}", file=sys.stderr)
        return 1
    failures = []

    archive = next(a for a in voice["upstreamArchives"] if a["id"] == "coreml-bundle")
    size = zip_path.stat().st_size
    with zip_path.open("rb") as handle:
        digest = sha256_of(handle)
    if size != archive["byteCount"]:
        failures.append(f"zip is {size} bytes, catalog says {archive['byteCount']}")
    if digest != archive["sha256"]:
        failures.append(f"zip sha256 {digest}, catalog says {archive['sha256']}")
    if not zipfile.is_zipfile(zip_path):
        failures.append(f"{zip_path} is not a zip")
        print("\n".join(failures), file=sys.stderr)
        return 1

    with zipfile.ZipFile(zip_path) as bundle:
        names = set(bundle.namelist())
        actual = {}
        for entry in voice["files"]:
            member = entry["archiveMember"]["member"]
            if member not in names:
                failures.append(f"missing member {member}")
                continue
            with bundle.open(member) as stream:
                actual[entry["path"]] = sha256_of(stream)
            if bundle.getinfo(member).file_size != entry["byteCount"]:
                failures.append(f"{entry['path']}: {bundle.getinfo(member).file_size} bytes, catalog says {entry['byteCount']}")
            if actual[entry["path"]] != entry["sha256"]:
                failures.append(f"{entry['path']}: sha256 {actual[entry['path']]}, catalog says {entry['sha256']}")

        listing_member = next((e["archiveMember"]["member"] for e in voice["files"] if e["path"] == "bundle.json"), None)
        if listing_member in names:
            listed = json.loads(bundle.read(listing_member))
            for item in listed.get("files", []):
                if item["path"] in actual and actual[item["path"]] != item["sha256"]:
                    failures.append(f"{item['path']}: bundle.json says {item['sha256']}, member hashes to {actual[item['path']]}")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"OK: {len(voice['files'])} catalog files match {zip_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
