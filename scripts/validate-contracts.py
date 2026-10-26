#!/usr/bin/env python3
import base64
import importlib.util
import json
import hashlib
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

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
    ("fixtures/invalid/voice-model-catalog-payload/*.json", "voice-model-catalog.schema.json"),
    ("fixtures/invalid/listening-signals/*.json", "i4-engagement.schema.json"),
]

# Remote source catalogs (seam I2): the published catalog and its manifest, and each
# fixture manifest with the fixture catalog of the same name.
PUBLISHED_CATALOG = ROOT / "Site/onboarding/catalog/v1/catalog.json"
SOURCE_CATALOG_PAIRS = [
    (ROOT / "Site/onboarding/catalog/v1/manifest.json", PUBLISHED_CATALOG),
    (CONTRACTS / "fixtures/source-catalog-manifest/top-podcasts-small.json",
     CONTRACTS / "fixtures/source-catalog/top-podcasts-small.json"),
]


# The published starter catalog is built from each show's own feed (#1732). Apple's chart and lookup data and
# its image servers are off limits: research/B1/build_catalog.py keeps the same host list.
APPLE_HOST_SUFFIXES = ("mzstatic.com", "apple.com", "apple.co", "itunes.com", "apple-dns.net", "aaplimg.com", "cdn-apple.com", "icloud.com")
APPLE_PROVENANCE_KINDS = ("apple_top_chart", "itunes_lookup")


def is_apple_url(url: str) -> bool:
    host = (urlsplit(url).hostname or "").lower()
    return any(host == suffix or host.endswith("." + suffix) for suffix in APPLE_HOST_SUFFIXES)


def validate_no_apple_data(path: Path) -> list[str]:
    """The published catalog carries no Apple chart data and no Apple-hosted URLs."""
    catalog = load_json(path)
    errors: list[str] = []
    for item in catalog.get("provenance", []):
        if (item["kind"] in APPLE_PROVENANCE_KINDS or is_apple_url(item.get("url", ""))
                or "appleGenreId" in item or "chartUpdatedAt" in item):
            errors.append(f"{path}: provenance {item['id']!r} is Apple data ({item['kind']})")
    for subject in catalog.get("subjects", []):
        if "appleGenreId" in subject:
            errors.append(f"{path}: subject {subject['id']!r} carries an Apple genre id")
    for entry in catalog.get("entries", []):
        for field in ("feedURL", "artworkURL", "websiteURL"):
            if is_apple_url(entry.get(field, "")):
                errors.append(f"{path}: {entry['id']} {field} points at Apple: {entry[field]}")
        if entry.get("chartPositions"):
            errors.append(f"{path}: {entry['id']} carries Apple chart ranks")
        if "applePodcastsId" in entry.get("externalIds", {}):
            errors.append(f"{path}: {entry['id']} carries an Apple Podcasts id")
    return errors


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
        "minimumChip": catalog_schema["$defs"]["voice"]["properties"]["minimumChip"],
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


def validate_source_catalog_pair(manifest_path: Path, catalog_path: Path, *, published: bool = False) -> list[str]:
    errors = validate_file(manifest_path, SCHEMAS / "source-catalog-manifest.schema.json")
    errors += validate_file(catalog_path, SCHEMAS / "source-catalog.schema.json")
    if errors:
        return errors
    errors += validate_source_catalog(catalog_path)
    if published:
        errors += validate_no_apple_data(catalog_path)
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


# --- portable formats (#1386): the public schema, the reference reader and the app's Swift code agree ----------

