#!/usr/bin/env python3
"""Reference reader and validator for the Spoken Margins portable formats (#1386).

It runs without the app, without Swift and without a network. The standard library is enough for packets;
JSON documents (session exports, Listening Editions, Listening Maps) also need `jsonschema`.

    spoken_margins_format.py check FILE...        validate .spokenmargins packets and portable JSON documents
    spoken_margins_format.py check --strict ...   also fail on warnings (a link that looks private)
    spoken_margins_format.py check --json ...     print the findings as JSON
    spoken_margins_format.py inspect PACKET       print a packet's manifest summary and Margins as JSON
    spoken_margins_format.py corpus OUT_DIR       rewrite the example packet corpus (see Contracts/README.md)

Exit codes: 0 every file is valid, 1 a file is invalid, 2 the command line is wrong.

The rules mirror `SpokenMarginsPackageArchive.read` in
`Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift`. That Swift reader is the
authority. This one covers the container, the manifest, the descriptors, the digest, the preview and the
commentary layer; it does not repeat the Listening Map scene rules or decode audio (see Contracts/README.md,
"What the reference reader does not check").
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import unicodedata
import urllib.parse
import uuid
import zipfile

CONTRACTS = Path(__file__).resolve().parents[1]
SCHEMAS = CONTRACTS / 'schemas'

PACKAGE_SCHEMA_VERSION = 'spoken-margins.package.v1'
FILE_EXTENSION = 'spokenmargins'
MIME_TYPE = 'application/vnd.spokenmargins.package+zip'

COMMENTARY_LAYER_VERSION = 'spoken-margins.commentary-layer.v1'
LISTENING_MAP_PROPOSAL_VERSION = 'spoken-margins.listening-map-proposal.v2'
EMBEDDED_TEXT_ITEM_VERSION = 'spoken-margins.embedded-text-item.v1'
FINGERPRINT_SPINE_VERSION = 'spoken-margins.edition-fingerprint-spine.v1'
PHRASE_SKETCH_VERSION = 'spoken-margins.transcript-phrase-sketch.v1'
CONVERSATION_VERSION = 'spoken-margins.margin-conversation.v1'

# SpokenMarginsPackageArchive.supportedRequiredCapabilities
SUPPORTED_REQUIRED_CAPABILITIES = frozenset({COMMENTARY_LAYER_VERSION, EMBEDDED_TEXT_ITEM_VERSION})

# SpokenMarginsArtifactKind, with the one schema version each kind is read at.
ARTIFACT_VERSIONS = {
    'commentary_layer': COMMENTARY_LAYER_VERSION,
    'listening_map_proposal': LISTENING_MAP_PROPOSAL_VERSION,
    'edition_fingerprint_spine': FINGERPRINT_SPINE_VERSION,
    'transcript_phrase_sketch': PHRASE_SKETCH_VERSION,
    'embedded_text_item': EMBEDDED_TEXT_ITEM_VERSION,
    'conversation': CONVERSATION_VERSION,
}
# A kind whose version doesn't match is refused even when it isn't required (the reader can't skip it).
ALWAYS_REQUIRED_KINDS = frozenset({'commentary_layer', 'embedded_text_item'})

# The keys the manifest may hold. The shipped readers (this build's and Build 29's frozen copy) refuse any
# other key, so a writer that adds one makes a packet no shipped build opens. test_portable_formats.py checks
# these sets against the Swift source and against Contracts/schemas/spoken-margins-package.schema.json.
MANIFEST_KEYS = frozenset({
    'schemaVersion', 'packageId', 'createdAt', 'contentDigest', 'item', 'itemTransport', 'senderDisplayLabel',
    'suggestedRevealMode', 'requiredCapabilities', 'artifacts', 'assets', 'redactions',
})
ITEM_KEYS = frozenset({
    'itemType', 'canonicalURL', 'originalURL', 'title', 'author', 'publisher', 'showTitle', 'episodeGUID',
    'enclosureURL', 'publishedAt', 'durationMs', 'normalizedContentSHA256', 'exactEditionSHA256', 'languageCode',
    'source',
})
SOURCE_KEYS = frozenset({'sourceType', 'canonicalURL', 'title', 'publisher'})
TRANSPORT_KEYS = frozenset({'kind', 'embeddedArtifactId', 'rightsBasis'})
REDACTION_KEYS = frozenset({
    'rawAudioOmitted', 'rawTranscriptOmitted', 'fullItemOmitted', 'itemAudioOmitted', 'diagnosticsOmitted',
    'filesystemPathsOmitted', 'unrelatedTurnsOmitted', 'privateRepresentationsOmitted',
})
# Every redaction but fullItemOmitted must be true (InterjectionPackageRedactions.provesPrivateMinimization).
PROVED_REDACTIONS = REDACTION_KEYS - {'fullItemOmitted'}
ARTIFACT_KEYS = frozenset({'id', 'kind', 'schemaVersion', 'path', 'required', 'byteCount', 'sha256'})
ASSET_KEYS = frozenset({'id', 'role', 'path', 'mimeType', 'durationMs', 'anchorOffsetMs', 'provenance', 'byteCount',
                        'sha256'})

# Three artifacts are closed like the manifest: (context, keys of the root, list field, keys of each entry).
CLOSED_ARTIFACTS = {
    'edition_fingerprint_spine': ('fingerprint spine', frozenset({
        'id', 'schemaVersion', 'itemId', 'canonicalURL', 'episodeGUID', 'producingEditionDurationMs',
        'producingEditionSHA256', 'createdAt', 'generatorVersion', 'landmarks'}), 'landmarks', 'fingerprint landmark',
        frozenset({'id', 'order', 'sourceMediaStartMs', 'sourceMediaEndMs', 'anchorMediaTimeMs', 'continuityEpoch',
                   'trigger', 'provenance', 'signatureAssetId', 'transcriptSketchWindowId', 'generatorVersion'})),
    'transcript_phrase_sketch': ('phrase sketch', frozenset({
        'id', 'schemaVersion', 'itemId', 'languageCode', 'saltBase64', 'normalizationVersion', 'shingleWidth',
        'maximumHashesPerWindow', 'createdAt', 'windows'}), 'windows', 'phrase sketch window',
        frozenset({'id', 'sourceStartMs', 'sourceEndMs', 'hashes'})),
    'conversation': ('conversation', frozenset({'id', 'schemaVersion', 'replies'}), 'replies', 'conversation reply',
                     frozenset({'packageScopedId', 'conversationId', 'parentPackageDigest', 'parentPackageScopedId'})),
}

ITEM_TYPES = frozenset({'text', 'podcast', 'pdf', 'epub', 'other'})
SOURCE_TYPES = frozenset({'podcast_feed', 'text_feed', 'newsletter', 'blog', 'social_feed', 'other'})
TRANSPORT_KINDS = frozenset({'reference', 'embedded_text', 'recipient_supplied'})
RIGHTS_BASES = frozenset({'app_authored', 'sender_confirmed_private_rights'})
REVEAL_MODES = frozenset({'fresh', 'companion', 'guided'})
ANCHOR_TYPES = frozenset({'text', 'transcript', 'media', 'turn'})
TEXT_REPRESENTATIONS = frozenset({'text_only', 'summary_text'})
AUDIO_REPRESENTATIONS = frozenset({'original_audio_and_text', 'cleaned_audio_and_text', 'summary_audio_and_text',
                                   'tts_audio_and_text'})
REPRESENTATION_PROVENANCE = frozenset({'sender_approved_original', 'deterministic_cleanup_v1_sender_approved',
                                       'sender_approved_text_only', 'sender_approved_summary', 'sender_approved_tts'})
ROLE_SIGNATURE = 'acoustic_signature'
ROLE_SUMMARY_VOICE = 'summary_voice'
SIGNATURE_MIME_TYPE = 'application/vnd.apple.shazam.signature'

MAX_PACKAGE_BYTES = 100 * 1024 * 1024
MAX_MANIFEST_BYTES = 1 * 1024 * 1024
MAX_ARTIFACT_BYTES = 5 * 1024 * 1024
MAX_AUDIO_BYTES = 20 * 1024 * 1024
MAX_EVIDENCE_BYTES = 1 * 1024 * 1024
MAX_MARGINS = 50
MAX_COMPRESSION_RATIO = 100
MAX_EXACT_TEXT = 1_000           # BoundedAnchorContext.maximumExactTextCharacters
MAX_CONTEXT_PER_SIDE = 500       # BoundedAnchorContext.maximumCharactersPerSide
FIXED_ZIP_DATE = (1980, 1, 1, 0, 0, 0)

_SHA256 = re.compile(r'[0-9a-f]{64}')
_COMPONENT = re.compile(r'[A-Za-z0-9._-]+')
# ISO8601DateFormatter's internet date-time, with or without fractional seconds.
_ISO_DATE = re.compile(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)')


@dataclass
class Finding:
    severity: str        # "error" refuses the file; "warning" is a note a shipped reader would not refuse on
    code: str
    message: str
    where: str = ''

    def line(self, file_label):
        where = f' {self.where}:' if self.where else ''
        return f'{file_label}: {self.severity} [{self.code}]{where} {self.message}'


@dataclass
class Report:
    path: str
    kind: str
    findings: list = field(default_factory=list)
    summary: dict = field(default_factory=dict)

    @property
    def errors(self):
        return [f for f in self.findings if f.severity == 'error']

    @property
    def warnings(self):
        return [f for f in self.findings if f.severity == 'warning']

    def ok(self, strict=False):
        return not self.errors and not (strict and self.warnings)

    def error(self, code, message, where=''):
        self.findings.append(Finding('error', code, message, where))

    def warn(self, code, message, where=''):
        self.findings.append(Finding('warning', code, message, where))

    def as_dict(self):
        return {'path': self.path, 'kind': self.kind, 'valid': not self.errors, 'summary': self.summary,
                'findings': [f.__dict__ for f in self.findings]}


class Refused(Exception):
    """The shipped reader stops at its first failure; so does the packet check, after recording it."""


# --- links -------------------------------------------------------------------------------------------------------

def is_https_url(value):
    """SpokenMarginsPackageArchive.validHTTPSURL: https, a host, no user or password, no whitespace or angle brackets."""
    if not isinstance(value, str) or any(c.isspace() for c in value) or '<' in value or '>' in value:
        return False
    try:
        parts = urllib.parse.urlsplit(value)
    except ValueError:
        return False
    return parts.scheme.lower() == 'https' and bool(parts.hostname) and parts.username is None and parts.password is None


# ShareableLinkPolicy (SessionKit): the exporter drops a link that carries an access secret or names a paid feed.
# The importer does not re-check, so a packet holding one still opens; this reader warns.
PRIVATE_HOST_SUFFIXES = ('patreon.com', 'patreonusercontent.com', 'supercast.com', 'supercast.tech',
                         'supportingcast.fm', 'memberful.com', 'memberfulcontent.com')
PRIVATE_PATH_MARKERS = frozenset({'private', 'premium', 'paid', 'subscriber', 'subscribers', 'member', 'members',
                                  'patron', 'patrons', 'supporter', 'supporters'})
CREDENTIAL_QUERY_FRAGMENTS = ('token', 'auth', 'key', 'secret', 'sig', 'hash', 'pass', 'pwd', 'session',
                              'credential', 'jwt', 'expire', 'policy', 'hmac', 'access')
PUBLIC_HEX_IDENTIFIER_FEED_HOSTS = ('rss.amperwave.net',)


def _looks_like_secret(value):
    trimmed = value.strip('=')
    if len(trimmed) < 32:
        return False
    try:
        uuid.UUID(trimmed)
        return False
    except ValueError:
        pass
    if not re.fullmatch(r'[A-Za-z0-9_-]+', trimmed):
        return False
    return any(c.isalpha() for c in trimmed) and any(c.isdigit() for c in trimmed)


def is_shareable_link(value):
    """True when the exporter would keep this link in a packet (no access secret in it)."""
    parts = urllib.parse.urlsplit(value)
    host = (parts.hostname or '').lower()
    if parts.scheme.lower() not in ('http', 'https') or not host or parts.username or parts.password:
        return False
    if any(host == s or host.endswith('.' + s) for s in PRIVATE_HOST_SUFFIXES):
        return False
    allows_hex = host in PUBLIC_HEX_IDENTIFIER_FEED_HOSTS
    for segment in (s for s in parts.path.split('/') if s):
        stem = segment.split('.', 1)[0]
        if stem.lower() in PRIVATE_PATH_MARKERS:
            return False
        if allows_hex and re.fullmatch(r'[0-9a-fA-F]{32}', stem):
            continue
        if _looks_like_secret(stem):
            return False
    for name, item_value in urllib.parse.parse_qsl(parts.query, keep_blank_values=True):
        if any(fragment in name.lower() for fragment in CREDENTIAL_QUERY_FRAGMENTS):
            return False
        if _looks_like_secret(item_value):
            return False
    return True


# --- encoding, digest and preview ---------------------------------------------------------------------------------

def _drop_nulls(value):
    if isinstance(value, dict):
        return {k: _drop_nulls(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [_drop_nulls(v) for v in value]
    return value


def _swift_date(value):
    """The manifest's createdAt as the Swift writer re-encodes it: UTC with milliseconds."""
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except (AttributeError, ValueError):
        return value
    if parsed.tzinfo is None:
        return value
    parsed = parsed.astimezone(timezone.utc)
    return parsed.strftime('%Y-%m-%dT%H:%M:%S.') + f'{parsed.microsecond // 1000:03d}Z'


