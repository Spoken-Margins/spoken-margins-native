#!/usr/bin/env python3
import base64
import json
import hashlib
import re
import subprocess
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

sys.path.insert(0, str(Path(__file__).resolve().parent))
import voice_catalog  # noqa: E402
import voice_catalog_tools  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "Contracts"
SCHEMAS = CONTRACTS / "schemas"


PATH_SCHEMA_RULES = [
    ("fixtures/listening-editions/*.json", "listening-edition.schema.json"),
    ("fixtures/persistence/*.json", "persistence-fixture.schema.json"),
    ("fixtures/capabilities/*.json", "runtime-capability-profile.schema.json"),
    ("fixtures/items/*.json", "item.schema.json"),
    ("fixtures/maps/*.json", "listening-map.schema.json"),
    ("fixtures/sessions/*.json", "session.schema.json"),
    ("fixtures/interjections/*.json", "interjection.schema.json"),
    ("fixtures/interjection-packages/*.json", "spoken-margins-package.schema.json"),
    ("fixtures/sharing/cleanup-revision.json", "interjection-share-revision.schema.json"),
    ("fixtures/sharing/commentary-layer.json", "shared-commentary-layer.schema.json"),
    ("fixtures/sharing/listening-map-proposal*.json", "portable-listening-map-proposal.schema.json"),
    ("fixtures/sharing/margin-conversation.json", "margin-conversation.schema.json"),
    ("fixtures/turns/*.json", "conversation-turn.schema.json", "array"),
    ("fixtures/exports/*.json", "session-export.schema.json"),
    ("fixtures/watch/offline-package.json", "watch-audio-package.schema.json"),
    ("fixtures/watch/sync-*-event.json", "watch-sync-event.schema.json"),
    ("fixtures/audio/*.json", "audio-asset.schema.json"),
    ("fixtures/link-resolution/*.json", "link-resolution-fixture.schema.json"),
    ("fixtures/transcripts/*.json", "transcript.schema.json"),
    ("fixtures/canonical-sources/*.json", "canonical-source.schema.json"),
    ("fixtures/prepared-audio/*.json", "prepared-audio-manifest.schema.json"),
    ("fixtures/offline-storage/*.json", "offline-storage.schema.json"),
    ("fixtures/followed-sources/*.json", "followed-source.schema.json"),
    ("fixtures/listening-signals/*.jsonl", "i4-engagement.schema.json", "jsonl"),
    ("fixtures/presentation/*.json", "app-presentation.schema.json"),
    ("fixtures/source-catalog/*.json", "source-catalog.schema.json"),
    ("fixtures/source-catalog-manifest/*.json", "source-catalog-manifest.schema.json"),
    ("fixtures/source-resolution/*.json", "source-resolution.schema.json"),
    ("fixtures/voice-model-catalog/envelope-*.json", "voice-model-catalog-envelope.schema.json"),
    ("fixtures/voice-model-catalog/catalog-*.json", "voice-model-catalog.schema.json"),
    ("fixtures/voice-model-catalog/draft-*.catalog.json", "voice-model-catalog.schema.json"),
    ("fixtures/voice-model-catalog/test-keys.json", "voice-model-catalog-test-keys.schema.json"),
    ("fixtures/voice-model-catalog/neighbour-inputs.json", "voice-model-catalog-neighbour-inputs.schema.json"),
    ("fixtures/podcast-search/test-names.json", "podcast-search-test-list.schema.json"),
    ("fixtures/podcast-search/itunes-responses/*.json", "itunes-search-response.schema.json"),
    ("traces/*.json", "session-trace.schema.json"),
]

NEGATIVE_PATH_SCHEMA_RULES = [
    ("fixtures/invalid/interjection-packages/*.json", "spoken-margins-package.schema.json"),
    ("fixtures/invalid/source-catalog/*.json", "source-catalog.schema.json"),
    ("fixtures/invalid/source-resolution/*.json", "source-resolution.schema.json"),
    ("fixtures/invalid/voice-model-catalog/*.json", "voice-model-catalog-envelope.schema.json"),
    ("fixtures/invalid/listening-signals/*.json", "i4-engagement.schema.json"),
]

# Remote source catalogs (seam I2): the published catalog and its manifest, and each
# fixture manifest with the fixture catalog of the same name.
SOURCE_CATALOG_PAIRS = [
    (ROOT / "Site/onboarding/catalog/v1/manifest.json", ROOT / "Site/onboarding/catalog/v1/catalog.json"),
    (CONTRACTS / "fixtures/source-catalog-manifest/top-podcasts-small.json",
     CONTRACTS / "fixtures/source-catalog/top-podcasts-small.json"),
]


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_file(path: Path, schema_path: Path, mode: str | None = None) -> list[str]:
    schema = load_json(schema_path)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    if mode == "jsonl":
        with path.open("r", encoding="utf-8") as handle:
            instances = [json.loads(line) for line in handle if line.strip()]
    else:
        instance = load_json(path)
        instances = instance if mode == "array" else [instance]
    errors: list[str] = []
    for index, value in enumerate(instances):
        prefix = f"{path}"
        if mode == "array":
            prefix += f"[{index}]"
        elif mode == "jsonl":
            prefix += f":{index + 1}"
        for error in sorted(validator.iter_errors(value), key=lambda err: list(err.path)):
            location = ".".join(str(part) for part in error.path) or "<root>"
            errors.append(f"{prefix}: {location}: {error.message}")
    return errors


