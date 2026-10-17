#!/usr/bin/env python3
"""Publishes the voice catalog on the site and keeps it honest (#1818). Run it through scripts/voice-catalog.

The hand-kept list is Contracts/voice-models/sources.json: per voice, the pinned upstream URLs, whether our
mirror also serves a file, each file's reviewed size and SHA-256, and each licence with the reviewed text
beside it. Nothing in this module edits that list. A person changes it, in a PR, after looking.

  check    ask every source and licence text what it serves now; hold back anything that differs
  build    turn the list into the catalog payload (artifacts/voice-catalog/payload.json)
  sign     sign the payload with the key in the Mac's login Keychain; write Site/voices/v1/
  page     write the plain page, Site/voices/index.html, from the same payload
  publish  dry run by default; --apply uploads the mirror files and runs the site's deploy script
  keygen   once, on the Mac: make the signing key; prints its public half

The private key lives only in the login Keychain. It is never written to the repository, `artifacts/`,
a log or a command line (the Keychain is written through `security -i`, which reads its commands from
stdin). The fetches in `check` send a fixed User-Agent and nothing else: no identifiers, cookies or
query strings.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import difflib
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.client import HTTPException
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from voice_catalog_tools import SIGNING_CONTEXT, pretty, sha256_hex  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

SOURCES_SCHEMA_VERSION = "voice-model-sources.v1"
MANIFEST_SCHEMA_VERSION = "voice-model-catalog-manifest.v1"
SITE_BASE = "https://spokenmargins.proximitytoprogress.com/voices/"
CATALOG_PATH = "v1/catalog.json"
MANIFEST_PATH = "v1/manifest.json"
KEYCHAIN_SERVICE = "com.spokenmargins.voice-catalog-signing"
DEFAULT_KEY_ID = "sm-voices-1"
USER_AGENT = "SpokenMargins-voice-catalog-check"
MEBIBYTE = 1024 * 1024
LICENCE_TEXT_LIMIT = 2 * MEBIBYTE
ISSUE_DIFF_LINES = 150


class ToolError(Exception):
    """Something the person running the tool can fix; printed without a traceback."""


@dataclasses.dataclass
class Paths:
    root: Path = ROOT

    @property
    def sources(self) -> Path:
        return self.root / "Contracts/voice-models/sources.json"

    @property
    def schema(self) -> Path:
        return self.root / "Contracts/schemas/voice-model-catalog.schema.json"

    @property
    def site(self) -> Path:
        return self.root / "Site/voices"

    @property
    def out(self) -> Path:
        return self.root / "artifacts/voice-catalog"

    @property
    def payload(self) -> Path:
        return self.out / "payload.json"

    @property
    def state(self) -> Path:
        return self.out / "state.json"

    @property
    def held(self) -> Path:
        return self.out / "held.json"

    @property
    def deploy_script(self) -> Path:
        return self.root / "scripts/deploy-spoken-margins-site.sh"


# --- the hand-kept list ----------------------------------------------------------------------------------

def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def mirror_url(sources: dict, voice: dict, file: dict) -> str:
    return sources["mirrorBase"] + voice["mirror"]["directory"] + file["path"]


def voice_entry(sources: dict, voice: dict) -> dict:
    """One catalog voice, from its hand-kept entry: drops the notes and mirror settings, and appends our
    mirror to the sources of each file that has one."""
    files = []
    for file in voice["files"]:
        urls = list(file["upstream"])
        if file.get("mirrored"):
            urls.append(mirror_url(sources, voice, file))
        entry = {"path": file["path"], "byteCount": file["byteCount"], "sha256": file["sha256"], "sources": urls}
        if "licenseId" in file:
            entry["licenseId"] = file["licenseId"]
        if "origin" in file:
            entry["origin"] = file["origin"]
        files.append(entry)
    licenses = []
    for licence in voice["licenses"]:
        entry = {key: licence[key] for key in ("id", "name", "spdxId", "textURL", "textSHA256", "requiresAcceptance", "restrictionsSummary") if key in licence}
        licenses.append(entry)
    entry = {key: voice[key] for key in ("id", "displayName", "publisher", "version", "runtime", "minimumIOSVersion",
                                          "minimumMemoryMegabytes", "status", "supersededBy", "bundled") if key in voice}
    entry["files"] = files
    entry["licenses"] = licenses
    return entry


def build_catalog(sources: dict, catalog_version: int, issued_at: str) -> dict:
    return {
        "schemaVersion": "voice-model-catalog.v1",
        "catalogVersion": catalog_version,
        "issuedAt": issued_at,
        "voices": [voice_entry(sources, voice) for voice in sources["voices"]],
    }


def payload_bytes(catalog: dict) -> bytes:
    return pretty(catalog)


def supported_runtimes_in_app(root: Path) -> list[str] | None:
    """The runtimes SessionKit's verifier can run, read from its source so the two lists cannot drift."""
    verifier = root / "Packages/SessionKit/Sources/SessionKit/VoiceModelCatalogVerifier.swift"
    if not verifier.is_file():
        return None
    match = re.search(r"static let supportedRuntimes: Set<String> = \[([^\]]*)\]", verifier.read_text(encoding="utf-8"))
    return sorted(re.findall(r'"([^"]+)"', match.group(1))) if match else None


