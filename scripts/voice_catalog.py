#!/usr/bin/env python3
"""The tooling behind the site's voice catalog (#1818). Run it as `scripts/voice-catalog <command>`.

  check     request every source and licence text in Contracts/voice-models/sources.json; report one line per
            voice and write the detail to artifacts/voice-catalog/. A file whose bytes or a licence text that
            changed puts its voice on hold. Exits 1 if any voice is on hold (0 with --file-issues, once each has an issue).
  build     turn sources.json into the unsigned catalog (artifacts/voice-catalog/catalog.payload.json). A voice
            on hold keeps its last published entry, or is left out if it was never published.
  keygen    make the signing key in the Mac's login Keychain, once, and print its public half.
  sign      sign the built catalog with that key; write Site/voices/v1/catalog.json and manifest.json.
  page      render Site/voices/index.html from the signed catalog.
  publish   dry run by default; with --apply, upload the mirror files and the site through the deploy script.

sources.json is the reviewed truth. Nothing in it changes until a person has looked at what changed upstream.
The private signing key lives only in the Keychain: it is never written to the repository, to artifacts/ or to
a log. `check` needs only the standard library, so it also runs on the VPS (ops/voice-catalog/).
"""

from __future__ import annotations

import argparse
import base64
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
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import voice_catalog_tools as tools  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCES_PATH = ROOT / "Contracts/voice-models/sources.json"
STATE_DIR = ROOT / "artifacts/voice-catalog"
SITE_DIR = ROOT / "Site"
CATALOG_REL = "voices/v1/catalog.json"
MANIFEST_REL = "voices/v1/manifest.json"
PAGE_REL = "voices/index.html"
TRUST_SWIFT = ROOT / "Packages/SessionKit/Sources/SessionKit/VoiceModelCatalogVerifier.swift"
DEPLOY_SCRIPT = ROOT / "scripts/deploy-spoken-margins-site.sh"
SCHEMA_PATH = ROOT / "Contracts/schemas/voice-model-catalog.schema.json"

KEYCHAIN_SERVICE = "SpokenMargins voice catalog signing key"
KEY_ID = "sm-voices-1"
USER_AGENT = "SpokenMargins-VoiceCatalogCheck/1"
SOURCES_VERSION = "voice-catalog-sources.v1"
MAX_CHECK_AGE_HOURS = 24
LICENCE_TEXT_LIMIT = 2 * 1024 * 1024
ISSUE_REPO = "uncomposed/spoken-margins-native"

SHA256_RE = re.compile(r"[0-9a-f]{64}")
HTTPS_RE = re.compile(r"https://[^\s]+")
STATUSES = ("available", "withdrawn", "superseded")


class CatalogToolError(Exception):
    """Something the person running the tool has to fix; main() prints it and exits 2."""


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text: str) -> dt.datetime:
    return dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(tools.pretty(value))


# --- sources.json --------------------------------------------------------------------------------

def load_sources(path: Path = SOURCES_PATH) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CatalogToolError(f"cannot read {path}: {error}") from error