PUBLIC_CONTRACTS = ROOT / "Contracts"
SWIFT_SOURCES = ROOT / "Packages" / "SessionKit" / "Sources"
SHIPPED_READER_SOURCES = ROOT / "Packages" / "SessionKit" / "Tests" / "ShippedReader"
# The reader the app ships, and Build 29's frozen copy of it: packets must open in both.
SWIFT_READERS = (
    SWIFT_SOURCES / "SessionKitSharing" / "InterjectionPackageArchive.swift",
    ROOT / "Packages" / "SessionKit" / "Tests" / "ShippedReader" / "SessionKitSharing" / "InterjectionPackageArchive.swift",
)
# Each portable format: the Swift type whose constant names its version, and the public schema for it (if any).
PORTABLE_VERSIONS = {
    "SpokenMarginsPackageArchive": "spoken-margins-package.schema.json",
    "SharedCommentaryLayerArtifact": "shared-commentary-layer.schema.json",
    "PortableListeningMapProposalArtifact": "portable-listening-map-proposal.schema.json",
    "MarginConversationArtifact": "margin-conversation.schema.json",
    "EmbeddedTextItemArtifact": None,
    "EditionFingerprintSpineArtifact": None,
    "TranscriptPhraseSketchArtifact": None,
    "ListeningEdition": "listening-edition.schema.json",
    "SessionExport": "session-export.schema.json",
}
ARTIFACT_TYPES = {
    "commentary_layer": "SharedCommentaryLayerArtifact",
    "listening_map_proposal": "PortableListeningMapProposalArtifact",
    "conversation": "MarginConversationArtifact",
    "embedded_text_item": "EmbeddedTextItemArtifact",
    "edition_fingerprint_spine": "EditionFingerprintSpineArtifact",
    "transcript_phrase_sketch": "TranscriptPhraseSketchArtifact",
}
# rejectUnknownKeys context in the Swift reader -> (reference reader set, path to the object in the schema)
MANIFEST_SHAPES = {
    "manifest": ("MANIFEST_KEYS", ()),
    "item": ("ITEM_KEYS", ("$defs", "item")),
    "source": ("SOURCE_KEYS", ("$defs", "item", "properties", "source", "anyOf", 0)),
    "item transport": ("TRANSPORT_KEYS", ("$defs", "itemTransport")),
    "redactions": ("REDACTION_KEYS", ("$defs", "redactions")),
    "artifact descriptor": ("ARTIFACT_KEYS", ("$defs", "artifact")),
    "asset descriptor": ("ASSET_KEYS", ("$defs", "asset")),
}


def load_reference_reader():
    spec = importlib.util.spec_from_file_location(
        "spoken_margins_format", PUBLIC_CONTRACTS / "tools" / "spoken_margins_format.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(spec.name, module)
    spec.loader.exec_module(module)
    return module


def swift_version_constants(sources: Path = SWIFT_SOURCES) -> dict[str, str]:
    """{Swift type name: its version string}, from `static let schemaVersion|version = "…"` or a stored
    `var schemaVersion: String = "…"` inside that type."""
    found: dict[str, str] = {}
    declaration = re.compile(r"^\s*(?:public\s+)?(?:final\s+)?(?:struct|enum|class)\s+(\w+)")
    constant = re.compile(r'(?:static let (?:schemaVersion|version)|var schemaVersion: String) = "([^"]+)"')
    for path in sorted(sources.rglob("*.swift")):
        current = None
        for line in path.read_text(encoding="utf-8").splitlines():
            if match := declaration.match(line):
                current = match.group(1)
            elif current and (match := constant.search(line)) and current not in found:
                found[current] = match.group(1)
    return found


def swift_allowed_keys(path: Path) -> dict[str, set[str]]:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r'rejectUnknownKeys\(\s*\w+,\s*allowed:\s*\[([^\]]*)\],\s*context:\s*"([^"]+)"', re.S)
    return {context: set(re.findall(r'"([^"]+)"', keys)) for keys, context in pattern.findall(text)}