def validate_sources(sources: dict, paths: Paths = Paths()) -> list[str]:
    """Everything that can be wrong with the list without touching the network."""
    from jsonschema import Draft202012Validator, FormatChecker

    errors: list[str] = []
    where = str(paths.sources)
    if sources.get("schemaVersion") != SOURCES_SCHEMA_VERSION:
        errors.append(f"{where}: schemaVersion must be {SOURCES_SCHEMA_VERSION}")
    base = sources.get("mirrorBase", "")
    if not (base.startswith("https://") and base.endswith("/")):
        errors.append(f"{where}: mirrorBase must be an https URL ending in /")
    if not isinstance(sources.get("voices"), list) or not sources["voices"]:
        return errors + [f"{where}: no voices"]
    runtimes = supported_runtimes_in_app(paths.root)
    if runtimes is not None and sorted(sources.get("appRuntimes", [])) != runtimes:
        errors.append(f"{where}: appRuntimes {sorted(sources.get('appRuntimes', []))} differs from VoiceModelCatalogVerifier.supportedRuntimes {runtimes}")

    seen_ids: set[str] = set()
    for voice in sources["voices"]:
        label = f"{where}: voice {voice.get('id')!r}"
        if voice.get("id") in seen_ids:
            errors.append(f"{label}: duplicate id")
        seen_ids.add(voice.get("id"))
        mirror = voice.get("mirror", {})
        licence_ids = {licence.get("id") for licence in voice.get("licenses", [])}
        for file in voice.get("files", []):
            file_label = f"{label}: file {file.get('path')!r}"
            if file.get("mirrored") and not (mirror.get("allowed") and mirror.get("directory", "").endswith("/")):
                errors.append(f"{file_label}: mirrored, but the voice's mirror is not allowed or has no directory ending in /")
            if not file.get("upstream") and not file.get("mirrored"):
                errors.append(f"{file_label}: no upstream URL and not mirrored")
            if file.get("licenseId") and file["licenseId"] not in licence_ids:
                errors.append(f"{file_label}: licenseId {file['licenseId']!r} is not one of the voice's licences")
        if mirror.get("allowed") and not mirror.get("basis"):
            errors.append(f"{label}: mirror.allowed needs a mirror.basis saying why the licence allows redistributing")
        for licence in voice.get("licenses", []):
            reviewed = paths.root / licence.get("reviewedText", "")
            if not licence.get("reviewedText") or not reviewed.is_file():
                errors.append(f"{label}: licence {licence.get('id')!r} has no reviewedText file")
            elif licence.get("watchURL") and not licence["watchURL"].startswith("https://"):
                errors.append(f"{label}: licence {licence.get('id')!r}: watchURL must be https")
            elif sha256_hex(reviewed.read_bytes()) != licence.get("textSHA256"):
                errors.append(f"{label}: licence {licence.get('id')!r}: {licence['reviewedText']} does not hash to textSHA256")

    if errors:
        return errors
    catalog = build_catalog(sources, 1, "2000-01-01T00:00:00Z")
    validator = Draft202012Validator(load_json(paths.schema), format_checker=FormatChecker())
    for error in validator.iter_errors(catalog):
        location = ".".join(str(part) for part in error.path) or "<root>"
        errors.append(f"{where}: built catalog: {location}: {error.message}")
    return errors


def validate_sources_in_repo(paths: Paths = Paths()) -> list[str]:
    """The checks scripts/validate-contracts.py runs: the list is well formed, and its Supertonic entry is
    exactly the draft that scripts/voice_catalog_tools.py holds to the bundled files."""
    if not paths.sources.is_file():
        # A Contracts tree without the voice list (the sharing-fixture tests build one) has nothing to check.
        return []
    sources = load_json(paths.sources)
    errors = validate_sources(sources, paths)
    draft_path = paths.root / "Contracts/fixtures/voice-model-catalog/draft-supertonic.catalog.json"
    if not errors and draft_path.is_file():
        draft = next(v for v in load_json(draft_path)["voices"] if v["id"] == "supertonic-3-int8")
        built = next((v for v in build_catalog(sources, 1, "2000-01-01T00:00:00Z")["voices"] if v["id"] == "supertonic-3-int8"), None)
        if built != draft:
            errors.append(f"{paths.sources}: the supertonic-3-int8 entry no longer matches {draft_path.name}; "
                          "regenerate the draft (scripts/voice_catalog_tools.py draft) or fix the list")
    return errors


# --- HTTP ----------------------------------------------------------------------------------------------

@dataclasses.dataclass
class Probe:
    status: int | None
    size: int | None = None
    etag: str | None = None
    error: str | None = None