def validate_sources(sources: dict, base_dir: Path = SOURCES_PATH.parent, allow_http: bool = False) -> list[str]:
    """Every rule the tool relies on, so a mistake in the hand-kept list fails here and not in `publish`."""
    errors: list[str] = []
    url_ok = (lambda u: isinstance(u, str) and bool(re.fullmatch(r"https?://[^\s]+" if allow_http else HTTPS_RE.pattern, u)))
    if sources.get("schemaVersion") != SOURCES_VERSION:
        errors.append(f"schemaVersion is not {SOURCES_VERSION}")
    site = sources.get("site") or {}
    if not (url_ok(site.get("baseURL")) and str(site.get("baseURL", "")).endswith("/")):
        errors.append("site.baseURL must be an https URL ending in '/'")
    mirror_path = site.get("mirrorPath", "")
    if not (isinstance(mirror_path, str) and mirror_path.endswith("/") and not mirror_path.startswith("/")):
        errors.append("site.mirrorPath must be relative and end in '/'")
    seen_voices: set[str] = set()
    for voice in sources.get("voices", []):
        vid = voice.get("id", "<no id>")
        where = f"voice {vid}"
        if vid in seen_voices:
            errors.append(f"{where}: duplicate id")
        seen_voices.add(vid)
        for key in ("id", "displayName", "publisher", "version", "runtime", "minimumIOSVersion", "minimumMemoryMegabytes", "status", "bundled", "files", "licenses"):
            if key not in voice:
                errors.append(f"{where}: missing {key}")
        if voice.get("status") not in STATUSES:
            errors.append(f"{where}: status {voice.get('status')!r} is not one of {STATUSES}")
        if voice.get("status") == "superseded" and not voice.get("supersededBy"):
            errors.append(f"{where}: superseded without supersededBy")
        files = voice.get("files", [])
        if voice.get("bundled") and files:
            errors.append(f"{where}: a bundled voice lists no files")
        if not voice.get("bundled") and not files:
            errors.append(f"{where}: a downloadable voice lists at least one file")
        license_ids = [lic.get("id") for lic in voice.get("licenses", [])]
        if not license_ids:
            errors.append(f"{where}: at least one licence")
        if len(set(license_ids)) != len(license_ids):
            errors.append(f"{where}: duplicate licence id")
        paths: set[str] = set()
        for file in files:
            path = file.get("path", "<no path>")
            label = f"{where} file {path}"
            if path in paths:
                errors.append(f"{label}: duplicate path")
            paths.add(path)
            if not (isinstance(file.get("byteCount"), int) and file["byteCount"] > 0):
                errors.append(f"{label}: byteCount must be a positive integer")
            if not SHA256_RE.fullmatch(str(file.get("sha256", ""))):
                errors.append(f"{label}: sha256 must be 64 lowercase hex characters")
            if "upstream" not in file and not file.get("mirrored"):
                errors.append(f"{label}: no upstream and not mirrored, so nothing to download from")
            if "upstream" in file and not url_ok(file["upstream"]):
                errors.append(f"{label}: upstream must be an https URL")
            if file.get("mirrored") and not (str(voice.get("mirrorDir", "")).endswith("/") and voice.get("mirrorFrom")):
                errors.append(f"{label}: mirrored needs the voice's mirrorDir (ending in '/') and mirrorFrom")
            if file.get("licenseId") and file["licenseId"] not in license_ids:
                errors.append(f"{label}: licenseId {file['licenseId']} is not one of the voice's licences")
        for licence in voice.get("licenses", []):
            label = f"{where} licence {licence.get('id')}"
            if not url_ok(licence.get("textURL")):
                errors.append(f"{label}: textURL must be an https URL")
            if "watchURL" in licence and not url_ok(licence["watchURL"]):
                errors.append(f"{label}: watchURL must be an https URL")
            if not SHA256_RE.fullmatch(str(licence.get("textSHA256", ""))):
                errors.append(f"{label}: textSHA256 must be 64 lowercase hex characters")
            if not isinstance(licence.get("requiresAcceptance"), bool):
                errors.append(f"{label}: requiresAcceptance must be true or false")
            if licence.get("requiresAcceptance") and not str(licence.get("restrictionsSummary", "")).strip():
                errors.append(f"{label}: acceptance needs a restrictionsSummary")
            reviewed = licence.get("reviewedText")
            if not reviewed:
                errors.append(f"{label}: reviewedText (the committed copy a change is diffed against) is missing")
            elif not (base_dir / reviewed).is_file():
                errors.append(f"{label}: reviewedText {reviewed} does not exist")
            elif file_sha256(base_dir / reviewed) != licence.get("textSHA256"):
                errors.append(f"{label}: reviewedText {reviewed} does not hash to textSHA256")
    return errors


# --- the catalog -----------------------------------------------------------------------------------

def mirror_prefix(sources: dict) -> str:
    return sources["site"]["baseURL"] + sources["site"]["mirrorPath"]


def mirror_url(sources: dict, voice: dict, file: dict) -> str:
    return mirror_prefix(sources) + voice["mirrorDir"] + file["path"]


def file_source_urls(sources: dict, voice: dict, file: dict) -> list[str]:
    """In the catalog's order of preference: the publisher's pinned file first, then our mirror."""
    urls = [file["upstream"]] if "upstream" in file else []
    if file.get("mirrored"):
        urls.append(mirror_url(sources, voice, file))
    return urls


def voice_entry(sources: dict, voice: dict) -> dict:
    entry = {key: voice[key] for key in ("id", "displayName", "publisher", "version", "runtime", "minimumIOSVersion", "minimumMemoryMegabytes", "status")}
    if "supersededBy" in voice:
        entry["supersededBy"] = voice["supersededBy"]
    entry["bundled"] = voice["bundled"]
    files = []
    for file in voice["files"]:
        item = {"path": file["path"], "byteCount": file["byteCount"], "sha256": file["sha256"], "sources": file_source_urls(sources, voice, file)}
        for key in ("licenseId", "origin"):
            if key in file:
                item[key] = file[key]
        files.append(item)
    entry["files"] = files
    entry["licenses"] = [{key: lic[key] for key in ("id", "name", "spdxId", "textURL", "textSHA256", "requiresAcceptance", "restrictionsSummary") if key in lic} for lic in voice["licenses"]]
    return entry


def schema_errors(payload: dict) -> list[str] | None:
    """None when jsonschema isn't installed (the Swift verifier is still the app's last word)."""
    try:
        from jsonschema import Draft202012Validator, FormatChecker
    except ImportError:
        return None
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    return [f"{'.'.join(str(p) for p in e.path) or '<root>'}: {e.message}" for e in Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(payload)]


# --- talking to the network --------------------------------------------------------------------------

