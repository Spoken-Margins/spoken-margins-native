#!/usr/bin/env python3
"""Validate every vendored Supertonic payload against the checked manifest."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "App/SpokenMarginsApp/Resources/Supertonic"
MANIFEST_PATH = ASSET_ROOT / "asset-manifest.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


LFS_HEADER = b"version https://git-lfs.github.com/spec/v1\n"


def lfs_pointer(path: Path) -> dict[str, str] | None:
    """The fields of a Git LFS pointer file (a small text file standing in for the real one), else None."""
    if path.stat().st_size > 1024:
        return None
    data = path.read_bytes()
    if not data.startswith(LFS_HEADER):
        return None
    fields = (line.partition(" ") for line in data.decode("utf-8", "replace").splitlines())
    return {key: value for key, _, value in fields}


def main() -> int:
    allow_pointers = "--allow-lfs-pointers" in sys.argv[1:]
    pointers = 0
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    expected = {entry["path"]: entry for entry in manifest["files"]}
    provenance = manifest.get("provenance", {})
    failures: list[str] = []

    if manifest.get("modelRevision") != "3cadd1ee6394adea1bd021217a0e650ede09a323":
        failures.append("modelRevision is not the approved pinned revision")
    if manifest.get("quantizedArchive", {}).get("sha256") != (
        "82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427"
    ):
        failures.append("quantized archive SHA-256 is not the approved pinned archive")

    for relative_path, entry in expected.items():
        provenance_key = entry.get("provenance")
        provenance_entry = provenance.get(provenance_key, {})
        if not provenance_entry.get("source") or not provenance_entry.get("version"):
            failures.append(f"provenance: {relative_path} has no source and version")
        path = ASSET_ROOT / relative_path
        if not path.is_file():
            failures.append(f"missing: {relative_path}")
            continue
        pointer = lfs_pointer(path) if allow_pointers else None
        if pointer is not None:
            # No LFS download here. The pointer records the real file's size and SHA-256, so it still has to agree
            # with the manifest; a stale or edited pointer fails like a stale file.
            pointers += 1
            if pointer.get("size") != str(entry["bytes"]):
                failures.append(f"pointer size: {relative_path} expected={entry['bytes']} pointer={pointer.get('size')}")
            elif pointer.get("oid") != f"sha256:{entry['sha256']}":
                failures.append(f"pointer sha256: {relative_path} expected={entry['sha256']} pointer={pointer.get('oid')}")
            continue
        size = path.stat().st_size
        if size != entry["bytes"]:
            failures.append(f"size: {relative_path} expected={entry['bytes']} actual={size}")
            continue
        actual_hash = sha256(path)
        if actual_hash != entry["sha256"]:
            failures.append(
                f"sha256: {relative_path} expected={entry['sha256']} actual={actual_hash}"
            )

    actual = {
        path.relative_to(ASSET_ROOT).as_posix()
        for path in ASSET_ROOT.rglob("*")
        if path.is_file() and path != MANIFEST_PATH
    }
    for unexpected in sorted(actual - expected.keys()):
        failures.append(f"untracked: {unexpected}")

    if failures:
        print("Supertonic asset validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    note = f" ({pointers} checked as Git LFS pointers, not downloaded)" if pointers else ""
    print(f"Validated {len(expected)} Supertonic files{note}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