class HTTP:
    """The only network code. Every request carries the fixed User-Agent and nothing identifying."""

    def __init__(self, timeout: float = 60, attempts: int = 3, sleep: Callable[[float], None] = time.sleep):
        self.timeout = timeout
        self.attempts = attempts
        self.sleep = sleep

    def _open(self, url: str, method: str = "GET", headers: dict | None = None):
        request = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT, **(headers or {})})
        return urllib.request.urlopen(request, timeout=self.timeout)

    def _retrying(self, make: Callable[[], object]):
        """Retry a dropped connection or a 5xx; hand back any other HTTP answer as it is."""
        last: Exception | None = None
        for attempt in range(self.attempts):
            if attempt:
                self.sleep(2 ** attempt)
            try:
                return make()
            except urllib.error.HTTPError as error:
                if error.code < 500 and error.code != 429:
                    return error
                error.close()
                last = error
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError, HTTPException) as error:
                last = error
        raise last  # type: ignore[misc]

    def head(self, url: str) -> Probe:
        try:
            response = self._retrying(lambda: self._open(url, "HEAD"))
            if _status(response) in (403, 405, 501):
                # Some hosts refuse HEAD; ask for the first byte instead and read the total from Content-Range.
                response.close()
                response = self._retrying(lambda: self._open(url, "GET", {"Range": "bytes=0-0"}))
                total = (response.headers.get("Content-Range") or "").rpartition("/")[2]
                size = int(total) if total.isdigit() else _int(response.headers.get("Content-Length"))
            else:
                size = _int(response.headers.get("Content-Length"))
            status = _status(response)
            probe = Probe(200 if status == 206 else status, size, response.headers.get("ETag"))
            response.close()
            return probe
        except Exception as error:  # noqa: BLE001 - every failure is reported, not raised
            return Probe(None, error=f"{type(error).__name__}: {error}")

    def download(self, url: str, destination: Path) -> tuple[int, int, str]:
        """Stream the body to `destination`; returns (status, bytes, sha256)."""
        response = self._retrying(lambda: self._open(url))
        status = _status(response)
        if status != 200:
            response.close()
            return status, 0, ""
        destination.parent.mkdir(parents=True, exist_ok=True)
        expected = _int(response.headers.get("Content-Length"))
        digest, count = hashlib.sha256(), 0
        try:
            with destination.open("wb") as out:
                while chunk := response.read(1 << 20):
                    out.write(chunk)
                    digest.update(chunk)
                    count += len(chunk)
        finally:
            response.close()
        if expected is not None and count < expected:
            destination.unlink(missing_ok=True)
            raise ConnectionError(f"the connection closed after {count} of {expected} bytes")
        return status, count, digest.hexdigest()

    def text(self, url: str, limit: int = LICENCE_TEXT_LIMIT) -> tuple[int, bytes]:
        response = self._retrying(lambda: self._open(url))
        status = _status(response)
        try:
            body = response.read(limit + 1)
        finally:
            response.close()
        if len(body) > limit:
            raise ToolError(f"{url} is bigger than {limit} bytes; a licence text should not be")
        return status, body


def _status(response) -> int:
    return getattr(response, "status", None) or response.code


def _int(value) -> int | None:
    return int(value) if value is not None and str(value).isdigit() else None


# --- check --------------------------------------------------------------------------------------------