def _swift_masks(text: str) -> tuple[str, str]:
    """(code, literals): the text with comments blanked, and the same with string contents also blanked to `x`.
    Both keep every offset, so a brace found in the second is the brace in the first."""
    code, masked = list(text), list(text)
    index, length = 0, len(text)
    while index < length:
        two = text[index:index + 2]
        if two == "//":
            end = text.find("\n", index)
            end = length if end < 0 else end
            for i in range(index, end):
                code[i] = masked[i] = " "
            index = end
        elif two == "/*":
            end = text.find("*/", index + 2)
            end = length if end < 0 else end + 2
            for i in range(index, end):
                if text[i] != "\n":
                    code[i] = masked[i] = " "
            index = end
        elif text[index] == '"':
            triple = text.startswith('"""', index)
            quote = '"""' if triple else '"'
            end = index + len(quote)
            while end < length and not text.startswith(quote, end):
                end += 2 if text[end] == "\\" else 1
            for i in range(index + len(quote), min(end, length)):
                if text[i] != "\n":
                    masked[i] = "x"
            index = end + len(quote)
        else:
            index += 1
    return "".join(code), "".join(masked)


_SWIFT_DECLARATION = re.compile(r"\b(struct|enum|class)\s+(\w+)[^{};]*\{")
_SWIFT_PROPERTY = re.compile(r"^\s*(?:public\s+)?(?:let|var)\s+(\w+)\s*:\s*([^={}\n]+?)\s*(?:=[^\n{}]*)?$", re.M)


def swift_declarations(root: Path) -> tuple[dict[str, dict[str, str]], dict[str, set[str]], set[str]]:
    """(structs, enums, custom): the stored properties ({name: type}) of each struct and the raw values of each
    enum under `root`, a nested type as `Outer.Inner`; `custom` names the types with their own `init(from:)`."""
    structs: dict[str, dict[str, str]] = {}
    enums: dict[str, set[str]] = {}
    custom: set[str] = set()

    def scan(code: str, masked: str, start: int, end: int, prefix: str) -> None:
        position = start
        while match := _SWIFT_DECLARATION.search(masked, position, end):
            depth, close = 1, match.end()
            while close < end and depth:
                depth += (masked[close] == "{") - (masked[close] == "}")
                close += 1
            name = prefix + match.group(2)
            body_start, body_end = match.end(), close - 1
            scan(code, masked, body_start, body_end, name + ".")
            flat, flat_code, nested = [], [], 0       # the body's own lines, with every {...} block emptied
            for i in range(body_start, body_end):
                char = masked[i]
                nested += (char == "{") - (char == "}")
                keep = nested == 0 or char in "{}\n"
                flat.append(char if keep else " ")
                flat_code.append(code[i] if keep else " ")
            flat_text, flat_literals = "".join(flat), "".join(flat_code)
            if match.group(1) == "enum":
                values = enums.setdefault(name, set())
                for case in re.finditer(r"^[ \t]*case[ \t]+([^\n{}]+)$", flat_literals, re.M):
                    for label, raw in re.findall(r'(\w+)\s*(?:=\s*"([^"]*)")?', case.group(1)):
                        values.add(raw or label)
            elif match.group(1) == "struct":
                fields = structs.setdefault(name, {})
                for prop in _SWIFT_PROPERTY.finditer(flat_text):
                    line = prop.group(0)
                    if "static" in line or "{" in line:
                        continue
                    fields[prop.group(1)] = re.sub(r"\s+", "", prop.group(2))
            if "init(from" in masked[body_start:body_end]:
                custom.add(name)
            position = close

    for path in sorted(root.rglob("*.swift")):
        code, masked = _swift_masks(path.read_text(encoding="utf-8"))
        scan(code, masked, 0, len(masked), "")
    return structs, enums, custom


