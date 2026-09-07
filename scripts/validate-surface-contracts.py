#!/usr/bin/env python3
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "Contracts"
SCHEMA_PATH = ROOT / "schemas" / "surface-contract.schema.json"
SURFACE_CONTRACTS = ROOT / "validation" / "surface-contracts"
COMMAND_MATRIX = ROOT / "validation" / "contracts" / "command-matrix.json"
SNAPSHOT_FIELDS = ROOT / "validation" / "contracts" / "snapshot-fields.json"
DELEGATION_MODES = ROOT / "validation" / "contracts" / "delegation-modes.json"


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_schema(path: Path, schema: dict) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    instance = load_json(path)
    errors: list[str] = []
    for error in sorted(validator.iter_errors(instance), key=lambda err: list(err.path)):
        location = ".".join(str(part) for part in error.path) or "<root>"
        errors.append(f"{path}: {location}: {error.message}")
    return errors


def ids_from_matrix(path: Path, key: str) -> set[str]:
    matrix = load_json(path)
    return {entry["id"] for entry in matrix.get(key, [])}


def validate_contract_references(path: Path, contract: dict) -> list[str]:
    errors: list[str] = []
    command_ids = ids_from_matrix(COMMAND_MATRIX, "commands")
    snapshot_fields = ids_from_matrix(SNAPSHOT_FIELDS, "fields")
    delegation_modes = ids_from_matrix(DELEGATION_MODES, "modes")

    profile = contract["runtimeProfile"]
    profile_path = CONTRACTS / "fixtures" / "capabilities" / f"{profile}.json"
    if not profile_path.exists():
        errors.append(f"{path}: runtimeProfile {profile!r} has no capability fixture")
    else:
        profile_doc = load_json(profile_path)
        if profile_doc.get("id") != profile:
            errors.append(f"{path}: runtimeProfile {profile!r} does not match {profile_path} id")

    for field in contract["snapshotFields"]:
        if field not in snapshot_fields:
            errors.append(f"{path}: snapshot field {field!r} is not listed in {SNAPSHOT_FIELDS}")

    for command in contract["commands"]:
        command_id = command["id"]
        if command_id not in command_ids:
            errors.append(f"{path}: command {command_id!r} is not listed in {COMMAND_MATRIX}")
        mode = command["delegationMode"]
        if mode not in delegation_modes:
            errors.append(f"{path}: delegation mode {mode!r} is not listed in {DELEGATION_MODES}")

    for trace in contract["traces"]:
        trace_path = CONTRACTS / trace
        if not trace_path.exists():
            errors.append(f"{path}: trace {trace!r} does not exist")
            continue
        trace_doc = load_json(trace_path)
        trace_profile = trace_doc.get("runtimeProfile")
        if trace_profile and trace_profile != profile:
            errors.append(
                f"{path}: trace {trace!r} runtimeProfile {trace_profile!r} does not match {profile!r}"
            )

    for fixture in contract["fixtures"]:
        if not (CONTRACTS / fixture).exists():
            errors.append(f"{path}: fixture {fixture!r} does not exist")

    return errors


def main() -> int:
    schema = load_json(SCHEMA_PATH)
    errors: list[str] = []
    paths = sorted(SURFACE_CONTRACTS.glob("*.json"))
    if not paths:
        errors.append(f"{SURFACE_CONTRACTS}: no surface contract files found")

    for path in paths:
        errors.extend(validate_schema(path, schema))
        if not errors or not any(str(path) in error for error in errors):
            errors.extend(validate_contract_references(path, load_json(path)))

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"Surface contract validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1

    print("Surface contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