def _url_key(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()[:12]


def _load_state(paths: Paths) -> dict:
    try:
        return load_json(paths.state)
    except (OSError, ValueError):
        return {"sources": {}}


def _live_voice_ids(paths: Paths) -> set[str]:
    _, published, _ = read_published(paths)
    return {voice["id"] for voice in published["voices"]} if published else set()


def check_sources(sources: dict, http: HTTP, paths: Paths, now: str) -> dict:
    """Ask every file source and licence text what it serves now. Returns the report (also written to
    artifacts/voice-catalog/report.json); `held` lists everything someone has to look at before the catalog
    is published again. A warning (our mirror not published yet) does not hold anything back."""
    paths.held.unlink(missing_ok=True)  # a run that dies half way must not leave an older clean result behind
    state = _load_state(paths)
    known = state.setdefault("sources", {})
    licence_cache: dict[str, tuple[int | None, bytes | None, str | None]] = {}
    voices_report = []
    live = _live_voice_ids(paths)

    for voice in sources["voices"]:
        held: list[dict] = []
        warnings: list[dict] = []
        counts = {"files": len(voice["files"]), "unchanged": 0, "licences": len(voice["licenses"])}

        for file in voice["files"]:
            urls = [(url, "upstream") for url in file["upstream"]]
            if file.get("mirrored"):
                urls.append((mirror_url(sources, voice, file), "mirror"))
            for url, role in urls:
                subject = file["path"] if role == "upstream" else f"{file['path']} (mirror)"
                # Our mirror is only a warning until the voice is published; after that, where it is a file's
                # only source, a missing mirror file means the catalog advertises a download that cannot work.
                sole = role == "mirror" and not file["upstream"] and voice["id"] in live
                finding = _check_one_source(voice, file, url, "upstream" if sole else role, http, paths, known, now, counts)
                if finding:
                    (held if finding["severity"] == "held" else warnings).append({"subject": subject, "url": url, **finding})

        for licence in voice["licenses"]:
            finding = _check_licence(licence, http, paths, licence_cache)
            if finding:
                held.append({"subject": f"licence {licence['id']}", "url": licence["textURL"], **finding})

        voices_report.append({"id": voice["id"], "counts": counts, "held": held, "warnings": warnings})

    state["checkedAt"] = now
    paths.out.mkdir(parents=True, exist_ok=True)
    paths.state.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    report = {"checkedAt": now, "voices": voices_report}
    (paths.out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    all_held = [{"voice": v["id"], **item} for v in voices_report for item in v["held"]]
    paths.held.write_text(json.dumps({"checkedAt": now, "held": all_held}, indent=2) + "\n", encoding="utf-8")
    return report


def _check_one_source(voice, file, url, role, http, paths, known, now, counts) -> dict | None:
    severity_if_gone = "held" if role == "upstream" else "warning"
    probe = http.head(url)
    if probe.error is not None:
        return {"kind": "unreachable", "severity": severity_if_gone, "detail": probe.error}
    if probe.status in (404, 410):
        kind = "source-missing" if role == "upstream" else "mirror-missing"
        return {"kind": kind, "severity": severity_if_gone, "detail": f"HTTP {probe.status}"}
    if probe.status != 200:
        return {"kind": "unreachable", "severity": severity_if_gone, "detail": f"HTTP {probe.status}"}

    seen = known.get(url)
    if (seen and probe.etag is not None and seen.get("etag") == probe.etag and seen.get("size") == probe.size
            and seen.get("sha256") == file["sha256"] and probe.size == file["byteCount"]):
        counts["unchanged"] += 1
        return None

    destination = paths.out / "downloads" / voice["id"] / f"{_url_key(url)}-{Path(file['path']).name}"
    try:
        status, size, digest = http.download(url, destination)
    except (urllib.error.URLError, OSError, HTTPException) as error:
        return {"kind": "unreachable", "severity": severity_if_gone, "detail": f"download failed: {error}"}
    if status != 200:
        return {"kind": "unreachable", "severity": severity_if_gone, "detail": f"HTTP {status} on download"}
    if digest == file["sha256"] and size == file["byteCount"]:
        destination.unlink(missing_ok=True)
        known[url] = {"etag": probe.etag, "size": size, "sha256": digest, "checkedAt": now}
        return None
    known.pop(url, None)
    return {"kind": "changed", "severity": "held",
            "detail": f"now {size} bytes, sha256 {digest}; reviewed {file['byteCount']} bytes, sha256 {file['sha256']}; "
                      f"the new file is kept at {destination}"}


def _check_licence(licence, http, paths, cache) -> dict | None:
    # Pinned textURLs cannot change, so a licence that has a pinned one also names where its publisher
    # keeps the current text (watchURL); that is the one checked.
    url = licence.get("watchURL") or licence["textURL"]
    if url not in cache:
        try:
            status, body = http.text(url)
            cache[url] = (status, body, None)
        except (urllib.error.URLError, OSError, HTTPException, ToolError) as error:
            cache[url] = (None, None, str(error))
    status, body, error = cache[url]
    if error is not None:
        return {"kind": "licence-unreachable", "severity": "held", "detail": error}
    if status != 200:
        return {"kind": "licence-unreachable", "severity": "held", "detail": f"HTTP {status}"}
    digest = sha256_hex(body)
    if digest == licence["textSHA256"]:
        return None
    folder = paths.out / "licences"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{licence['id']}.new.txt").write_bytes(body)
    reviewed = (paths.root / licence["reviewedText"]).read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    current = body.decode("utf-8", errors="replace").splitlines(keepends=True)
    diff = "".join(difflib.unified_diff(reviewed, current, "reviewed", "now at " + url))
    (folder / f"{licence['id']}.diff").write_text(diff, encoding="utf-8")
    return {"kind": "licence-changed", "severity": "held", "newSHA256": digest,
            "detail": f"text now sha256 {digest}; reviewed {licence['textSHA256']}; diff at {folder / (licence['id'] + '.diff')}"}


def summary_lines(report: dict) -> list[str]:
    lines = []
    for voice in report["voices"]:
        counts = voice["counts"]
        if voice["held"]:
            lines.append(f"{voice['id']}: HELD - " + "; ".join(f"{item['subject']}: {item['kind']}" for item in voice["held"]))
        else:
            note = f"{counts['files']} files ({counts['unchanged']} sources unchanged by ETag), {counts['licences']} licences"
            if voice["warnings"]:
                note += f"; {len(voice['warnings'])} warnings, e.g. {voice['warnings'][0]['kind']}"
            lines.append(f"{voice['id']}: ok - {note}")
    return lines


def licence_issue(voice_id: str, item: dict, licence: dict, paths: Paths) -> tuple[str, str]:
    """Title and body for the one issue a changed licence text opens."""
    new_hash = item["newSHA256"]
    diff_path = paths.out / "licences" / f"{licence['id']}.diff"
    diff = diff_path.read_text(encoding="utf-8").splitlines() if diff_path.is_file() else []
    shown = "\n".join(diff[:ISSUE_DIFF_LINES]) + (f"\n... {len(diff) - ISSUE_DIFF_LINES} more lines in {diff_path}" if len(diff) > ISSUE_DIFF_LINES else "")
    fence = "`" * max(3, max((len(run) for run in re.findall(r"`+", shown)), default=0) + 1)
    title = f"Voice licence changed: {licence['id']} ({new_hash[:8]})"
    body = f"""**Outcome.** The licence text for "{licence['name']}" (used by `{voice_id}`) now differs from the text we reviewed. Someone reads the change and either updates the reviewed copy or withdraws the voice. Until then `scripts/voice-catalog publish` refuses to run.

**Evidence.** `scripts/voice-catalog check` fetched {licence['textURL']}. It hashes to `{new_hash}`; the reviewed copy (`{licence['reviewedText']}`) hashes to `{licence['textSHA256']}`.

{fence}diff
{shown}
{fence}

**Done when.**
1. A thread reads the diff. If the new terms add use restrictions, or forbid how we distribute the files, the owner decides; otherwise the thread decides.
2. If the change is acceptable: replace the reviewed text, update `textSHA256` (and `restrictionsSummary` if the restrictions changed) in `Contracts/voice-models/sources.json`, and rebuild the catalog.
3. If it is not: set the voice's `status` to `withdrawn` in `sources.json` and rebuild. An installed copy keeps working.
4. `scripts/voice-catalog check` is clean.

**Must not break:** voices already installed on listeners' phones.
"""
    return title, body


def file_licence_issues(report: dict, sources: dict, paths: Paths, run: Callable = subprocess.run) -> list[str]:
    """Open one issue per changed licence text through `gh`, unless an issue with that title already exists."""
    licences = {(v["id"], lic["id"]): lic for v in sources["voices"] for lic in v["licenses"]}
    messages = []
    seen_titles: set[str] = set()
    for voice in report["voices"]:
        for item in voice["held"]:
            if item["kind"] != "licence-changed":
                continue
            licence = licences[(voice["id"], item["subject"].removeprefix("licence "))]
            title, body = licence_issue(voice["id"], item, licence, paths)
            if title in seen_titles:  # one licence text shared by two voices is one issue
                continue
            seen_titles.add(title)
            existing = run(["gh", "issue", "list", "--state", "all", "--search", f'"{title}" in:title', "--json", "title"],
                           capture_output=True, text=True)
            if existing.returncode == 0 and any(row["title"] == title for row in json.loads(existing.stdout or "[]")):
                messages.append(f"issue already exists: {title}")
                continue
            body_path = paths.out / "licences" / f"{licence['id']}.issue.md"
            body_path.write_text(body, encoding="utf-8")
            created = run(["gh", "issue", "create", "--title", title, "--body-file", str(body_path), "--milestone", "Open Source"],
                          capture_output=True, text=True)
            messages.append(f"opened {created.stdout.strip()}" if created.returncode == 0 else f"could not open an issue ({created.stderr.strip()}); body is at {body_path}")
    return messages


# --- build ----------------------------------------------------------------------------------------------

def read_published(paths: Paths) -> tuple[dict | None, dict | None, bytes | None]:
    """The envelope on the site, its decoded payload and the exact payload bytes; None when nothing is published."""
    path = paths.site / CATALOG_PATH
    if not path.is_file():
        return None, None, None
    envelope = load_json(path)
    raw = base64.b64decode(envelope["payload"])
    return envelope, json.loads(raw), raw


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build(sources: dict, paths: Paths, issued_at: str | None = None) -> tuple[dict, str]:
    """The catalog payload. catalogVersion rises only when the voices differ from what is published, so
    a rebuild of an unchanged list is the same bytes and the app sees a refresh, not a new catalog."""
    _, published, _ = read_published(paths)
    candidate = build_catalog(sources, 1, issued_at or utc_now())
    if published is not None and published["voices"] == candidate["voices"]:
        candidate["catalogVersion"] = published["catalogVersion"]
        candidate["issuedAt"] = published["issuedAt"]
        note = f"unchanged (catalogVersion {published['catalogVersion']})"
    else:
        candidate["catalogVersion"] = (published["catalogVersion"] + 1) if published else 1
        note = f"catalogVersion {candidate['catalogVersion']}"
    return candidate, note


# --- sign -----------------------------------------------------------------------------------------------

def _ed25519():
    try:
        from cryptography.hazmat.primitives.asymmetric import ed25519
        from cryptography.hazmat.primitives import serialization
    except ImportError as error:
        raise ToolError("Signing needs the `cryptography` package: .venv/bin/pip install cryptography") from error
    return ed25519, serialization


def public_key_of(seed: bytes) -> bytes:
    ed25519, serialization = _ed25519()
    key = ed25519.Ed25519PrivateKey.from_private_bytes(seed)
    return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def sign_catalog(payload: bytes, seed: bytes, key_id: str) -> dict:
    ed25519, _ = _ed25519()
    signature = ed25519.Ed25519PrivateKey.from_private_bytes(seed).sign(SIGNING_CONTEXT + payload)
    return {"schemaVersion": "voice-model-catalog-envelope.v1", "keyId": key_id, "algorithm": "ed25519",
            "payload": base64.b64encode(payload).decode("ascii"), "signature": base64.b64encode(signature).decode("ascii")}


def verify_envelope(envelope: dict, public_key: bytes) -> bytes:
    """Returns the payload bytes, or raises ToolError if the signature does not verify."""
    ed25519, _ = _ed25519()
    from cryptography.exceptions import InvalidSignature
    payload = base64.b64decode(envelope["payload"])
    try:
        ed25519.Ed25519PublicKey.from_public_bytes(public_key).verify(base64.b64decode(envelope["signature"]), SIGNING_CONTEXT + payload)
    except InvalidSignature as error:
        raise ToolError("the signature does not verify against the signing key's public half") from error
    return payload


class KeychainKeyStore:
    """The signing seed in the login Keychain, through `security`. The seed is passed to `security -i` on stdin,
    never as an argument, so it does not show in the process list. Only macOS has it."""

    def __init__(self, run: Callable = subprocess.run, platform: str = sys.platform):
        self.run = run
        self.platform = platform

    def _require_mac(self) -> None:
        if self.platform != "darwin":
            raise ToolError("The signing key lives in the Mac's login Keychain; run this on the Mac.")

    def load(self, key_id: str) -> bytes | None:
        self._require_mac()
        result = self.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", key_id, "-w"],
                          capture_output=True, text=True)
        if result.returncode == 44:  # errSecItemNotFound
            return None
        if result.returncode != 0:
            raise ToolError(f"The Keychain would not give up the signing key (security exited {result.returncode}).")
        return base64.b64decode(result.stdout.strip())

    def create(self, key_id: str) -> bytes:
        self._require_mac()
        ed25519, serialization = _ed25519()
        seed = ed25519.Ed25519PrivateKey.generate().private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        command = f'add-generic-password -s {KEYCHAIN_SERVICE} -a {key_id} -l "Spoken Margins voice catalog signing key" -w {base64.b64encode(seed).decode("ascii")}\n'
        result = self.run(["security", "-i"], input=command, capture_output=True, text=True)
        if result.returncode != 0:
            raise ToolError(f"Could not save the signing key in the login Keychain (security exited {result.returncode}).")
        if self.load(key_id) != seed:
            raise ToolError("The signing key read back from the Keychain differs from the one saved.")
        return seed


def sign(paths: Paths, store, key_id: str) -> list[str]:
    if not paths.payload.is_file():
        raise ToolError("No payload yet: run `scripts/voice-catalog build` first.")
    payload = paths.payload.read_bytes()
    catalog = json.loads(payload)
    envelope, published, published_bytes = read_published(paths)
    if published is not None:
        if catalog["catalogVersion"] < published["catalogVersion"]:
            raise ToolError(f"catalogVersion {catalog['catalogVersion']} is lower than the published {published['catalogVersion']}; "
                            "the app rejects a rollback.")
        if payload == published_bytes and envelope["keyId"] == key_id:
            return ["nothing to sign: the payload is what is already published"]
        if catalog["catalogVersion"] == published["catalogVersion"] and payload != published_bytes:
            raise ToolError("The payload differs from the published one but has the same catalogVersion; run `build` again.")
    seed = store.load(key_id)
    if seed is None:
        raise ToolError(f"No signing key {key_id!r} in the Keychain: run `scripts/voice-catalog keygen` once.")
    envelope = sign_catalog(payload, seed, key_id)
    if verify_envelope(envelope, public_key_of(seed)) != payload:
        raise ToolError("Self-check failed: the signed payload is not the payload.")
    catalog_file = pretty(envelope)
    manifest = {
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "catalogId": "voices",
        "contentVersion": catalog["catalogVersion"],
        "generatedAt": catalog["issuedAt"],
        "keyId": key_id,
        "catalogURL": SITE_BASE + CATALOG_PATH,
        "catalogByteCount": len(catalog_file),
        "catalogChecksumSHA256": sha256_hex(catalog_file),
        "entryCount": len(catalog["voices"]),
    }
    (paths.site / "v1").mkdir(parents=True, exist_ok=True)
    (paths.site / CATALOG_PATH).write_bytes(catalog_file)
    (paths.site / MANIFEST_PATH).write_bytes(pretty(manifest))
    return [f"signed catalogVersion {catalog['catalogVersion']} with {key_id}: {len(catalog['voices'])} voices, {len(catalog_file)} bytes"]


def keygen(store, key_id: str) -> list[str]:
    seed = store.load(key_id)
    created = seed is None
    if created:
        seed = store.create(key_id)
    public = base64.b64encode(public_key_of(seed)).decode("ascii")
    return [
        f"{'Made' if created else 'Found'} signing key {key_id!r} in the login Keychain. The private half never left it.",
        f"public key (base64): {public}",
        "Put it in VoiceCatalogTrust.production (Packages/SessionKit/Sources/SessionKit/VoiceModelCatalogVerifier.swift):",
        f'    VoiceCatalogTrustedKey(keyId: "{key_id}", publicKey: Data(base64Encoded: "{public}")!)',
    ]


# --- page -----------------------------------------------------------------------------------------------

def format_size(byte_count: int) -> str:
    megabytes = round(byte_count / MEBIBYTE)
    return f"{megabytes} MB" if megabytes else "under 1 MB"


def _link(url: str, text: str) -> str:
    return f'<a href="{html.escape(url, quote=True)}">{html.escape(text)}</a>' if url.startswith("https://") else html.escape(text)


def _host(url: str) -> str:
    return url.split("/")[2] if url.count("/") >= 2 else url


def render_page(catalog: dict, app_runtimes: list[str]) -> str:
    voices = sorted(catalog["voices"], key=lambda v: v["status"] != "available")  # stable: retired voices last
    sections = []
    for voice in voices:
        total = sum(file["byteCount"] for file in voice["files"])
        details = [voice["publisher"], f"version {voice['version']}"]
        details.append("included in the app, no download" if voice["bundled"] else format_size(total))
        notes = []
        if voice["status"] == "withdrawn":
            notes.append("<p><strong>Withdrawn.</strong> The app no longer offers this voice. A copy already on a phone keeps working.</p>")
        elif voice["status"] == "superseded":
            notes.append(f"<p><strong>Replaced</strong> by <code>{html.escape(voice['supersededBy'])}</code>. A copy already on a phone keeps working.</p>")
        elif voice["runtime"]["name"] not in app_runtimes:
            notes.append("<p><strong>Not in the app yet.</strong> The app skips this voice until it can run it.</p>")
        if voice["files"]:
            hosts = []
            for file in voice["files"]:
                for source in file["sources"]:
                    if _host(source) not in hosts:
                        hosts.append(_host(source))
            notes.append(f"<p><strong>Downloads from</strong> {html.escape(', '.join(hosts))}. The app checks every file's size and "
                         f"SHA-256 fingerprint against this catalog before it uses it.</p>")
        items = []
        for licence in voice["licenses"]:
            item = _link(licence["textURL"], licence["name"])
            if licence["requiresAcceptance"]:
                item += (" — you agree to its use restrictions before downloading the voice."
                         f"<details><summary>What you agree to</summary><p>{html.escape(licence['restrictionsSummary'])}</p></details>")
            items.append(f"<li>{item}</li>")
        notes.append("<p><strong>Licences</strong></p><ul>" + "".join(items) + "</ul>")
        sections.append(f'<section class="card"><h2>{html.escape(voice["displayName"])}</h2>'
                        f'<p class="meta">{html.escape(" · ".join(details))}</p>{"".join(notes)}</section>')
    issued = catalog["issuedAt"][:10]
    bundled = [v["displayName"] for v in voices if v["bundled"] and v["status"] == "available"]
    built_in = f"{html.escape(', '.join(bundled))} is built into the app. " if len(bundled) == 1 else (
        f"{html.escape(', '.join(bundled))} are built into the app. " if bundled else "")
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Voices — Spoken Margins</title><link rel="stylesheet" href="../assets/site.css"></head>\n'
        '<body><main><header><div class="mark"><a href="../">Spoken Margins</a></div><h1>Voices</h1>'
        f'<p class="meta">Catalog version {catalog["catalogVersion"]} · issued {html.escape(issued)}</p></header>\n'
        f'<p class="lede">The speech voices Spoken Margins can read with. {built_in}'
        'The others are optional: a voice downloads only when you ask for it in the app, and you can remove it there.</p>\n'
        + "\n".join(sections) +
        '\n<p class="meta">The app reads the signed catalog at <a href="v1/catalog.json">v1/catalog.json</a>. This page is made from the same data.</p>\n'
        '<footer><a href="../privacy/">Privacy Policy</a> · <a href="../terms/">Terms</a> · <a href="../support/">Support</a> · <a href="../">Home</a></footer>'
        '</main></body></html>\n'
    )