class Http:
    """Plain requests that carry no cookies, identifiers or query strings of ours; tests point it at a local server."""

    def __init__(self, timeout: int = 60):
        self.timeout = timeout

    def _open(self, url: str, method: str):
        request = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT})
        return urllib.request.urlopen(request, timeout=self.timeout)

    def head(self, url: str) -> dict:
        """{'status', 'size', 'etag', 'error'}: size and etag are None when the server doesn't say."""
        for method in ("HEAD", "GET"):
            try:
                with self._open(url, method) as response:
                    length = response.headers.get("Content-Length")
                    return {"status": response.status, "size": int(length) if length and length.isdigit() else None, "etag": response.headers.get("ETag"), "error": None}
            except urllib.error.HTTPError as error:
                if method == "HEAD" and error.code in (403, 405, 501):
                    continue
                return {"status": error.code, "size": None, "etag": None, "error": None}
            except (urllib.error.URLError, OSError, ValueError) as error:
                return {"status": None, "size": None, "etag": None, "error": str(error)}
        return {"status": None, "size": None, "etag": None, "error": "no answer"}

    def get(self, url: str, limit: int = LICENCE_TEXT_LIMIT) -> tuple[int | None, bytes]:
        try:
            with self._open(url, "GET") as response:
                return response.status, response.read(limit + 1)[:limit]
        except urllib.error.HTTPError as error:
            return error.code, b""
        except (urllib.error.URLError, OSError, ValueError):
            return None, b""

    def download(self, url: str, into: Path) -> tuple[int | None, int, str]:
        """Stream a file to `into`; returns (status, byte count, sha256)."""
        digest, count = hashlib.sha256(), 0
        try:
            with self._open(url, "GET") as response, into.open("wb") as out:
                for chunk in iter(lambda: response.read(1 << 20), b""):
                    digest.update(chunk)
                    out.write(chunk)
                    count += len(chunk)
                return response.status, count, digest.hexdigest()
        except urllib.error.HTTPError as error:
            return error.code, 0, ""
        except (urllib.error.URLError, OSError, ValueError):
            return None, count, ""


# --- check ---------------------------------------------------------------------------------------------

def _load_json_or(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def check(sources: dict, state_dir: Path, *, http=None, full: bool = False, mirror: str = "note",
          now: dt.datetime | None = None, out=print, base_dir: Path = SOURCES_PATH.parent) -> dict:
    """Request every source and licence text. `mirror` is 'skip', 'note' (reported, never holds a voice) or
    'require' (a missing or wrong mirror file holds the voice). Returns the report it also writes."""
    http = http or Http()
    now = now or dt.datetime.now(dt.timezone.utc)
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "tmp").mkdir(exist_ok=True)
    seen = _load_json_or(state_dir / "seen.json", {})
    prefix = mirror_prefix(sources)
    detail: list[str] = []
    report = {"checkedAt": iso(now), "sourcesSHA256": sha256_hex(json.dumps(sources, sort_keys=True).encode()), "mirror": mirror, "voices": {}}

    def note(line: str) -> None:
        detail.append(line)

    for voice in sources["voices"]:
        problems: list[dict] = []
        notes: list[str] = []

        def problem(kind: str, subject: str, url: str, text: str, is_mirror: bool = False) -> None:
            problems.append({"kind": kind, "subject": subject, "url": url, "detail": text, "mirror": is_mirror})
            note(f"PROBLEM {voice['id']} {subject} {kind}: {text} <{url}>")

        for file in voice["files"]:
            for url in file_source_urls(sources, voice, file):
                is_mirror = url.startswith(prefix)
                if is_mirror and mirror == "skip":
                    continue
                answer = http.head(url)
                status, size, etag = answer["status"], answer["size"], answer["etag"]
                note(f"{voice['id']} {file['path']} {url} status={status} size={size} etag={etag}")
                if status != 200:
                    kind = "missing" if status in (404, 410) else "unreachable"
                    text = f"HTTP {status}" if status else f"no answer ({answer['error']})"
                    if is_mirror and mirror == "note":
                        notes.append(f"mirror {kind}: {file['path']} ({text})")
                        note(f"NOTE mirror {kind}: {file['path']}")
                    else:
                        problem(kind, file["path"], url, text, is_mirror)
                    continue
                record = seen.get(url, {})
                stale = (full or record.get("sha256") != file["sha256"] or (size is not None and size != file["byteCount"])
                         or (etag is not None and record.get("etag") != etag))
                if not stale:
                    continue
                target = state_dir / "tmp" / "download"
                status, count, digest = http.download(url, target)
                if digest == file["sha256"] and count == file["byteCount"]:
                    seen[url] = {"etag": etag, "size": count, "sha256": digest, "verifiedAt": iso(now)}
                    target.unlink(missing_ok=True)
                    continue
                kept = state_dir / "changed" / voice["id"] / file["path"]
                kept.parent.mkdir(parents=True, exist_ok=True)
                if status == 200:
                    shutil.move(str(target), kept)
                else:
                    target.unlink(missing_ok=True)
                seen.pop(url, None)
                what = (f"now {count} bytes, sha256 {digest}; reviewed {file['byteCount']} bytes, sha256 {file['sha256']}; kept at {kept}"
                        if status == 200 else f"download failed (HTTP {status})")
                kind = "hash-differs" if status == 200 else "unreachable"
                if is_mirror and mirror == "note":
                    notes.append(f"mirror {kind}: {file['path']}")
                else:
                    problem(kind, file["path"], url, what, is_mirror)
        for licence in voice["licenses"]:
            url = licence.get("watchURL") or licence["textURL"]
            status, body = http.get(url)
            note(f"{voice['id']} licence {licence['id']} {url} status={status} bytes={len(body)}")
            if status != 200:
                problem("licence-unreachable", f"licence {licence['id']}", url, f"HTTP {status}")
                continue
            if sha256_hex(body) == licence["textSHA256"]:
                continue
            reviewed = (base_dir / licence["reviewedText"]).read_text(encoding="utf-8", errors="replace")
            diff = "\n".join(difflib.unified_diff(reviewed.splitlines(), body.decode("utf-8", errors="replace").splitlines(),
                                                  f"reviewed/{licence['id']}", f"live/{licence['id']}", lineterm=""))
            licence_dir = state_dir / "licences"
            licence_dir.mkdir(exist_ok=True)
            (licence_dir / f"{voice['id']}-{licence['id']}.diff").write_text(diff + "\n", encoding="utf-8")
            (licence_dir / f"{voice['id']}-{licence['id']}.new.txt").write_bytes(body)
            problem("licence-changed", f"licence {licence['id']}", url, f"now hashes to {sha256_hex(body)}; reviewed {licence['textSHA256']}; diff in licences/{voice['id']}-{licence['id']}.diff")
        held = any(not p["mirror"] or mirror == "require" for p in problems)
        report["voices"][voice["id"]] = {"held": held, "problems": problems, "notes": notes}
        if held:
            out(f"{voice['id']}: HELD - " + "; ".join(f"{p['kind']} {p['subject']}" for p in problems[:4]) + (" ..." if len(problems) > 4 else ""))
        else:
            tail = f", {len(notes)} mirror note(s)" if notes else ""
            out(f"{voice['id']}: ok ({len(voice['files'])} files, {len(voice['licenses'])} licences{tail})")
    write_json(state_dir / "check.json", report)
    write_json(state_dir / "seen.json", seen)
    (state_dir / "check.txt").write_text("\n".join(detail) + "\n", encoding="utf-8")
    return report