def check_issued_at(path: Path, catalog: dict) -> list[str]:
    """jsonschema's FormatChecker skips date-time unless an optional package is installed, so check it here."""
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})", str(catalog.get("issuedAt", ""))):
        return [f"{path}: issuedAt {catalog.get('issuedAt')!r} is not an RFC 3339 date-time"]
    return []


def validate_voice_catalogs() -> list[str]:
    """The signed voice catalog (#1816): each envelope's payload is a valid catalog, the field rules in
    the schema agree with the neighbouring-input table, and the Supertonic draft lists the bundled files."""
    errors: list[str] = []
    folder = CONTRACTS / "fixtures/voice-model-catalog"
    if not folder.is_dir():
        # A Contracts tree without the voice catalog (the sharing-fixture tests build one) has nothing to check;
        # the SessionKit tests fail if the real folder's fixtures go missing.
        return errors
    catalog_schema = load_json(SCHEMAS / "voice-model-catalog.schema.json")
    for envelope_path in sorted(folder.glob("envelope-*.json")):
        payload = base64.b64decode(load_json(envelope_path)["payload"])
        validator = Draft202012Validator(catalog_schema, format_checker=FormatChecker())
        catalog = json.loads(payload)
        for error in validator.iter_errors(catalog):
            location = ".".join(str(part) for part in error.path) or "<root>"
            errors.append(f"{envelope_path}: payload: {location}: {error.message}")
        errors += check_issued_at(envelope_path, catalog)
    table = load_json(folder / "neighbour-inputs.json")
    rule_schemas = {
        "sha256": catalog_schema["$defs"]["sha256"],
        "httpsURL": catalog_schema["$defs"]["httpsURL"],
        "filePath": catalog_schema["$defs"]["filePath"],
        "id": catalog_schema["$defs"]["id"],
        "spdxId": catalog_schema["$defs"]["license"]["properties"]["spdxId"],
        "runtimeName": catalog_schema["$defs"]["voice"]["properties"]["runtime"]["properties"]["name"],
    }
    for rule, rule_schema in rule_schemas.items():
        validator = Draft202012Validator(rule_schema)
        for row in table[rule]:
            if validator.is_valid(row["value"]) != row["valid"]:
                errors.append(f"{folder / 'neighbour-inputs.json'}: schema {rule} judges {row['value']!r} ({row['why']}) wrongly")
    for draft_path in sorted(folder.glob("draft-*.catalog.json")):
        errors += check_issued_at(draft_path, load_json(draft_path))
    errors += voice_catalog_tools.check_envelope_payloads()
    errors += voice_catalog_tools.check_draft_matches_manifest()
    errors += validate_voice_sources()
    return errors


def validate_voice_sources() -> list[str]:
    """The hand-kept source list behind the site's catalog (#1818): its own rules, and that the Supertonic entry
    builds exactly the reviewed draft, so the two lists of the same 23 files cannot drift apart."""
    path = CONTRACTS / "voice-models/sources.json"
    if not path.is_file():
        return []
    sources = load_json(path)
    errors = [f"{path}: {message}" for message in voice_catalog.validate_sources(sources, path.parent)]
    draft = load_json(voice_catalog_tools.DRAFT)["voices"][0]
    supertonic = next((v for v in sources["voices"] if v["id"] == draft["id"]), None)
    if supertonic is None:
        errors.append(f"{path}: no {draft['id']} voice, which the draft catalog lists")
    elif voice_catalog.voice_entry(sources, supertonic) != draft:
        errors.append(f"{path}: the {draft['id']} entry builds something other than {voice_catalog_tools.DRAFT.name}; they list the same files")
    return errors


def validate_trace_references(trace_path: Path) -> list[str]:
    trace = load_json(trace_path)
    errors: list[str] = []
    profile = trace.get("runtimeProfile")
    if profile:
        profile_path = CONTRACTS / "fixtures" / "capabilities" / f"{profile}.json"
        if not profile_path.exists():
            errors.append(f"{trace_path}: runtimeProfile {profile!r} has no capability fixture")
        else:
            capabilities = load_json(profile_path).get("capabilities", {})
            for category, required in trace.get("requiresCapabilities", {}).items():
                available = set(capabilities.get(category, []))
                for capability in required:
                    if capability not in available:
                        errors.append(
                            f"{trace_path}: requires {category}.{capability}, absent from {profile_path}"
                        )
    for label, value in trace.get("fixtures", {}).items():
        if isinstance(value, str) and not (CONTRACTS / value).exists():
            errors.append(f"{trace_path}: fixture {label} points to missing path {value}")
    return errors