def codable_problems(reader) -> list[str]:
    """The reader's table of Swift types against the structs and enums in the app and in Build 29's frozen copy."""
    problems: list[str] = []
    for label, root in (("the app", SWIFT_SOURCES), ("Build 29's frozen reader", SHIPPED_READER_SOURCES)):
        structs, enums, custom = swift_declarations(root)
        for name, fields in reader.SWIFT_TYPES.items():
            declared = structs.get(name)
            if declared is None:
                if root == SWIFT_SOURCES:
                    problems.append(f"portable formats: {name} is not a struct in {label}")
                continue            # a type a build never shipped is one it doesn't read
            if name in custom:
                problems.append(f"portable formats: {name} in {label} decodes by hand; decode_problem() models "
                                "synthesized Codable only")
            if declared != fields:
                changed = sorted(k for k in set(declared) | set(fields) if declared.get(k) != fields.get(k))
                problems.append(f"portable formats: {name} differs between {label} and the reference reader's "
                                f"SWIFT_TYPES at {changed}")
        for name, values in reader.SWIFT_ENUMS.items():
            declared = enums.get(name)
            if declared is None:
                if root == SWIFT_SOURCES:
                    problems.append(f"portable formats: {name} is not an enum in {label}")
            elif declared != set(values):
                problems.append(f"portable formats: {name} values differ between {label} {sorted(declared)} and the "
                                f"reference reader {sorted(values)}")
    return problems