def issue_for(voice_id: str, report_voice: dict, state_dir: Path) -> list[tuple[str, str]]:
    """(title, body) for the one issue each kind of change deserves."""
    issues = []
    licence_problems = [p for p in report_voice["problems"] if p["kind"] == "licence-changed"]
    others = [p for p in report_voice["problems"] if p["kind"] != "licence-changed"]
    for p in licence_problems:
        licence_id = p["subject"].removeprefix("licence ")
        diff_path = state_dir / "licences" / f"{voice_id}-{licence_id}.diff"
        diff = diff_path.read_text(encoding="utf-8") if diff_path.is_file() else "(diff not kept)"
        if len(diff) > 20000:
            diff = diff[:20000] + "\n... (cut; the full diff is in the check's artifacts folder)"
        issues.append((f"Voice licence changed: {voice_id} / {licence_id}", "\n".join([
            "**Outcome.** The voice catalog is not republished with a licence nobody has read. The new terms are read, and `Contracts/voice-models/sources.json` and the reviewed copy under `Contracts/voice-models/licenses/` are updated, or the voice is withdrawn.",
            "",
            f"**Evidence.** The weekly `scripts/voice-catalog check` fetched `{p['url']}` and its SHA-256 differs from the reviewed one. The voice `{voice_id}` is held back: the catalog keeps its last published entry until this is resolved.",
            "",
            "```diff", diff, "```", "",
            "**Done when.**",
            "1. A thread reads the diff and writes down what changed in plain words on this issue.",
            "2. If the new terms add use restrictions or forbid how we distribute the files, the question goes to the owner as a one-line question. Otherwise the thread updates `sources.json` (`textSHA256`, `restrictionsSummary` and `requiresAcceptance` if they changed) and the reviewed copy in `Contracts/voice-models/licenses/`.",
            "3. `scripts/voice-catalog check` no longer holds the voice.",
            "",
            "**Must not break:** the catalog already published (it stays as it is), the onboarding catalog and its URLs.",
        ])))
    if others:
        listing = "\n".join(f"- `{p['kind']}` {p['subject']}: {p['detail']} (<{p['url']}>)" for p in others)
        issues.append((f"Voice source problem: {voice_id}", "\n".join([
            "**Outcome.** The voice's files are all reachable and match the reviewed size and SHA-256 again, or the voice is withdrawn from the catalog.",
            "",
            f"**Evidence.** The weekly `scripts/voice-catalog check` found, for `{voice_id}`:", "", listing, "",
            "The voice is held back: the catalog keeps its last published entry until this is resolved.", "",
            "**Done when.**",
            "1. A thread finds out whether the file moved, was removed, or changed in place.",
            "2. `sources.json` points at the new location or hash after the new bytes have been looked at, or the voice is marked `withdrawn`.",
            "3. `scripts/voice-catalog check` no longer holds the voice.", "",
            "**Must not break:** the catalog already published, the onboarding catalog and its URLs.",
        ])))
    return issues


def file_issues(report: dict, state_dir: Path, token: str, *, repo: str = ISSUE_REPO, api: str = "https://api.github.com", out=print) -> list[str]:
    """Open one issue per held voice and kind of change, unless an open issue with that title exists."""
    def call(method: str, path: str, body: dict | None = None):
        request = urllib.request.Request(api + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": USER_AGENT, "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read() or b"null")

    wanted = [item for voice_id, v in report["voices"].items() if v["held"] for item in issue_for(voice_id, v, state_dir)]
    if not wanted:
        return []
    open_titles = {issue["title"] for issue in call("GET", f"/repos/{repo}/issues?state=open&per_page=100")}
    filed = []
    for title, body in wanted:
        if title in open_titles:
            out(f"issue already open: {title}")
            continue
        call("POST", f"/repos/{repo}/issues", {"title": title, "body": body + "\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_", "labels": ["ready"]})
        filed.append(title)
        out(f"issue filed: {title}")
    return filed