def write_page(paths: Paths, sources: dict, catalog: dict | None = None) -> str:
    if catalog is None:
        if not paths.payload.is_file():
            raise ToolError("No payload yet: run `scripts/voice-catalog build` first.")
        catalog = load_json(paths.payload)
    paths.site.mkdir(parents=True, exist_ok=True)
    (paths.site / "index.html").write_text(render_page(catalog, sources["appRuntimes"]), encoding="utf-8")
    return f"wrote {paths.site / 'index.html'} for catalogVersion {catalog['catalogVersion']}"


# --- publish --------------------------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


CHECK_MAX_AGE = dt.timedelta(hours=24)


def _parse_time(text: str) -> dt.datetime:
    return dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def plan_publish(sources: dict, paths: Paths, mirror_from: dict[str, Path] | None = None, now: str | None = None,
                 http: HTTP | None = None) -> tuple[list[str], list[tuple[Path, str]]]:
    """Everything that must be true before anything goes public. Returns (problems, mirror uploads)."""
    problems: list[str] = []
    uploads: list[tuple[Path, str]] = []
    if paths.held.is_file():
        result = load_json(paths.held)
        for item in result["held"]:
            problems.append(f"held back: {item['voice']}: {item['subject']}: {item['kind']}. Look at it, update sources.json, run `check` again.")
        age = _parse_time(now or utc_now()) - _parse_time(result["checkedAt"]) if "checkedAt" in result else None
        if age is None or age > CHECK_MAX_AGE or age < -dt.timedelta(minutes=5):
            problems.append("The last `check` is more than a day old (or undated): run `scripts/voice-catalog check` again, here, just before publishing.")
    else:
        problems.append("No check result: run `scripts/voice-catalog check` first.")

    envelope, published, _ = read_published(paths)
    if envelope is None:
        problems.append("Nothing signed yet: run `build`, `sign` and `page` first.")
        return problems, uploads
    expected_voices = [voice_entry(sources, voice) for voice in sources["voices"]]
    if published["voices"] != expected_voices:
        problems.append("Site/voices/v1/catalog.json does not match sources.json: run `build`, `sign` and `page` again.")
    page_path = paths.site / "index.html"
    if not page_path.is_file() or page_path.read_text(encoding="utf-8") != render_page(published, sources["appRuntimes"]):
        problems.append("Site/voices/index.html is missing or does not match the signed catalog: run `page`.")
    manifest_path = paths.site / MANIFEST_PATH
    catalog_file = (paths.site / CATALOG_PATH).read_bytes()
    if not manifest_path.is_file() or load_json(manifest_path).get("catalogChecksumSHA256") != sha256_hex(catalog_file):
        problems.append("Site/voices/v1/manifest.json does not describe catalog.json: run `sign`.")

    if http is not None:
        # The local copy may be older than what is live; never move the live catalogVersion backwards.
        try:
            status, body = http.text(SITE_BASE + MANIFEST_PATH)
        except (urllib.error.URLError, OSError, HTTPException, ToolError) as error:
            problems.append(f"Could not read the live manifest to compare versions ({error}).")
        else:
            if status == 200 and json.loads(body)["contentVersion"] > published["catalogVersion"]:
                problems.append(f"The live catalog is version {json.loads(body)['contentVersion']}, newer than this checkout's {published['catalogVersion']}: "
                                "pull the latest Site/voices/ first.")

    for voice in sources["voices"]:
        mirrored = [file for file in voice["files"] if file.get("mirrored")]
        if not mirrored:
            continue
        directory = (mirror_from or {}).get(voice["id"]) or paths.root / voice["mirror"]["localDirectory"]
        for file in mirrored:
            local = directory / file["path"]
            remote = voice["mirror"]["directory"] + file["path"]
            if not local.is_file():
                problems.append(f"mirror file missing: {local} (use --mirror-from {voice['id']}=DIR)")
            elif local.stat().st_size < 200 and local.read_bytes().startswith(b"version https://git-lfs"):
                problems.append(f"{local} is a Git LFS pointer, not the file: run `git lfs pull`")
            elif local.stat().st_size != file["byteCount"] or sha256_file(local) != file["sha256"]:
                problems.append(f"mirror file {local} does not match the reviewed size and SHA-256")
            else:
                uploads.append((local, remote))
    return problems, uploads