def portable_format_problems(reader=None) -> list[str]:
    reader = reader or load_reference_reader()
    problems: list[str] = []
    versions = swift_version_constants()
    schemas = PUBLIC_CONTRACTS / "schemas"

    for type_name, schema_name in PORTABLE_VERSIONS.items():
        if type_name not in versions:
            problems.append(f"portable formats: no version constant for {type_name} under {SWIFT_SOURCES}")
            continue
        if schema_name:
            schema = load_json(schemas / schema_name)
            constant = schema.get("properties", {}).get("schemaVersion", {}).get("const")
            if constant != versions[type_name]:
                problems.append(f"portable formats: {schema_name} names {constant!r}, the app writes "
                                f"{versions[type_name]!r} ({type_name})")
    if reader.PACKAGE_SCHEMA_VERSION != versions.get("SpokenMarginsPackageArchive"):
        problems.append("portable formats: the reference reader's package version differs from the app's")
    for kind, type_name in ARTIFACT_TYPES.items():
        if reader.ARTIFACT_VERSIONS.get(kind) != versions.get(type_name):
            problems.append(f"portable formats: the reference reader reads {kind} at "
                            f"{reader.ARTIFACT_VERSIONS.get(kind)!r}, the app at {versions.get(type_name)!r}")
    models = (SWIFT_SOURCES / "SessionKit" / "SharingModels.swift").read_text(encoding="utf-8")
    kind_block = re.search(r"enum SpokenMarginsArtifactKind \{(.*?)\n\}", models, re.S)
    swift_kinds = set(re.findall(r'= "([^"]+)"', kind_block.group(1))) if kind_block else set()
    if swift_kinds != set(reader.ARTIFACT_VERSIONS):
        problems.append(f"portable formats: artifact kinds differ: app {sorted(swift_kinds)}, reference reader "
                        f"{sorted(reader.ARTIFACT_VERSIONS)}")

    problems.extend(codable_problems(reader))
    if reader.KIND_SWIFT_TYPE != ARTIFACT_TYPES:
        problems.append("portable formats: the reference reader decodes the artifact kinds as different Swift types")

    package_schema = load_json(schemas / "spoken-margins-package.schema.json")
    for swift_reader in SWIFT_READERS:
        source = swift_reader.read_text(encoding="utf-8")
        allowed = swift_allowed_keys(swift_reader)
        label = swift_reader.relative_to(ROOT)
        for context, (reader_set, schema_path) in MANIFEST_SHAPES.items():
            node = package_schema
            for step in schema_path:
                try:
                    node = node[step]
                except (KeyError, IndexError, TypeError):
                    node = {}
                    break
            schema_keys = set(node.get("properties", {}))
            reader_keys = set(getattr(reader, reader_set))
            if allowed.get(context) != reader_keys or reader_keys != schema_keys:
                problems.append(f"portable formats: {context} keys differ: {label} {sorted(allowed.get(context, []))}, "
                                f"reference reader {sorted(reader_keys)}, schema {sorted(schema_keys)}")
        for context, keys, _, entry_context, entry_keys in reader.CLOSED_ARTIFACTS.values():
            for name, expected in ((context, keys), (entry_context, entry_keys)):
                if name in allowed and allowed[name] != set(expected):
                    problems.append(f"portable formats: {name} keys differ: {label} {sorted(allowed[name])}, "
                                    f"reference reader {sorted(expected)}")
                elif name not in allowed and swift_reader == SWIFT_READERS[0]:
                    problems.append(f"portable formats: {label} no longer checks {name} keys")
        block = re.search(r"supportedRequiredCapabilities: Set<String> = \[(.*?)\]", source, re.S)
        names = re.findall(r"(\w+)\.schemaVersion", block.group(1)) if block else []
        if {versions.get(name) for name in names} != set(reader.SUPPORTED_REQUIRED_CAPABILITIES):
            problems.append(f"portable formats: {label} supports the required capabilities {names}, the reference "
                            f"reader {sorted(reader.SUPPORTED_REQUIRED_CAPABILITIES)}")

    # The app bundles Contracts/ itself; no other copy of a schema may sit beside it.
    legacy = {path.name for path in (ROOT / "schemas").glob("*.json")}
    for name in sorted(legacy & {path.name for path in schemas.glob("*.json")}):
        problems.append(f"portable formats: schemas/{name} is a second copy of Contracts/schemas/{name}")

    examples = PUBLIC_CONTRACTS / "examples" / "packets"
    expectations = json.loads((examples / "expectations.json").read_text(encoding="utf-8"))["packets"]
    on_disk = {path.name for path in examples.glob("*.spokenmargins")}
    for name in sorted(on_disk ^ set(expectations)):
        problems.append(f"portable formats: {name} is in only one of {examples} and expectations.json")
    fresh = reader.corpus(examples)
    for name, expected in sorted(expectations.items()):
        if name not in on_disk:
            continue
        committed = (examples / name).read_bytes()
        for label, data in (("committed", committed), ("regenerated", fresh.get(name))):
            if data is None:
                continue
            report = reader.read_packet(data, label=name)
            verdict = "valid" if not report.errors else report.errors[0].code
            if verdict != expected["reference"]:
                problems.append(f"portable formats: {label} {name} reads as {verdict!r}, expected "
                                f"{expected['reference']!r} (swift: {expected['swift']})")
            if expected.get("warning") and expected["warning"] not in {w.code for w in report.warnings}:
                problems.append(f"portable formats: {label} {name} lacks the warning {expected['warning']!r}")
        if name in fresh and reader.unpack(fresh[name])[0] != reader.unpack(committed)[0]:
            problems.append(f"portable formats: {name} is stale; run `Contracts/tools/spoken_margins_format.py "
                            f"corpus {examples.relative_to(ROOT)}`")
    return problems


def main(argv=()) -> int:
    # --allow-lfs-pointers: a checkout without Git LFS (the hosted portable plan, #1847) has pointer files
    # where the voice models go; the Supertonic check then compares each pointer's recorded size and hash.
    arguments = list(argv)
    unknown = [a for a in arguments if a != "--allow-lfs-pointers"]
    if unknown:
        print(f"usage: validate-contracts.py [--allow-lfs-pointers] (unknown: {' '.join(unknown)})", file=sys.stderr)
        return 2
    errors: list[str] = []
    errors.extend(portable_format_problems())
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
        # Only the published catalog is held to the no-Apple rule; the fixtures are test data.
        errors.extend(validate_source_catalog_pair(manifest_path, catalog_path, published=catalog_path == PUBLISHED_CATALOG))

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