# --- build -----------------------------------------------------------------------------------------------

def published_payload(site_dir: Path) -> dict | None:
    path = site_dir / CATALOG_REL
    if not path.is_file():
        return None
    return json.loads(base64.b64decode(json.loads(path.read_text(encoding="utf-8"))["payload"]))


def build(sources: dict, state_dir: Path, site_dir: Path, *, now: dt.datetime | None = None, out=print) -> dict:
    now = now or dt.datetime.now(dt.timezone.utc)
    report = _load_json_or(state_dir / "check.json", None)
    if report is None:
        out("note: no check report yet; nothing is held. Run `check` first for a real publish.")
    held_ids = {vid for vid, v in (report or {}).get("voices", {}).items() if v["held"]}
    previous = published_payload(site_dir)
    previous_voices = {v["id"]: v for v in (previous or {}).get("voices", [])}
    voices = []
    for voice in sources["voices"]:
        if voice["id"] in held_ids:
            if voice["id"] in previous_voices:
                voices.append(previous_voices[voice["id"]])
                out(f"{voice['id']}: HELD, keeping the entry published in catalog {previous['catalogVersion']}")
            else:
                out(f"{voice['id']}: HELD and never published, left out")
            continue
        voices.append(voice_entry(sources, voice))
        out(f"{voice['id']}: included")
    if not voices:
        raise CatalogToolError("every voice is held or there are none; refusing to build an empty catalog")
    if previous and previous["voices"] == voices:
        version, issued = previous["catalogVersion"], previous["issuedAt"]
    else:
        version, issued = (previous["catalogVersion"] + 1 if previous else 1), iso(now)
    payload = {"schemaVersion": "voice-model-catalog.v1", "catalogVersion": version, "issuedAt": issued, "voices": voices}
    problems = schema_errors(payload)
    if problems:
        raise CatalogToolError("the built catalog breaks its schema:\n" + "\n".join(problems))
    if problems is None:
        out("note: jsonschema is not installed, so the schema check was skipped.")
    write_json(state_dir / "catalog.payload.json", payload)
    out(f"catalog version {version}" + (" (unchanged)" if previous and version == previous["catalogVersion"] else ""))
    return payload


# --- keys and signing ----------------------------------------------------------------------------------------

def _security(arguments: list[str], run=subprocess.run):
    try:
        return run(["security", *arguments], capture_output=True, text=True)
    except FileNotFoundError as error:
        raise CatalogToolError("the macOS `security` tool is not here; keys are made and used on the Mac") from error


def keychain_key(run=subprocess.run):
    """The signing key from the login Keychain, or None. The secret is read into memory and never printed."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    result = _security(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEY_ID, "-w"], run)
    if result.returncode != 0:
        return None
    return Ed25519PrivateKey.from_private_bytes(base64.b64decode(result.stdout.strip()))


def public_b64(private_key) -> str:
    from cryptography.hazmat.primitives import serialization

    return base64.b64encode(private_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()


def swift_key_line(private_key) -> str:
    return f'VoiceCatalogTrustedKey(keyId: "{KEY_ID}", publicKey: Data(base64Encoded: "{public_b64(private_key)}")!)'


def keygen(run=subprocess.run, out=print) -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    if keychain_key(run) is not None:
        raise CatalogToolError(f"a key named {KEY_ID!r} is already in the login Keychain; refusing to replace it (delete it in Keychain Access first, if you mean to rotate)")
    key = Ed25519PrivateKey.generate()
    secret = base64.b64encode(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())).decode()
    # `security` takes the secret as an argument; macOS shows a process's arguments only to its own user.
    stored = _security(["add-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEY_ID, "-w", secret], run)
    if stored.returncode != 0:
        raise CatalogToolError("could not store the key in the login Keychain: " + stored.stderr.strip().replace(secret, "<secret>"))
    out(f"signing key {KEY_ID} is in the login Keychain (service {KEYCHAIN_SERVICE!r}). It never leaves it.")
    out("Put this line in VoiceCatalogTrust.production (Packages/SessionKit/Sources/SessionKit/VoiceModelCatalogVerifier.swift):")
    out("    " + swift_key_line(key))


def trusted_keys(swift_path: Path = TRUST_SWIFT) -> dict[str, str]:
    """keyId -> public key (base64) of the keys compiled into the app's VoiceCatalogTrust.production."""
    text = swift_path.read_text(encoding="utf-8")
    start = text.find("static let production")
    segment = text[start:] if start >= 0 else ""
    segment = segment.split("\n}\n", 1)[0] if segment else ""
    pattern = r'VoiceCatalogTrustedKey\(\s*keyId:\s*"([a-z0-9-]+)",\s*publicKey:\s*Data\(base64Encoded:\s*"([A-Za-z0-9+/=]+)"\)!?\s*\)'
    return dict(re.findall(pattern, segment))