def stage_mirror(paths: Paths, uploads: list[tuple[Path, str]]) -> Path:
    """The files laid out as they go under voices/files/. Hard links (a copy across volumes), so rsync needs no
    link-following option, and directories at 0755 whatever the umask, because `rsync -a` copies their mode."""
    stage = paths.out / "mirror-stage"
    if stage.exists():
        shutil.rmtree(stage)
    for local, remote in uploads:
        target = stage / remote
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(local, target)
        except OSError:
            shutil.copy2(local, target)
        target.chmod(0o644)
    for directory in [stage, *[p for p in stage.rglob("*") if p.is_dir()]]:
        directory.chmod(0o755)
    return stage


# --- command line ---------------------------------------------------------------------------------------

def main(argv: list[str] | None = None, paths: Paths = Paths(), http: HTTP | None = None, store=None) -> int:
    parser = argparse.ArgumentParser(prog="voice-catalog", description="Publish the voice catalog and keep it honest (#1818).")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="ask every source and licence text what it serves now").add_argument(
        "--file-issues", action="store_true", help="open one GitHub issue per changed licence text (needs gh)")
    commands.add_parser("build", help="write artifacts/voice-catalog/payload.json").add_argument("--issued-at", help="RFC 3339 time; default now")
    commands.add_parser("sign", help="sign the payload and write Site/voices/v1/").add_argument("--key-id", default=DEFAULT_KEY_ID)
    commands.add_parser("page", help="write Site/voices/index.html")
    publish = commands.add_parser("publish", help="dry run; --apply uploads the mirror files and deploys the site")
    publish.add_argument("--apply", action="store_true")
    publish.add_argument("--mirror-from", action="append", default=[], metavar="VOICE=DIR", help="where a mirrored voice's files are on this machine")
    commands.add_parser("keygen", help="once, on the Mac: make the signing key").add_argument("--key-id", default=DEFAULT_KEY_ID)
    args = parser.parse_args(argv)

    try:
        sources = load_json(paths.sources)
        problems = validate_sources(sources, paths)
        if problems:
            print("\n".join(problems), file=sys.stderr)
            return 2

        if args.command == "check":
            report = check_sources(sources, http or HTTP(), paths, utc_now())
            print("\n".join(summary_lines(report)))
            if args.file_issues:
                print("\n".join(file_licence_issues(report, sources, paths)))
            print(f"details: {paths.out / 'report.json'}")
            return 1 if any(voice["held"] for voice in report["voices"]) else 0

        if args.command == "build":
            catalog, note = build(sources, paths, args.issued_at)
            paths.out.mkdir(parents=True, exist_ok=True)
            paths.payload.write_bytes(payload_bytes(catalog))
            for voice in catalog["voices"]:
                print(f"{voice['id']}: {voice['status']}, {len(voice['files'])} files, {len(voice['licenses'])} licences")
            print(f"payload: {paths.payload} ({note})")
            return 0

        if args.command == "sign":
            print("\n".join(sign(paths, store or KeychainKeyStore(), args.key_id)))
            return 0

        if args.command == "keygen":
            print("\n".join(keygen(store or KeychainKeyStore(), args.key_id)))
            return 0

        if args.command == "page":
            print(write_page(paths, sources))
            return 0

        if args.command == "publish":
            mirror_from = {}
            for spec in args.mirror_from:
                voice_id, _, directory = spec.partition("=")
                mirror_from[voice_id] = Path(directory).expanduser()
            blockers, uploads = plan_publish(sources, paths, mirror_from, http=http or HTTP())
            if blockers:
                print("\n".join(blockers), file=sys.stderr)
                return 1
            total = sum(local.stat().st_size for local, _ in uploads)
            print(f"{len(uploads)} mirror files ({format_size(total)}) -> voices/files/; then the site deploy ({paths.deploy_script.name}).")
            if not args.apply:
                print("Dry run: nothing uploaded. Add --apply to publish.")
                return 0
            stage = stage_mirror(paths, uploads)
            environment = {**os.environ, "SPOKEN_MARGINS_MIRROR_STAGE": str(stage)}
            return subprocess.run([str(paths.deploy_script)], env=environment).returncode
    except ToolError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