def validate_source_catalog(path: Path) -> list[str]:
    """Rules JSON Schema can't express: unique ids and references that resolve."""
    catalog = load_json(path)
    errors: list[str] = []
    entry_ids = [entry["id"] for entry in catalog.get("entries", [])]
    subject_ids = {subject["id"] for subject in catalog.get("subjects", [])}
    provenance_ids = {item["id"] for item in catalog.get("provenance", [])}
    if len(entry_ids) != len(set(entry_ids)):
        errors.append(f"{path}: duplicate entry ids")
    # Scheme and host fold case; paths don't (Simplecast ids are mixed case).
    feeds = []
    for entry in catalog.get("entries", []):
        scheme, _, rest = entry["feedURL"].partition("://")
        host, slash, path = rest.partition("/")
        feeds.append(f"{scheme.lower()}://{host.lower()}{slash}{path}".rstrip("/"))
    if len(feeds) != len(set(feeds)):
        errors.append(f"{path}: duplicate feed URLs")
    for entry in catalog.get("entries", []):
        for subject in entry["subjects"]:
            if subject not in subject_ids:
                errors.append(f"{path}: {entry['id']} names unknown subject {subject!r}")
        referenced = set(entry["provenanceIds"]) | {pos["provenanceId"] for pos in entry.get("chartPositions", [])}
        for missing in sorted(referenced - provenance_ids):
            errors.append(f"{path}: {entry['id']} names unknown provenance {missing!r}")
    for row in catalog.get("starterRows", []):
        if row["subjectId"] not in subject_ids:
            errors.append(f"{path}: starter row names unknown subject {row['subjectId']!r}")
        for entry_id in row["entryIds"]:
            if entry_id not in entry_ids:
                errors.append(f"{path}: starter row {row['subjectId']} names unknown entry {entry_id!r}")
    return errors


def validate_source_catalog_pair(manifest_path: Path, catalog_path: Path) -> list[str]:
    errors = validate_file(manifest_path, SCHEMAS / "source-catalog-manifest.schema.json")
    errors += validate_file(catalog_path, SCHEMAS / "source-catalog.schema.json")
    if errors:
        return errors
    errors += validate_source_catalog(catalog_path)
    manifest = load_json(manifest_path)
    catalog = load_json(catalog_path)
    data = catalog_path.read_bytes()
    if manifest["catalogByteCount"] != len(data):
        errors.append(f"{manifest_path}: catalogByteCount {manifest['catalogByteCount']} != {len(data)}")
    if manifest["catalogChecksumSHA256"] != hashlib.sha256(data).hexdigest():
        errors.append(f"{manifest_path}: catalogChecksumSHA256 does not match {catalog_path.name}")
    for key in ("catalogId", "contentVersion"):
        if manifest[key] != catalog[key]:
            errors.append(f"{manifest_path}: {key} does not match {catalog_path.name}")
    return errors


def main(argv=()) -> int:
    # --allow-lfs-pointers: a checkout without Git LFS (the hosted portable plan, #1847) has pointer files
    # where the voice models go; the Supertonic check then compares each pointer's recorded size and hash.
    arguments = list(argv)
    unknown = [a for a in arguments if a != "--allow-lfs-pointers"]
    if unknown:
        print(f"usage: validate-contracts.py [--allow-lfs-pointers] (unknown: {' '.join(unknown)})", file=sys.stderr)
        return 2
    errors: list[str] = []
    for rule in PATH_SCHEMA_RULES:
        pattern, schema_name, *rest = rule
        mode = rest[0] if rest else None
        schema_path = SCHEMAS / schema_name
        for path in sorted(CONTRACTS.glob(pattern)):
            errors.extend(validate_file(path, schema_path, mode))
            if pattern == "fixtures/persistence/*.json":
                metadata = load_json(path)
                database = path.parent / metadata["database"]
                if not database.is_file() or hashlib.sha256(database.read_bytes()).hexdigest() != metadata["sha256"]:
                    errors.append(f"{path}: prior-build database missing or digest changed")
            if pattern == "traces/*.json":
                errors.extend(validate_trace_references(path))
            if pattern == "fixtures/source-catalog/*.json":
                errors.extend(validate_source_catalog(path))

    for manifest_path, catalog_path in SOURCE_CATALOG_PAIRS:
        errors.extend(validate_source_catalog_pair(manifest_path, catalog_path))

    errors.extend(validate_voice_catalogs())

    for pattern, schema_name in NEGATIVE_PATH_SCHEMA_RULES:
        schema_path = SCHEMAS / schema_name
        paths = sorted(CONTRACTS.glob(pattern))
        if not paths:
            errors.append(f"{pattern}: negative fixture family has no fixtures")
        for path in paths:
            if not validate_file(path, schema_path):
                errors.append(f"{path}: negative fixture unexpectedly passed {schema_name}")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"Contract validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1

    asset_validation = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "validate-supertonic-assets.py"), *arguments],
        check=False,
        text=True,
        capture_output=True,
    )
    if asset_validation.returncode != 0:
        print(asset_validation.stderr.rstrip(), file=sys.stderr)
        return asset_validation.returncode
    print(asset_validation.stdout.rstrip())

    print("Contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
