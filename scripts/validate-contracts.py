#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "Contracts"
SCHEMAS = CONTRACTS / "schemas"


PATH_SCHEMA_RULES = [
    ("fixtures/capabilities/*.json", "runtime-capability-profile.schema.json"),
    ("fixtures/items/*.json", "item.schema.json"),
    ("fixtures/maps/*.json", "listening-map.schema.json"),
    ("fixtures/sessions/*.json", "session.schema.json"),
    ("fixtures/interjections/*.json", "interjection.schema.json"),
    ("fixtures/interjection-packages/*.json", "spoken-margins-package.schema.json"),
    ("fixtures/sharing/cleanup-revision.json", "interjection-share-revision.schema.json"),
    ("fixtures/sharing/commentary-layer.json", "shared-commentary-layer.schema.json"),
    ("fixtures/sharing/listening-map-proposal.json", "portable-listening-map-proposal.schema.json"),
    ("fixtures/turns/*.json", "conversation-turn.schema.json", "array"),
    ("fixtures/exports/*.json", "session-export.schema.json"),
    ("fixtures/watch/offline-package.json", "watch-audio-package.schema.json"),
    ("fixtures/watch/sync-*-event.json", "watch-sync-event.schema.json"),
    ("fixtures/audio/*.json", "audio-asset.schema.json"),
    ("fixtures/link-resolution/*.json", "link-resolution-fixture.schema.json"),
    ("fixtures/transcripts/*.json", "transcript.schema.json"),
    ("traces/*.json", "session-trace.schema.json"),
]

NEGATIVE_PATH_SCHEMA_RULES = [
    ("fixtures/invalid/interjection-packages/*.json", "spoken-margins-package.schema.json"),
]


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_file(path: Path, schema_path: Path, mode: str | None = None) -> list[str]:
    schema = load_json(schema_path)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    instance = load_json(path)
    instances = instance if mode == "array" else [instance]
    errors: list[str] = []
    for index, value in enumerate(instances):
        prefix = f"{path}"
        if mode == "array":
            prefix += f"[{index}]"
        for error in sorted(validator.iter_errors(value), key=lambda err: list(err.path)):
            location = ".".join(str(part) for part in error.path) or "<root>"
            errors.append(f"{prefix}: {location}: {error.message}")
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


def main() -> int:
    errors: list[str] = []
    for rule in PATH_SCHEMA_RULES:
        pattern, schema_name, *rest = rule
        mode = rest[0] if rest else None
        schema_path = SCHEMAS / schema_name
        for path in sorted(CONTRACTS.glob(pattern)):
            errors.extend(validate_file(path, schema_path, mode))
            if pattern == "traces/*.json":
                errors.extend(validate_trace_references(path))

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
        [sys.executable, str(ROOT / "scripts" / "validate-supertonic-assets.py")],
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
    raise SystemExit(main())