def envelope_signature_ok(envelope: dict, public_key_b64: str) -> bool:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    try:
        Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64)).verify(
            base64.b64decode(envelope["signature"]), tools.SIGNING_CONTEXT + base64.b64decode(envelope["payload"]))
        return True
    except (InvalidSignature, ValueError, KeyError):
        return False


def sign(sources: dict, state_dir: Path, site_dir: Path, private_key, *, out=print) -> dict:
    payload_path = state_dir / "catalog.payload.json"
    if not payload_path.is_file():
        raise CatalogToolError("no built catalog; run `build` first")
    payload = payload_path.read_bytes()
    catalog = json.loads(payload)
    problems = schema_errors(catalog)
    if problems:
        raise CatalogToolError("the built catalog breaks its schema:\n" + "\n".join(problems))
    envelope = tools.sign_envelope(KEY_ID, private_key, payload)
    if not envelope_signature_ok(envelope, public_b64(private_key)):
        raise CatalogToolError("the signature does not verify against the key's own public half; not writing anything")
    catalog_bytes = tools.pretty(envelope)
    (site_dir / CATALOG_REL).parent.mkdir(parents=True, exist_ok=True)
    (site_dir / CATALOG_REL).write_bytes(catalog_bytes)
    manifest = {
        "schemaVersion": "voice-catalog-manifest.v1",
        "catalogId": "voice-models",
        "contentVersion": catalog["catalogVersion"],
        "generatedAt": catalog["issuedAt"],
        "catalogURL": sources["site"]["baseURL"] + CATALOG_REL,
        "catalogByteCount": len(catalog_bytes),
        "catalogChecksumSHA256": sha256_hex(catalog_bytes),
        "entryCount": len(catalog["voices"]),
    }
    write_json(site_dir / MANIFEST_REL, manifest)
    out(f"signed catalog version {catalog['catalogVersion']} with {KEY_ID}: {CATALOG_REL}, {MANIFEST_REL}")
    return manifest


# --- the page -----------------------------------------------------------------------------------------------------

def format_bytes(count: int) -> str:
    if count >= 10**9:
        return f"{count / 10**9:.1f} GB"
    if count >= 10**6:
        return f"{round(count / 10**6)} MB"
    return f"{max(1, round(count / 10**3))} KB"


def _esc(value) -> str:
    return html.escape(str(value), quote=True)


def render_page(catalog: dict, sources: dict) -> str:
    site_host = urllib.parse.urlsplit(sources["site"]["baseURL"]).netloc
    cards = []
    for voice in catalog["voices"]:
        hosts: list[str] = []
        for file in voice["files"]:
            for url in file["sources"]:
                host = urllib.parse.urlsplit(url).netloc
                label = f"{host} (our own mirror)" if host == site_host else host
                if label not in hosts:
                    hosts.append(label)
        if voice["bundled"]:
            where = "Ships inside the app. Nothing is downloaded."
            size = "Included in the app"
        else:
            where = "Downloads from " + ", ".join(hosts) + ". The app tries them in this order and checks every file against the size and SHA-256 listed below."
            size = format_bytes(sum(f["byteCount"] for f in voice["files"]))
        status = {"available": "", "withdrawn": " <strong>Withdrawn:</strong> the app no longer offers it.",
                  "superseded": f" <strong>Superseded</strong> by <code>{_esc(voice.get('supersededBy', ''))}</code>."}[voice["status"]]
        licences = []
        for licence in voice["licenses"]:
            spdx = f" ({_esc(licence['spdxId'])})" if "spdxId" in licence else ""
            line = f"<li><a href=\"{_esc(licence['textURL'])}\">{_esc(licence['name'])}</a>{spdx}"
            if licence["requiresAcceptance"]:
                line += f"<br><strong>You agree to this before the download starts.</strong> {_esc(licence['restrictionsSummary'])}"
            licences.append(line + "</li>")
        listing = ""
        if voice["files"]:
            rows = "".join(f"<tr><td><code>{_esc(f['path'])}</code></td><td>{_esc(format_bytes(f['byteCount']))}</td><td><code>{_esc(f['sha256'])}</code></td></tr>" for f in voice["files"])
            listing = f"<details><summary>{len(voice['files'])} files</summary><table><tr><th>File</th><th>Size</th><th>SHA-256</th></tr>{rows}</table></details>"
        cards.append(
            f"<section class=\"card\" id=\"{_esc(voice['id'])}\"><h2>{_esc(voice['displayName'])}</h2>"
            f"<p class=\"meta\">{_esc(voice['publisher'])} - version {_esc(voice['version'])} - {_esc(size)} - needs iOS {_esc(voice['minimumIOSVersion'])} and {_esc(voice['minimumMemoryMegabytes'])} MB of memory{status}</p>"
            f"<p>{_esc(where)}</p><h3>Licences</h3><ul>{''.join(licences)}</ul>{listing}</section>")
    return (
        "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        "<title>Voices - Spoken Margins</title>"
        f"<link rel=\"stylesheet\" href=\"{_esc(sources['site']['baseURL'])}assets/site.css\">"
        "<style>table{border-collapse:collapse;font:13px/1.4 ui-sans-serif,system-ui;margin-top:12px;max-width:100%}td,th{border-top:1px solid var(--line);padding:4px 8px;text-align:left;overflow-wrap:anywhere}h3{font:600 16px ui-sans-serif,system-ui;margin-top:1.4em}</style></head>\n"
        "<body><main><header><div class=\"mark\"><a href=\"/\">Spoken Margins</a></div><h1>Voices</h1>"
        f"<p class=\"meta\">Catalog version {_esc(catalog['catalogVersion'])}, issued {_esc(catalog['issuedAt'])}</p></header>\n"
        "<p class=\"lede\">These are the voices the Spoken Margins app can read with, where each one comes from, and the licence it is under. "
        "The app reads the signed list at <a href=\"/voices/v1/catalog.json\">/voices/v1/catalog.json</a> and refuses anything whose signature or file checks do not match. "
        "The request carries no account and no identifier; it is the same for every listener.</p>\n"
        + "\n".join(cards)
        + "\n<footer><a href=\"/privacy/\">Privacy Policy</a> | <a href=\"/terms/\">Terms of Use</a> | <a href=\"/support/\">Support</a> | <a href=\"/\">Home</a></footer></main></body></html>\n")