def canonical_manifest_bytes(manifest):
    """The bytes the content digest covers: the manifest without contentDigest, as Swift's JSONEncoder writes it
    (sorted keys, no spaces, slashes unescaped, absent optionals left out)."""
    unsigned = _drop_nulls({k: v for k, v in manifest.items() if k != 'contentDigest'})
    if isinstance(unsigned.get('createdAt'), str):
        unsigned['createdAt'] = _swift_date(unsigned['createdAt'])
    return json.dumps(unsigned, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def encode_manifest(manifest):
    return json.dumps(_drop_nulls(manifest), sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def content_digest(manifest, preview, files):
    """SpokenMarginsPackageArchive.digest: the unsigned manifest, then each of preview.md and the declared files
    (in path order) as `path NUL sha256(bytes) NUL byte-count NUL`."""
    hasher = hashlib.sha256(canonical_manifest_bytes(manifest))

    def update(path, data):
        hasher.update(path.encode('utf-8') + b'\0' + hashlib.sha256(data).digest() + b'\0'
                      + str(len(data)).encode('ascii') + b'\0')

    update('preview.md', preview)
    for path in sorted(files):
        update(path, files[path])
    return hasher.hexdigest()


_MARKDOWN_ESCAPABLE = set('\\`*_{}[]<>()#+-!|>')


def _markdown_escaped(value):
    return ''.join('\\' + c if c in _MARKDOWN_ESCAPABLE else c for c in value)


def character_count(text):
    """Swift's String.count (grapheme clusters), close enough for the preview: combining marks and joiners
    don't start a new character."""
    count = 0
    previous_joiner = False
    for char in text:
        joins = unicodedata.combining(char) or char in '\u200d\ufe0f\ufe0e' or 0x1F3FB <= ord(char) <= 0x1F3FF
        if not joins and not previous_joiner:
            count += 1
        previous_joiner = char == '\u200d'
    return count


def preview_markdown(manifest, interjections, proposals=0, spines=0, sketches=0, embedded_text=None):
    """SpokenMarginsPackageArchive.previewMarkdown, which the reader compares byte for byte."""
    sender = ' '.join((manifest.get('senderDisplayLabel') or '').split())
    count = len(interjections)
    item = manifest.get('item') or {}
    assets = manifest.get('assets') or []
    kind = (manifest.get('itemTransport') or {}).get('kind')
    if kind == 'reference':
        transport = 'Item transport: reference only; the recipient reconstructs the item.'
    elif kind == 'recipient_supplied':
        transport = 'Item transport: not included; the recipient must provide the same item.'
    else:
        characters = character_count(embedded_text or '')
        transport = (f'Item transport: full listened-to text included ({characters} characters) after a '
                     'private-sharing rights confirmation.')
    canonical = item.get('canonicalURL')
    lines = [
        '# Spoken Margins', '',
        f"{_markdown_escaped(sender or 'Someone')} shared {count} reviewed Margin{'' if count == 1 else 's'} about "
        f"**{_markdown_escaped(item.get('title', ''))}**.",
        '',
        f'Item reference: <{canonical}>' if canonical is not None else 'Item reference: no public URL',
        '',
        transport,
        'Item audio is not included.',
        f"Voice assets: {sum(1 for a in assets if str(a.get('path', '')).startswith('assets/audio/'))}.",
        f"Acoustic signatures: {sum(1 for a in assets if a.get('role') == ROLE_SIGNATURE)}. These are opaque "
        'matching evidence, not item audio.',
        f'Listening Map proposals: {proposals}. Proposals are not activated automatically.',
        f'Episode fingerprint maps: {spines}. Transcript phrase sketches: {sketches}. Full episode transcripts and '
        'source audio are not included.', '',
    ]
    for index, interjection in enumerate(interjections):
        default_id = interjection.get('defaultRepresentationId')
        representation = next((r for r in interjection.get('representations') or [] if r.get('id') == default_id), None)
        lines += [f'## Margin {index + 1}', '',
                  _markdown_escaped(representation.get('approvedTranscript', '') if representation
                                    else 'Unavailable representation'), '']
    return '\n'.join(lines)


def normalized_content_sha256(text):
    """PortableArticleAnchorResolver.normalizedContentSHA256 for text Python folds the way Foundation does
    (returns None otherwise, and the caller skips the check)."""
    if not text.isascii():
        return None
    folded = re.sub(r'[^A-Za-z0-9]+', ' ', text.lower())
    folded = re.sub(r'\s+', ' ', folded).strip()
    return hashlib.sha256(folded.encode('utf-8')).hexdigest()


def exact_edition_sha256(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


# --- packet paths ---------------------------------------------------------------------------------------------

def _valid_nested_path(path, prefix, extensions):
    if not path.startswith(prefix) or '..' in path or '\\' in path or '//' in path:
        return False
    component = path[len(prefix):]
    if not component or '/' in component or not _COMPONENT.fullmatch(component):
        return False
    return Path(component).suffix.lstrip('.') in extensions


def valid_artifact_path(path):
    return _valid_nested_path(path, 'artifacts/', {'json'})


def valid_asset_path(path):
    return (_valid_nested_path(path, 'assets/audio/', {'m4a'})
            or _valid_nested_path(path, 'assets/evidence/', {'shazamsignature'}))


def allowed_package_path(path):
    return path in ('manifest.json', 'preview.md') or valid_artifact_path(path) or valid_asset_path(path)


def staged_file_name(descriptor):
    """Where an asset lands once extracted; two that land on one name (ignoring case) are refused."""
    suffix = Path(str(descriptor.get('path', ''))).suffix
    return re.sub(r'[^A-Za-z0-9._-]', '-', str(descriptor.get('id', ''))) + suffix


# --- the packet check ---------------------------------------------------------------------------------------

def _is_sha(value):
    return isinstance(value, str) and bool(_SHA256.fullmatch(value))


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _length_ok(value, maximum):
    return value is None or (isinstance(value, str) and character_count(value) <= maximum)


def _refuse(report, code, message, where=''):
    report.error(code, message, where)
    raise Refused


def _unknown_keys(report, document, allowed, context):
    unknown = sorted(set(document) - allowed)
    if unknown:
        _refuse(report, 'unknown-field', f"unknown {context} fields: {', '.join(unknown)} (shipped readers refuse a "
                f'{context} key they do not list; a new field needs a new version)')


def _check_link(report, value, where):
    if value is None:
        return
    if not is_https_url(value):
        _refuse(report, 'link-not-https', f'{value!r} is not an https link without a user name or password', where)
    if not is_shareable_link(value):
        report.warn('link-looks-private', f'{value!r} looks like a private or paid link; the exporter would have '
                    'left it out (ShareableLinkPolicy)', where)


def _check_zip(report, archive, size):
    if size > MAX_PACKAGE_BYTES:
        _refuse(report, 'too-large', 'the packet is larger than 100 MB')
    entries, seen, total = {}, set(), 0
    for info in archive.infolist():
        name = info.filename
        if name in seen:
            _refuse(report, 'duplicate-entry', f'the archive holds {name} twice')
        seen.add(name)
        if info.is_dir() or not allowed_package_path(name):
            _refuse(report, 'unsafe-entry', f'{name} is not an allowed packet path (manifest.json, preview.md, '
                    'artifacts/<name>.json, assets/audio/<name>.m4a, assets/evidence/<name>.shazamsignature)')
        total += info.file_size
        if total > MAX_PACKAGE_BYTES:
            _refuse(report, 'too-large', 'the packet unpacks to more than 100 MB')
        limits = [('manifest.json', MAX_MANIFEST_BYTES, 'manifest-too-large'),
                  ('artifacts/', MAX_ARTIFACT_BYTES, 'invalid-asset'),
                  ('assets/audio/', MAX_AUDIO_BYTES, 'audio-too-large'),
                  ('assets/evidence/', MAX_EVIDENCE_BYTES, 'invalid-asset')]
        for prefix, limit, code in limits:
            if name.startswith(prefix) and info.file_size > limit:
                _refuse(report, code, f'{name} is larger than {limit} bytes')
        if info.compress_size > 0 and info.file_size // max(1, info.compress_size) > MAX_COMPRESSION_RATIO:
            _refuse(report, 'excessive-compression', f'{name} unpacks to more than 100 times its packed size')
        try:
            entries[name] = archive.read(info)
        except (zipfile.BadZipFile, OSError, RuntimeError, NotImplementedError) as error:
            _refuse(report, 'malformed-archive', f'{name} cannot be unpacked: {error}')
    return entries


def _load_json(report, data, where, code='invalid-manifest'):
    try:
        return json.loads(data.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _refuse(report, code, f'not JSON: {error}', where)


def _check_manifest_shape(report, manifest):
    if not isinstance(manifest, dict):
        _refuse(report, 'invalid-manifest', 'the manifest root is not an object')
    declared = manifest.get('schemaVersion')
    if isinstance(declared, str) and declared != PACKAGE_SCHEMA_VERSION:
        _refuse(report, 'unsupported-schema', f'package version {declared!r} is not supported (this reader reads '
                f'{PACKAGE_SCHEMA_VERSION})')
    _unknown_keys(report, manifest, MANIFEST_KEYS, 'manifest')
    typed = {'item': dict, 'itemTransport': dict, 'artifacts': list, 'assets': list, 'redactions': dict}
    for key, kind in typed.items():
        if not isinstance(manifest.get(key), kind):
            _refuse(report, 'invalid-manifest', f'{key} is absent or has the wrong type')
    item = manifest['item']
    _unknown_keys(report, item, ITEM_KEYS, 'item')
    if isinstance(item.get('source'), dict):
        _unknown_keys(report, item['source'], SOURCE_KEYS, 'source')
    _unknown_keys(report, manifest['itemTransport'], TRANSPORT_KEYS, 'item transport')
    _unknown_keys(report, manifest['redactions'], REDACTION_KEYS, 'redactions')
    for descriptor in manifest['artifacts']:
        if not isinstance(descriptor, dict):
            _refuse(report, 'invalid-manifest', 'an artifact descriptor is not an object')
        _unknown_keys(report, descriptor, ARTIFACT_KEYS, 'artifact descriptor')
    for descriptor in manifest['assets']:
        if not isinstance(descriptor, dict):
            _refuse(report, 'invalid-manifest', 'an asset descriptor is not an object')
        _unknown_keys(report, descriptor, ASSET_KEYS, 'asset descriptor')


def _check_manifest_types(report, manifest):
    """What decoding SpokenMarginsPackageManifest needs: required fields present, with their types and enums."""
    def need(condition, message, where=''):
        if not condition:
            _refuse(report, 'invalid-manifest', message, where)

    need(isinstance(manifest.get('schemaVersion'), str), 'schemaVersion is absent')
    need(isinstance(manifest.get('packageId'), str), 'packageId is absent')
    need(isinstance(manifest.get('createdAt'), str) and bool(_ISO_DATE.fullmatch(manifest['createdAt'])),
         'createdAt is not an ISO-8601 date and time with a zone')
    need(isinstance(manifest.get('requiredCapabilities'), list)
         and all(isinstance(c, str) for c in manifest['requiredCapabilities']), 'requiredCapabilities is absent')
    need(manifest.get('suggestedRevealMode') in REVEAL_MODES | {None}, 'suggestedRevealMode is not a known mode')
    need(manifest.get('senderDisplayLabel') is None or isinstance(manifest['senderDisplayLabel'], str),
         'senderDisplayLabel is not text')
    item = manifest['item']
    need(item.get('itemType') in ITEM_TYPES, f"itemType {item.get('itemType')!r} is not known", 'item')
    need(isinstance(item.get('title'), str), 'title is absent', 'item')
    for key in ITEM_KEYS - {'itemType', 'title', 'durationMs', 'source'}:
        need(item.get(key) is None or isinstance(item[key], str), f'{key} is not text', 'item')
    need(item.get('durationMs') is None or _is_int(item['durationMs']), 'durationMs is not an integer', 'item')
    source = item.get('source')
    if source is not None:
        need(isinstance(source, dict) and source.get('sourceType') in SOURCE_TYPES
             and isinstance(source.get('canonicalURL'), str), 'source needs a known sourceType and a canonicalURL',
             'item.source')
    transport = manifest['itemTransport']
    need(transport.get('kind') in TRANSPORT_KINDS, f"itemTransport kind {transport.get('kind')!r} is not known")
    need(transport.get('rightsBasis') in RIGHTS_BASES | {None}, 'rightsBasis is not known')
    for key in REDACTION_KEYS:
        need(isinstance(manifest['redactions'].get(key), bool), f'redactions.{key} is absent')
    for descriptor in manifest['artifacts']:
        need(all(isinstance(descriptor.get(k), str) for k in ('id', 'kind', 'schemaVersion', 'path'))
             and isinstance(descriptor.get('required'), bool), 'an artifact descriptor lacks id, kind, '
             'schemaVersion, path or required')
    for descriptor in manifest['assets']:
        need(all(isinstance(descriptor.get(k), str) for k in ('id', 'role', 'path', 'mimeType', 'provenance')),
             'an asset descriptor lacks id, role, path, mimeType or provenance')
        for key in ('durationMs', 'anchorOffsetMs', 'byteCount'):
            need(descriptor.get(key) is None or _is_int(descriptor[key]), f'asset {key} is not an integer')
    for descriptor in manifest['artifacts']:
        need(descriptor.get('byteCount') is None or _is_int(descriptor['byteCount']), 'artifact byteCount is not an integer')


def _check_distinct(report, manifest):
    artifacts, assets = manifest['artifacts'], manifest['assets']
    for group in ([a['id'] for a in artifacts], [a['id'] for a in assets],
                  [a['path'] for a in artifacts], [a['path'] for a in assets]):
        if len(set(group)) != len(group):
            _refuse(report, 'invalid-manifest', 'descriptor identities are not unique')
    names = [staged_file_name(a).lower() for a in assets]
    if len(set(names)) != len(names):
        _refuse(report, 'invalid-manifest', 'asset ids would extract to the same file')


def _decode_artifacts(report, manifest, entries):
    decoded = {kind: [] for kind in ARTIFACT_VERSIONS}
    for descriptor in manifest['artifacts']:
        kind, version, where = descriptor['kind'], descriptor['schemaVersion'], descriptor['path']
        expected = ARTIFACT_VERSIONS.get(kind)
        if expected is None:
            if descriptor['required']:
                _refuse(report, 'unsupported-capability', f'required artifact kind {kind!r} is not known', where)
            report.warn('skipped-artifact', f'optional artifact kind {kind!r} is not known; readers skip it', where)
            continue
        if version != expected:
            if descriptor['required'] or kind in ALWAYS_REQUIRED_KINDS:
                _refuse(report, 'unsupported-schema', f'{kind} version {version!r} is not supported', where)
            report.warn('skipped-artifact', f'optional {kind} version {version!r} is not supported; readers skip it',
                        where)
            continue
        value = _load_json(report, entries[descriptor['path']], where)
        if not isinstance(value, dict):
            _refuse(report, 'invalid-manifest', f'{kind} root is not an object', where)
        if kind in CLOSED_ARTIFACTS:
            context, keys, list_key, entry_context, entry_keys = CLOSED_ARTIFACTS[kind]
            _unknown_keys(report, value, keys, context)
            if not isinstance(value.get(list_key), list) or not all(isinstance(e, dict) for e in value[list_key]):
                _refuse(report, 'invalid-manifest', f'{context} {list_key} are absent', where)
            for entry in value[list_key]:
                _unknown_keys(report, entry, entry_keys, entry_context)
        if value.get('id') != descriptor['id'] or value.get('schemaVersion') != version:
            _refuse(report, 'invalid-manifest', f'{kind} id or schemaVersion does not match its descriptor', where)
        decoded[kind].append((descriptor, value))
    return decoded


def _check_item(report, item):
    for key in ('canonicalURL', 'originalURL', 'enclosureURL'):
        _check_link(report, item.get(key), f'item.{key}')
    if isinstance(item.get('source'), dict):
        _check_link(report, item['source'].get('canonicalURL'), 'item.source.canonicalURL')
    title = item['title']
    if not 1 <= character_count(title) <= 500 or not title.strip():
        _refuse(report, 'invalid-manifest', 'title is empty or longer than 500 characters', 'item')
    limits = {'author': 300, 'publisher': 300, 'showTitle': 500, 'episodeGUID': 1_000, 'publishedAt': 100,
              'languageCode': 35}
    for key, maximum in limits.items():
        if not _length_ok(item.get(key), maximum):
            _refuse(report, 'invalid-manifest', f'{key} is longer than {maximum} characters', 'item')
    source = item.get('source') or {}
    if not _length_ok(source.get('title'), 500) or not _length_ok(source.get('publisher'), 300):
        _refuse(report, 'invalid-manifest', 'source title or publisher is too long', 'item.source')
    if item.get('durationMs') is not None and item['durationMs'] < 0:
        _refuse(report, 'invalid-manifest', 'durationMs is negative', 'item')
    for key in ('normalizedContentSHA256', 'exactEditionSHA256'):
        if item.get(key) is not None and not _is_sha(item[key]):
            _refuse(report, 'invalid-manifest', f'{key} is not a lowercase SHA-256', 'item')


def _check_boundary(report, manifest, decoded):
    item, transport, redactions = manifest['item'], manifest['itemTransport'], manifest['redactions']
    layers = decoded['commentary_layer']
    if not 1 <= len(manifest['packageId']) <= 200 or not manifest['artifacts'] or len(layers) != 1:
        _refuse(report, 'invalid-manifest', 'a packet needs a packageId of 1-200 characters and exactly one '
                'commentary layer')
    for capability in manifest['requiredCapabilities']:
        if capability not in SUPPORTED_REQUIRED_CAPABILITIES:
            _refuse(report, 'unsupported-capability', f'required capability {capability!r} is not supported')
    if not _is_sha(manifest.get('contentDigest')):
        _refuse(report, 'invalid-manifest', 'contentDigest is absent or not a lowercase SHA-256')
    label = manifest.get('senderDisplayLabel')
    if label is not None and character_count(label) > 120:
        _refuse(report, 'invalid-manifest', 'senderDisplayLabel is longer than 120 characters')
    false_redactions = sorted(k for k in PROVED_REDACTIONS if redactions[k] is not True)
    if false_redactions:
        _refuse(report, 'privacy-redaction', f"redactions {', '.join(false_redactions)} must be true: a packet never "
                'carries raw recordings, item audio, diagnostics, file paths or private representations')
    _check_item(report, item)
    for descriptor in manifest['artifacts']:
        if not valid_artifact_path(descriptor['path']):
            _refuse(report, 'invalid-manifest', 'artifact path is not allowed', descriptor['path'])
    for descriptor in manifest['assets']:
        where = descriptor['path']
        offset, duration = descriptor.get('anchorOffsetMs'), descriptor.get('durationMs')
        if (not valid_asset_path(where) or not descriptor['role'] or not descriptor['mimeType']
                or character_count(descriptor['provenance']) > 200
                or (duration is not None and not 0 <= duration <= 600_000)
                or (offset is not None and not -600_000 <= offset <= 600_000)
                or (descriptor['role'] == ROLE_SIGNATURE and offset is None)):
            _refuse(report, 'invalid-manifest', 'asset descriptor is out of bounds', where)

    embedded = decoded['embedded_text_item']
    kind = transport['kind']
    if kind in ('reference', 'recipient_supplied'):
        has_url = item.get('canonicalURL') is not None
        if (has_url != (kind == 'reference') or transport.get('embeddedArtifactId') is not None
                or transport.get('rightsBasis') is not None or not redactions['fullItemOmitted'] or embedded):
            _refuse(report, 'transport-inconsistent', f'{kind} transport needs '
                    + ('an https canonicalURL' if kind == 'reference' else 'no canonicalURL')
                    + ', no embedded artifact or rights basis, and fullItemOmitted true')
    else:
        if (item.get('canonicalURL') is not None or item['itemType'] == 'podcast'
                or transport.get('rightsBasis') is None or redactions['fullItemOmitted'] or len(embedded) != 1
                or embedded[0][1].get('id') != transport.get('embeddedArtifactId')):
            _refuse(report, 'transport-inconsistent', 'embedded_text transport needs one embedded_text_item named by '
                    'embeddedArtifactId, a rightsBasis, fullItemOmitted false, no canonicalURL and a non-podcast item')
        artifact = embedded[0][1]
        text = artifact.get('text')
        if not isinstance(text, str) or not text.strip():
            _refuse(report, 'transport-inconsistent', 'the embedded text is empty')
        if artifact.get('originalMediaType') != item['itemType']:
            _refuse(report, 'transport-inconsistent', f"embedded originalMediaType {artifact.get('originalMediaType')!r} "
                    f"is not the item's type {item['itemType']!r}")
        if item.get('exactEditionSHA256') != exact_edition_sha256(text):
            _refuse(report, 'edition-mismatch', "item.exactEditionSHA256 is not the SHA-256 of the embedded text: the "
                    'text is a different edition from the one the Margins were anchored to')
        normalized = normalized_content_sha256(text)
        if normalized is None:
            report.warn('not-checked', 'normalizedContentSHA256 of non-ASCII text is left to the Swift reader')
        elif item.get('normalizedContentSHA256') != normalized:
            _refuse(report, 'edition-mismatch', 'item.normalizedContentSHA256 does not match the embedded text')

    assets_by_id = {a['id']: a for a in manifest['assets']}
    _check_layer(report, layers[0][1], assets_by_id)
    for descriptor, proposal in decoded['listening_map_proposal']:
        _check_proposal(report, proposal, assets_by_id, descriptor['path'])
    for descriptor, spine in decoded['edition_fingerprint_spine']:
        guid = spine.get('episodeGUID')
        if item.get('episodeGUID') is not None and guid is not None and guid != item['episodeGUID']:
            _refuse(report, 'edition-mismatch', 'the fingerprint spine names a different episode from the item',
                    descriptor['path'])
    if len(decoded['conversation']) > 1:
        _refuse(report, 'invalid-manifest', 'more than one conversation artifact')
    scoped = {m['packageScopedId'] for m in layers[0][1]['interjections']}
    for descriptor, conversation in decoded['conversation']:
        replies = conversation['replies']
        if not 1 <= len(replies) <= MAX_MARGINS * 4:
            _refuse(report, 'invalid-manifest', 'the conversation is empty or too large', descriptor['path'])
        for reply in replies:
            if (reply.get('packageScopedId') not in scoped or not _is_sha(reply.get('parentPackageDigest'))
                    or not isinstance(reply.get('conversationId'), str) or not 1 <= len(reply['conversationId']) <= 200
                    or not isinstance(reply.get('parentPackageScopedId'), str)
                    or not 1 <= len(reply['parentPackageScopedId']) <= 200):
                _refuse(report, 'invalid-manifest', 'a reply link names no Margin in this packet or is out of bounds',
                        descriptor['path'])


INTERJECTION_KEYS = frozenset({'packageScopedId', 'createdAt', 'anchor', 'defaultRepresentationId', 'representations'})
ANCHOR_KEYS = frozenset({'anchorType', 'startChar', 'endChar', 'exactText', 'prefix', 'suffix', 'mediaTimeMs',
                         'roughPercent', 'transcriptSegmentId', 'chapterTitle', 'machineEvidenceAssetIds'})
REPRESENTATION_KEYS = frozenset({'id', 'kind', 'approvedTranscript', 'assetId', 'provenance'})


def _check_layer(report, layer, assets_by_id):
    where = 'commentary layer'
    for key in sorted(set(layer) - {'id', 'schemaVersion', 'interjections'}):
        report.warn('ignored-field', f'{key!r} is not a commentary layer field; shipped readers ignore it', where)
    interjections = layer.get('interjections')
    if not isinstance(interjections, list) or not 1 <= len(interjections) <= MAX_MARGINS:
        _refuse(report, 'invalid-manifest', f'the commentary layer needs 1-{MAX_MARGINS} Margins', where)
    scoped = [m.get('packageScopedId') if isinstance(m, dict) else None for m in interjections]
    if len(set(scoped)) != len(scoped):
        _refuse(report, 'invalid-manifest', 'package-scoped Margin ids are not unique', where)
    for index, margin in enumerate(interjections):
        at = f'{where} Margin {index + 1}'
        if not isinstance(margin, dict) or not isinstance(margin.get('anchor'), dict):
            _refuse(report, 'invalid-manifest', 'a Margin or its anchor is not an object', at)
        for key in sorted(set(margin) - INTERJECTION_KEYS):
            report.warn('ignored-field', f'{key!r} is not a Margin field; shipped readers ignore it', at)
        anchor = margin['anchor']
        for key in sorted(set(anchor) - ANCHOR_KEYS):
            report.warn('ignored-field', f'{key!r} is not an anchor field; shipped readers ignore it', at)
        representations = margin.get('representations')
        ints = [anchor.get(k) for k in ('startChar', 'endChar', 'mediaTimeMs', 'roughPercent')]
        decodes = (isinstance(margin.get('packageScopedId'), str) and isinstance(margin.get('createdAt'), str)
                   and isinstance(margin.get('defaultRepresentationId'), str) and isinstance(representations, list)
                   and anchor.get('anchorType') in ANCHOR_TYPES
                   and isinstance(anchor.get('machineEvidenceAssetIds'), list)
                   and all(v is None or _is_int(v) for v in ints))
        if not decodes:
            _refuse(report, 'invalid-manifest', 'a Margin lacks packageScopedId, createdAt, anchor (with anchorType '
                    'and machineEvidenceAssetIds), defaultRepresentationId or representations', at)
        start, end = anchor.get('startChar'), anchor.get('endChar')
        bounded = (1 <= len(margin['packageScopedId']) <= 200 and representations
                   and len({r.get('id') for r in representations if isinstance(r, dict)}) == len(representations)
                   and any(isinstance(r, dict) and r.get('id') == margin['defaultRepresentationId'] for r in representations)
                   and all(v is None or v >= 0 for v in (start, end, anchor.get('mediaTimeMs')))
                   and (start is None or end is None or end >= start)
                   and _length_ok(anchor.get('exactText'), MAX_EXACT_TEXT)
                   and _length_ok(anchor.get('prefix'), MAX_CONTEXT_PER_SIDE)
                   and _length_ok(anchor.get('suffix'), MAX_CONTEXT_PER_SIDE)
                   and (anchor.get('roughPercent') is None or 0 <= anchor['roughPercent'] <= 100)
                   and _length_ok(anchor.get('transcriptSegmentId'), 300)
                   and _length_ok(anchor.get('chapterTitle'), 500))
        if not bounded:
            _refuse(report, 'invalid-manifest', 'a Margin field is absent or out of bounds', at)
        for evidence in anchor['machineEvidenceAssetIds']:
            if (assets_by_id.get(evidence) or {}).get('role') != ROLE_SIGNATURE:
                _refuse(report, 'invalid-manifest', f'anchor evidence {evidence!r} is absent or not an acoustic signature', at)
        for representation in representations:
            for key in sorted(set(representation) - REPRESENTATION_KEYS):
                report.warn('ignored-field', f'{key!r} is not a representation field; shipped readers ignore it', at)
            transcript = representation.get('approvedTranscript')
            kind = representation.get('kind')
            if (not isinstance(representation.get('id'), str) or not 1 <= len(representation['id']) <= 200
                    or not isinstance(transcript, str) or not transcript.strip() or character_count(transcript) > 50_000
                    or representation.get('provenance') not in REPRESENTATION_PROVENANCE
                    or kind not in TEXT_REPRESENTATIONS | AUDIO_REPRESENTATIONS):
                _refuse(report, 'invalid-manifest', 'a representation is empty, out of bounds or of an unknown kind', at)
            asset_id = representation.get('assetId')
            if kind in TEXT_REPRESENTATIONS and asset_id is not None:
                _refuse(report, 'invalid-manifest', 'a text representation references audio', at)
            if kind in AUDIO_REPRESENTATIONS and not str((assets_by_id.get(asset_id) or {}).get('path', '')).startswith('assets/audio/'):
                _refuse(report, 'invalid-manifest', 'an audio representation names no voice asset', at)


def _check_proposal(report, proposal, assets_by_id, where):
    scenes = proposal.get('scenes')
    if (not isinstance(scenes, list) or not scenes or not isinstance(proposal.get('generator'), str)
            or len(proposal['generator']) > 200 or len({s.get('id') for s in scenes}) != len(scenes)
            or [s.get('order') for s in scenes] != list(range(len(scenes)))):
        _refuse(report, 'invalid-manifest', 'Listening Map proposal order is invalid', where)
    for scene in scenes:
        summary = scene.get('summaryAssetId')
        if summary is not None and (assets_by_id.get(summary) or {}).get('role') != ROLE_SUMMARY_VOICE:
            _refuse(report, 'invalid-manifest', 'scene summary asset is absent or has the wrong role', where)


def _check_asset_bytes(report, manifest, entries):
    for descriptor in manifest['assets']:
        data, where = entries[descriptor['path']], descriptor['path']
        if where.startswith('assets/audio/'):
            # The Swift reader opens it with AudioToolbox (M4A or MPEG-4, 0-10 minutes); without it, it checks
            # for an `ftyp` box, as this does.
            if len(data) < 12 or data[4:8] != b'ftyp':
                _refuse(report, 'invalid-asset', 'the voice asset is not an MPEG-4 audio file', where)
        elif descriptor['role'] != ROLE_SIGNATURE or descriptor['mimeType'] != SIGNATURE_MIME_TYPE or not data:
            _refuse(report, 'invalid-asset', 'evidence must be a non-empty acoustic_signature of type '
                    f'{SIGNATURE_MIME_TYPE}', where)


def read_packet(path_or_bytes, label=None):
    """Check a .spokenmargins packet the way the shipped reader does. Never raises for a bad packet."""
    data = path_or_bytes if isinstance(path_or_bytes, (bytes, bytearray)) else Path(path_or_bytes).read_bytes()
    report = Report(label or (str(path_or_bytes) if not isinstance(path_or_bytes, (bytes, bytearray)) else '<bytes>'),
                    'packet')
    try:
        try:
            archive = zipfile.ZipFile(io.BytesIO(data))
        except zipfile.BadZipFile:
            _refuse(report, 'malformed-archive', 'this is not a zip archive')
        with archive:
            entries = _check_zip(report, archive, len(data))
        if 'manifest.json' not in entries:
            _refuse(report, 'manifest-missing', 'the packet has no manifest.json')
        manifest = _load_json(report, entries['manifest.json'], 'manifest.json')
        _check_manifest_shape(report, manifest)
        _check_manifest_types(report, manifest)
        _check_distinct(report, manifest)
        declared = {'manifest.json', 'preview.md'} | {d['path'] for d in manifest['artifacts'] + manifest['assets']}
        if declared != set(entries):
            missing, extra = sorted(declared - set(entries)), sorted(set(entries) - declared)
            _refuse(report, 'entries-mismatch', f'declared entries do not match the archive (missing {missing}, '
                    f'undeclared {extra})')
        for descriptor in manifest['artifacts'] + manifest['assets']:
            body = entries[descriptor['path']]
            if descriptor.get('byteCount') != len(body) or descriptor.get('sha256') != hashlib.sha256(body).hexdigest():
                _refuse(report, 'digest-mismatch', 'the file does not match its byteCount or sha256: it changed after '
                        'export', descriptor['path'])
        decoded = _decode_artifacts(report, manifest, entries)
        _check_boundary(report, manifest, decoded)
        files = {d['path']: entries[d['path']] for d in manifest['artifacts'] + manifest['assets']}
        if manifest['contentDigest'] != content_digest(manifest, entries['preview.md'], files):
            _refuse(report, 'digest-mismatch', 'contentDigest does not match the packet: it changed after export')
        layer = decoded['commentary_layer'][0][1]
        embedded = decoded['embedded_text_item']
        expected_preview = preview_markdown(
            manifest, layer['interjections'], proposals=len(decoded['listening_map_proposal']),
            spines=len(decoded['edition_fingerprint_spine']), sketches=len(decoded['transcript_phrase_sketch']),
            embedded_text=embedded[0][1].get('text') if embedded else None).encode('utf-8')
        if entries['preview.md'] != expected_preview:
            _refuse(report, 'preview-mismatch', 'preview.md does not match the packet')
        _check_asset_bytes(report, manifest, entries)
        report.summary = summarize(manifest, decoded)
    except Refused:
        pass
    return report


def summarize(manifest, decoded):
    layer = decoded['commentary_layer'][0][1]
    margins = []
    for margin in layer['interjections']:
        anchor = margin['anchor']
        default = next(r for r in margin['representations'] if r['id'] == margin['defaultRepresentationId'])
        margins.append({key: value for key, value in {
            'id': margin['packageScopedId'], 'anchorType': anchor['anchorType'],
            'mediaTimeMs': anchor.get('mediaTimeMs'), 'exactText': anchor.get('exactText'),
            'kind': default['kind'], 'text': default['approvedTranscript']}.items() if value is not None})
    return {
        'packageId': manifest['packageId'], 'createdAt': manifest['createdAt'], 'digest': manifest['contentDigest'],
        'sender': manifest.get('senderDisplayLabel'), 'item': manifest['item'],
        'transport': manifest['itemTransport']['kind'],
        'artifacts': sorted(d['kind'] for d in manifest['artifacts']), 'assets': len(manifest['assets']),
        'margins': margins,
    }


# --- writing (examples and tests) -----------------------------------------------------------------------------

def write_packet(manifest, artifacts, assets=None, preview=None, extra_entries=None):
    """Bytes of a packet: fills each descriptor's byteCount and sha256, the preview and the digest, and zips the
    entries in the order the Swift writer uses with a fixed date, so the same input gives the same bytes.

    `artifacts` and `assets` map packet paths to bytes. A test that wants a broken packet passes its own
    `preview`, edits the manifest afterwards via `extra_entries`, or edits the bytes."""
    assets = assets or {}
    manifest = json.loads(json.dumps(manifest))
    for descriptor in manifest['artifacts']:
        body = artifacts[descriptor['path']]
        descriptor['byteCount'], descriptor['sha256'] = len(body), hashlib.sha256(body).hexdigest()
    for descriptor in manifest['assets']:
        body = assets[descriptor['path']]
        descriptor['byteCount'], descriptor['sha256'] = len(body), hashlib.sha256(body).hexdigest()
    if preview is None:
        layer = next(json.loads(artifacts[d['path']]) for d in manifest['artifacts'] if d['kind'] == 'commentary_layer')
        embedded = next((json.loads(artifacts[d['path']]) for d in manifest['artifacts']
                         if d['kind'] == 'embedded_text_item'), None)
        known = [d for d in manifest['artifacts'] if ARTIFACT_VERSIONS.get(d['kind']) == d['schemaVersion']]
        preview = preview_markdown(
            manifest, layer['interjections'],
            proposals=sum(d['kind'] == 'listening_map_proposal' for d in known),
            spines=sum(d['kind'] == 'edition_fingerprint_spine' for d in known),
            sketches=sum(d['kind'] == 'transcript_phrase_sketch' for d in known),
            embedded_text=embedded.get('text') if embedded else None).encode('utf-8')
    manifest['contentDigest'] = content_digest(manifest, preview, {**artifacts, **assets})
    entries = [('manifest.json', encode_manifest(manifest)), ('preview.md', preview)]
    entries += sorted(artifacts.items()) + sorted(assets.items()) + list((extra_entries or {}).items())
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        for name, body in entries:
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, body)
    return buffer.getvalue()


def unpack(data):
    """(manifest, artifacts, assets) of a packet's bytes, for building variants of it."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        artifacts = {d['path']: archive.read(d['path']) for d in manifest['artifacts']}
        assets = {d['path']: archive.read(d['path']) for d in manifest['assets']}
    return manifest, artifacts, assets


# --- JSON documents -------------------------------------------------------------------------------------------

def schema_versions(schemas=SCHEMAS):
    """{schemaVersion constant: schema file} for every schema whose `schemaVersion` is a constant."""
    found = {}
    for path in sorted(Path(schemas).glob('*.schema.json')):
        schema = json.loads(path.read_text(encoding='utf-8'))
        constant = ((schema.get('properties') or {}).get('schemaVersion') or {}).get('const')
        if isinstance(constant, str):
            found[constant] = path
    return found


def validate_document(path, schema_name=None, schemas=SCHEMAS):
    report = Report(str(path), 'json')
    try:
        document = json.loads(Path(path).read_text(encoding='utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        report.error('not-json', str(error))
        return report
    if schema_name:
        schema_path = Path(schemas) / schema_name
    else:
        version = document.get('schemaVersion') if isinstance(document, dict) else None
        schema_path = schema_versions(schemas).get(version)
        if schema_path is None:
            report.error('unknown-format', f'schemaVersion {version!r} names no schema in {schemas}; pass --schema')
            return report
    report.kind = schema_path.name
    try:
        from jsonschema import Draft202012Validator, FormatChecker
    except ImportError:
        report.error('needs-jsonschema', 'checking JSON documents needs the jsonschema package')
        return report
    validator = Draft202012Validator(json.loads(schema_path.read_text(encoding='utf-8')), format_checker=FormatChecker())
    for error in sorted(validator.iter_errors(document), key=lambda e: list(e.absolute_path)):
        report.error('schema', error.message, '/'.join(map(str, error.absolute_path)) or '<root>')
    return report


def check(path, schema_name=None):
    path = Path(path)
    if path.suffix == f'.{FILE_EXTENSION}':
        return read_packet(path)
    return validate_document(path, schema_name)


# --- the example corpus -----------------------------------------------------------------------------------------

EXAMPLES = CONTRACTS / 'examples' / 'packets'


def corpus(sources=EXAMPLES):
    """{file name: bytes} of the variant packets, built from the two Swift-written examples. Each variant is one
    reader rule; Contracts/examples/packets/expectations.json says what the shipped reader does with each."""
    article = unpack((Path(sources) / 'article-reference.spokenmargins').read_bytes())
    podcast = unpack((Path(sources) / 'podcast-reference.spokenmargins').read_bytes())

    def copy(packet):
        return json.loads(json.dumps(packet[0])), dict(packet[1]), dict(packet[2])

    out = {}

    manifest, artifacts, assets = copy(article)
    text = ('This short note was written for the Spoken Margins format examples. It carries no outside content. '
            'Listening is a kind of reading, and the margin is where the reader talks back.')
    embedded = {'id': 'embedded-item', 'originalMediaType': 'text', 'schemaVersion': EMBEDDED_TEXT_ITEM_VERSION,
                'text': text}
    manifest['item'] = {'itemType': 'text', 'title': 'A short note written for this example', 'languageCode': 'en',
                        'exactEditionSHA256': exact_edition_sha256(text),
                        'normalizedContentSHA256': normalized_content_sha256(text)}
    manifest['itemTransport'] = {'kind': 'embedded_text', 'embeddedArtifactId': 'embedded-item',
                                 'rightsBasis': 'app_authored'}
    manifest['redactions']['fullItemOmitted'] = False
    manifest['requiredCapabilities'] = [COMMENTARY_LAYER_VERSION, EMBEDDED_TEXT_ITEM_VERSION]
    manifest['artifacts'].append({'id': 'embedded-item', 'kind': 'embedded_text_item', 'path': 'artifacts/embedded-item.json',
                                  'required': True, 'schemaVersion': EMBEDDED_TEXT_ITEM_VERSION})
    artifacts['artifacts/embedded-item.json'] = encode_manifest(embedded)
    out['article-embedded-text.spokenmargins'] = write_packet(manifest, artifacts, assets)
    manifest['item']['exactEditionSHA256'] = exact_edition_sha256(text + ' A later edition adds this sentence.')
    out['invalid-edition-mismatch.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(article)
    manifest['futureField'] = True
    out['invalid-unknown-manifest-field.spokenmargins'] = write_packet(manifest, artifacts, assets)

    for required in (False, True):
        manifest, artifacts, assets = copy(podcast)
        manifest['artifacts'].append({'id': 'future', 'kind': 'future_thing', 'path': 'artifacts/future.json',
                                      'required': required, 'schemaVersion': 'spoken-margins.future-thing.v1'})
        artifacts['artifacts/future.json'] = b'{"id":"future","note":"a kind no reader knows yet"}'
        name = 'invalid-unknown-required-artifact' if required else 'unknown-optional-artifact'
        out[f'{name}.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(podcast)
    manifest['requiredCapabilities'].append('spoken-margins.future-thing.v1')
    out['invalid-unknown-required-capability.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(podcast)
    manifest['schemaVersion'] = 'spoken-margins.package.v2'
    out['invalid-future-package-version.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(podcast)
    layer_path = next(d['path'] for d in manifest['artifacts'] if d['kind'] == 'commentary_layer')
    layer = json.loads(artifacts[layer_path])
    layer['interjections'][0]['futureNote'] = 'a field this build does not know'
    layer['interjections'][0]['anchor']['futureAnchorHint'] = 7
    artifacts[layer_path] = encode_manifest(layer)
    out['unknown-commentary-fields.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(podcast)
    manifest['assets'].append({'id': 'asset-broken', 'mimeType': 'audio/mp4', 'path': 'assets/audio/broken.m4a',
                               'provenance': 'sender_approved_original', 'role': 'original_voice', 'durationMs': 1000})
    assets['assets/audio/broken.m4a'] = b'this is not audio, only text with an m4a name'
    out['invalid-malformed-voice-asset.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(podcast)
    packet = write_packet(manifest, artifacts, assets)
    manifest, artifacts, assets = unpack(packet)
    layer = json.loads(artifacts[layer_path])
    layer['interjections'][0]['representations'][0]['approvedTranscript'] = 'Words the sender never approved.'
    with zipfile.ZipFile(io.BytesIO(packet)) as archive:
        preview = archive.read('preview.md')
    tampered = dict(artifacts)
    tampered[layer_path] = encode_manifest(layer)
    out['invalid-tampered-margin.spokenmargins'] = _rezip(manifest, preview, tampered, assets)

    manifest, artifacts, assets = copy(podcast)
    out['invalid-unsafe-entry.spokenmargins'] = write_packet(manifest, artifacts, assets,
                                                             extra_entries={'../outside.json': b'{}'})

    manifest, artifacts, assets = copy(podcast)
    manifest['item']['enclosureURL'] = 'http://example.com/podcast/episode-1.mp3'
    out['invalid-insecure-link.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(podcast)
    manifest['item']['enclosureURL'] = 'https://example.com/podcast/episode-1.mp3?token=0000example0000'
    out['private-link.spokenmargins'] = write_packet(manifest, artifacts, assets)

    manifest, artifacts, assets = copy(podcast)
    manifest['redactions']['rawAudioOmitted'] = False
    out['invalid-redaction-disabled.spokenmargins'] = write_packet(manifest, artifacts, assets)
    return out


def _rezip(manifest, preview, artifacts, assets):
    """Zip a manifest as it is, without recomputing anything: a packet edited after export."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        for name, body in [('manifest.json', encode_manifest(manifest)), ('preview.md', preview)] + \
                sorted(artifacts.items()) + sorted(assets.items()):
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, body)
    return buffer.getvalue()


# --- command line -------------------------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    check_parser = commands.add_parser('check', help='validate packets and portable JSON documents')
    check_parser.add_argument('files', nargs='+', type=Path)
    check_parser.add_argument('--strict', action='store_true', help='fail on warnings too')
    check_parser.add_argument('--json', action='store_true', help='print findings as JSON')
    check_parser.add_argument('--schema', help='schema file name in Contracts/schemas for JSON documents')
    inspect_parser = commands.add_parser('inspect', help="print a packet's summary as JSON")
    inspect_parser.add_argument('packet', type=Path)
    corpus_parser = commands.add_parser('corpus', help='write the example variant packets')
    corpus_parser.add_argument('out', type=Path)
    args = parser.parse_args(argv)

    if args.command == 'corpus':
        args.out.mkdir(parents=True, exist_ok=True)
        for name, body in sorted(corpus().items()):
            (args.out / name).write_bytes(body)
            print(args.out / name)
        return 0
    if args.command == 'inspect':
        report = read_packet(args.packet)
        print(json.dumps(report.as_dict(), indent=2, ensure_ascii=False))
        return 0 if report.ok() else 1
    reports = []
    for path in args.files:
        if not path.is_file():
            print(f'{path}: no such file', file=sys.stderr)
            return 2
        reports.append(check(path, args.schema))
    if args.json:
        print(json.dumps([r.as_dict() for r in reports], indent=2, ensure_ascii=False))
    else:
        for report in reports:
            for finding in report.findings:
                print(finding.line(report.path))
            if report.ok(args.strict):
                print(f'{report.path}: valid {report.kind}')
    return 0 if all(r.ok(args.strict) for r in reports) else 1


if __name__ == '__main__':
    raise SystemExit(main())