def write_page(sources: dict, site_dir: Path, out=print) -> Path:
    path = site_dir / CATALOG_REL
    if not path.is_file():
        raise CatalogToolError("no signed catalog under Site/voices/v1/; run `sign` first")
    catalog = published_payload(site_dir)
    target = site_dir / PAGE_REL
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render_page(catalog, sources), encoding="utf-8")
    out(f"wrote {PAGE_REL} for catalog version {catalog['catalogVersion']}")
    return target


# --- publish ---------------------------------------------------------------------------------------------------------

def stage_mirror(sources: dict, state_dir: Path) -> tuple[Path, int, int]:
    """Link every mirrored file, after checking its bytes, into a folder the deploy script uploads from."""
    stage = state_dir / "mirror"
    shutil.rmtree(stage, ignore_errors=True)
    problems, count, total = [], 0, 0
    for voice in sources["voices"]:
        for file in voice["files"]:
            if not file.get("mirrored"):
                continue
            source = ROOT / voice["mirrorFrom"] / file["path"]
            label = f"{voice['id']} {file['path']}"
            if not source.is_file():
                problems.append(f"{label}: {source} does not exist")
            elif source.stat().st_size != file["byteCount"]:
                problems.append(f"{label}: {source} is {source.stat().st_size} bytes, expected {file['byteCount']} (a Git LFS pointer? run `git lfs pull`)")
            elif file_sha256(source) != file["sha256"]:
                problems.append(f"{label}: {source} does not hash to the reviewed sha256")
            else:
                destination = stage / voice["mirrorDir"] / file["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(source.resolve(), destination)
                count += 1
                total += file["byteCount"]
    if problems:
        raise CatalogToolError("cannot stage the mirror files:\n" + "\n".join(problems))
    return stage, count, total


def publish(sources: dict, state_dir: Path, site_dir: Path, *, apply: bool = False, http=None, run=subprocess.run,
            now: dt.datetime | None = None, live_version="fetch", swift_path: Path = TRUST_SWIFT, out=print) -> None:
    http = http or Http()
    now = now or dt.datetime.now(dt.timezone.utc)
    report = _load_json_or(state_dir / "check.json", None)
    if report is None:
        raise CatalogToolError("no check report; run `check` first")
    age = now - parse_iso(report["checkedAt"])
    if age > dt.timedelta(hours=MAX_CHECK_AGE_HOURS):
        raise CatalogToolError(f"the last check is {age.total_seconds() / 3600:.0f} hours old (limit {MAX_CHECK_AGE_HOURS}); run `check` again")
    if report["sourcesSHA256"] != sha256_hex(json.dumps(sources, sort_keys=True).encode()):
        raise CatalogToolError("sources.json changed since the last check; run `check` again")
    for name in (CATALOG_REL, MANIFEST_REL, PAGE_REL):
        if not (site_dir / name).is_file():
            raise CatalogToolError(f"Site/{name} is missing; run build, sign and page first")
    envelope = json.loads((site_dir / CATALOG_REL).read_text(encoding="utf-8"))
    catalog = published_payload(site_dir)
    manifest = json.loads((site_dir / MANIFEST_REL).read_text(encoding="utf-8"))
    if manifest["contentVersion"] != catalog["catalogVersion"] or manifest["catalogChecksumSHA256"] != sha256_hex((site_dir / CATALOG_REL).read_bytes()):
        raise CatalogToolError("manifest.json does not describe catalog.json; run `sign` again")
    if (site_dir / PAGE_REL).read_text(encoding="utf-8") != render_page(catalog, sources):
        raise CatalogToolError("Site/voices/index.html is out of date with the catalog; run `page` again")
    in_catalog = {v["id"]: v for v in catalog["voices"]}
    for voice in sources["voices"]:
        if not report["voices"][voice["id"]]["held"] and in_catalog.get(voice["id"]) != voice_entry(sources, voice):
            raise CatalogToolError(f"the signed catalog's entry for {voice['id']} is not what sources.json says; run `build`, `sign` and `page` again")
    keys = trusted_keys(swift_path)
    if not keys:
        raise CatalogToolError("no signing key is compiled into the app yet (VoiceCatalogTrust.production is empty); publishing a catalog no build trusts does nothing")
    if envelope["keyId"] not in keys or not envelope_signature_ok(envelope, keys[envelope["keyId"]]):
        raise CatalogToolError(f"the catalog is not signed by a key the app trusts ({envelope['keyId']}); `sign` with the key whose public half is in VoiceCatalogTrust.production")
    if live_version == "fetch":
        status, body = http.get(sources["site"]["baseURL"] + MANIFEST_REL)
        if status == 404:
            live_version = None
        elif status == 200:
            live_version = json.loads(body)["contentVersion"]
        else:
            raise CatalogToolError(f"could not read the live manifest (HTTP {status}); not moving the catalog without knowing its version")
    if live_version is not None and catalog["catalogVersion"] < live_version:
        raise CatalogToolError(f"catalogVersion {catalog['catalogVersion']} is lower than the live {live_version}; the app would reject it as a rollback")
    stage, mirror_count, mirror_bytes = stage_mirror(sources, state_dir)
    out(f"catalog version {catalog['catalogVersion']} ({len(catalog['voices'])} voices); live version: {live_version if live_version is not None else 'none yet'}")
    out(f"mirror: {mirror_count} files, {format_bytes(mirror_bytes)}, staged at {stage}")
    if not apply:
        out("dry run: nothing uploaded. Add --apply to run scripts/deploy-spoken-margins-site.sh.")
        return
    environment = dict(os.environ)
    if mirror_count:
        environment["SPOKEN_MARGINS_VOICE_MIRROR_DIR"] = str(stage)
    result = run([str(DEPLOY_SCRIPT)], env=environment)
    if result.returncode != 0:
        raise CatalogToolError(f"the deploy script failed (exit {result.returncode}); the site may be half updated, run publish again")
    status, body = http.get(sources["site"]["baseURL"] + MANIFEST_REL)
    if status != 200 or json.loads(body)["contentVersion"] != catalog["catalogVersion"]:
        raise CatalogToolError("deployed, but the live manifest does not show the new version")
    wrong = []
    for voice in sources["voices"]:
        for file in voice["files"]:
            if file.get("mirrored"):
                answer = http.head(mirror_url(sources, voice, file))
                if answer["status"] != 200 or (answer["size"] is not None and answer["size"] != file["byteCount"]):
                    wrong.append(f"{voice['id']} {file['path']}: HTTP {answer['status']}, size {answer['size']}")
    if wrong:
        raise CatalogToolError("deployed, but these mirror files are not served as reviewed:\n" + "\n".join(wrong))
    out("published and verified: live manifest and every mirror file match.")


# --- command line ---------------------------------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="voice-catalog", description=__doc__.split("\n\n")[0])
    parser.add_argument("--sources", type=Path, default=SOURCES_PATH)
    parser.add_argument("--state-dir", type=Path, default=STATE_DIR)
    parser.add_argument("--site-dir", type=Path, default=SITE_DIR)
    commands = parser.add_subparsers(dest="command", required=True)
    check_parser = commands.add_parser("check")
    check_parser.add_argument("--full", action="store_true", help="download and hash every file, even those seen unchanged")
    check_parser.add_argument("--mirror", choices=["skip", "note", "require"], default="note")
    check_parser.add_argument("--file-issues", action="store_true", help="open an issue per held voice (needs --token-file)")
    check_parser.add_argument("--token-file", type=Path)
    check_parser.add_argument("--repo", default=ISSUE_REPO)
    commands.add_parser("build")
    commands.add_parser("keygen")
    commands.add_parser("sign")
    commands.add_parser("page")
    publish_parser = commands.add_parser("publish")
    publish_parser.add_argument("--apply", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "keygen":
            keygen()
            return 0
        sources = load_sources(arguments.sources)
        problems = validate_sources(sources, arguments.sources.parent)
        if problems:
            raise CatalogToolError("sources.json is not valid:\n" + "\n".join(problems))
        if arguments.command == "check":
            report = check(sources, arguments.state_dir, full=arguments.full, mirror=arguments.mirror, base_dir=arguments.sources.parent)
            held = any(v["held"] for v in report["voices"].values())
            if arguments.file_issues:
                if not arguments.token_file:
                    raise CatalogToolError("--file-issues needs --token-file")
                try:
                    file_issues(report, arguments.state_dir, arguments.token_file.read_text(encoding="utf-8").strip(), repo=arguments.repo)
                except (urllib.error.URLError, OSError) as error:
                    raise CatalogToolError(f"could not file the issues: {error}") from error
                return 0  # a held voice now has an issue; only a failure to file one fails the run
            return 1 if held else 0
        if arguments.command == "build":
            build(sources, arguments.state_dir, arguments.site_dir)
        elif arguments.command == "sign":
            key = keychain_key()
            if key is None:
                raise CatalogToolError(f"no key named {KEY_ID!r} in the login Keychain; run `keygen` once on the Mac")
            sign(sources, arguments.state_dir, arguments.site_dir, key)
        elif arguments.command == "page":
            write_page(sources, arguments.site_dir)
        elif arguments.command == "publish":
            publish(sources, arguments.state_dir, arguments.site_dir, apply=arguments.apply)
        return 0
    except CatalogToolError as error:
        print(f"voice-catalog: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
