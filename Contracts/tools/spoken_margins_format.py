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
authority. This one covers the container, the manifest, the descriptors, the digest, the preview, the
commentary layer and the Listening Map scene rules; it does not decode audio (see Contracts/README.md,
"What the reference reader does not check").
"""
from __future__ import annotations

import argparse
import base64
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
import zlib

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
SCENE_ELIGIBILITY = frozenset({'eligible', 'excluded', 'unknown'})
SUMMARY_PROVENANCE = frozenset({'publisher_supplied', 'sender_authored', 'deterministic', 'model_generated'})
FINGERPRINT_TRIGGERS = frozenset({'initial_playback', 'periodic_playback', 'pre_interjection',
                                  'post_interjection_resume', 'stable_post_seek', 'downloaded_preparation'})
FINGERPRINT_PROVENANCE = frozenset({'observed_decoded_playback', 'source_window_reference',
                                    'downloaded_source_reference'})

# The stored properties of every Swift Codable type a shipped reader decodes, each with the type Swift gives it
# (`T?` is optional, `[T]` a list). The synthesized Codable decoder needs each non-optional key present with
# that type, so decode_problem() reads this table and nothing else: a field that the table gets wrong, or leaves
# out, is checked wrongly everywhere. scripts/validate-contracts.py compares the table, name for name and type for
# type, with the Swift structs in the app and in Build 29's frozen copy, so it cannot drift unseen.
# (A type `T` nested in a struct `S` is `S.T` here and in SWIFT_ENUMS, and `S`'s own properties spell it `T`.)
SWIFT_TYPES = {
    'SpokenMarginsPackageManifest': {
        'schemaVersion': 'String', 'packageId': 'String', 'createdAt': 'Date', 'contentDigest': 'String?',
        'item': 'SharedItemIdentity', 'itemTransport': 'SharedItemTransport', 'senderDisplayLabel': 'String?',
        'suggestedRevealMode': 'ImportedCommentaryRevealMode?', 'requiredCapabilities': '[String]',
        'artifacts': '[SpokenMarginsArtifactDescriptor]', 'assets': '[SpokenMarginsAssetDescriptor]',
        'redactions': 'InterjectionPackageRedactions'},
    'SharedItemIdentity': {
        'itemType': 'SharedItemType', 'canonicalURL': 'String?', 'originalURL': 'String?', 'title': 'String',
        'author': 'String?', 'publisher': 'String?', 'showTitle': 'String?', 'episodeGUID': 'String?',
        'enclosureURL': 'String?', 'publishedAt': 'String?', 'durationMs': 'Int?',
        'normalizedContentSHA256': 'String?', 'exactEditionSHA256': 'String?', 'languageCode': 'String?',
        'source': 'SharedSourceIdentity?'},
    'SharedSourceIdentity': {
        'sourceType': 'SourceType', 'canonicalURL': 'String', 'title': 'String?', 'publisher': 'String?'},
    'SharedItemTransport': {
        'kind': 'SharedItemTransportKind', 'embeddedArtifactId': 'String?', 'rightsBasis': 'SharedItemRightsBasis?'},
    'InterjectionPackageRedactions': {
        'rawAudioOmitted': 'Bool', 'rawTranscriptOmitted': 'Bool', 'fullItemOmitted': 'Bool',
        'itemAudioOmitted': 'Bool', 'diagnosticsOmitted': 'Bool', 'filesystemPathsOmitted': 'Bool',
        'unrelatedTurnsOmitted': 'Bool', 'privateRepresentationsOmitted': 'Bool'},
    'SpokenMarginsArtifactDescriptor': {
        'id': 'String', 'kind': 'String', 'schemaVersion': 'String', 'path': 'String', 'required': 'Bool',
        'byteCount': 'Int?', 'sha256': 'String?'},
    'SpokenMarginsAssetDescriptor': {
        'id': 'String', 'role': 'String', 'path': 'String', 'mimeType': 'String', 'durationMs': 'Int?',
        'anchorOffsetMs': 'Int?', 'provenance': 'String', 'byteCount': 'Int?', 'sha256': 'String?'},
    'SharedCommentaryLayerArtifact': {
        'id': 'String', 'schemaVersion': 'String', 'interjections': '[SharedInterjectionPackageRecord]'},
    'SharedInterjectionPackageRecord': {
        'packageScopedId': 'String', 'createdAt': 'Date', 'anchor': 'PortableAnchorEvidence',
        'defaultRepresentationId': 'String', 'representations': '[SharedInterjectionRepresentation]'},
    'SharedInterjectionRepresentation': {
        'id': 'String', 'kind': 'SharedInterjectionRepresentationKind', 'approvedTranscript': 'String',
        'assetId': 'String?', 'provenance': 'SharedInterjectionProvenance'},
    'PortableAnchorEvidence': {
        'anchorType': 'AnchorType', 'startChar': 'Int?', 'endChar': 'Int?', 'exactText': 'String?',
        'prefix': 'String?', 'suffix': 'String?', 'mediaTimeMs': 'Int?', 'roughPercent': 'Int?',
        'transcriptSegmentId': 'String?', 'chapterTitle': 'String?', 'machineEvidenceAssetIds': '[String]'},
    'PortableListeningMapProposalArtifact': {
        'id': 'String', 'schemaVersion': 'String', 'languageCode': 'String?', 'createdAt': 'Date',
        'generator': 'String', 'scenes': '[PortableListeningMapScene]'},
    'PortableListeningMapScene': {
        'id': 'String', 'order': 'Int', 'title': 'String?', 'summaryText': 'String?', 'summaryAssetId': 'String?',
        'summaryProvenance': 'PortableSummaryProvenance?', 'eligibility': 'PortableSceneEligibility',
        'eligibilityReason': 'String?', 'startAnchor': 'PortableAnchorEvidence', 'endAnchor': 'PortableAnchorEvidence'},
    'EditionFingerprintSpineArtifact': {
        'id': 'String', 'schemaVersion': 'String', 'itemId': 'String', 'canonicalURL': 'String?',
        'episodeGUID': 'String?', 'producingEditionDurationMs': 'Int?', 'producingEditionSHA256': 'String?',
        'createdAt': 'Date', 'generatorVersion': 'String', 'landmarks': '[EpisodeFingerprintLandmark]'},
    'EpisodeFingerprintLandmark': {
        'id': 'String', 'order': 'Int', 'sourceMediaStartMs': 'Int', 'sourceMediaEndMs': 'Int',
        'anchorMediaTimeMs': 'Int', 'continuityEpoch': 'Int', 'trigger': 'EpisodeFingerprintTrigger',
        'provenance': 'EpisodeFingerprintProvenance', 'signatureAssetId': 'String',
        'transcriptSketchWindowId': 'String?', 'generatorVersion': 'String'},
    'TranscriptPhraseSketchArtifact': {
        'id': 'String', 'schemaVersion': 'String', 'itemId': 'String', 'languageCode': 'String?',
        'saltBase64': 'String', 'normalizationVersion': 'String', 'shingleWidth': 'Int',
        'maximumHashesPerWindow': 'Int', 'createdAt': 'Date', 'windows': '[TranscriptPhraseSketchWindow]'},
    'TranscriptPhraseSketchWindow': {
        'id': 'String', 'sourceStartMs': 'Int', 'sourceEndMs': 'Int', 'hashes': '[String]'},
    'MarginConversationArtifact': {
        'id': 'String', 'schemaVersion': 'String', 'replies': '[Reply]'},
    'MarginConversationArtifact.Reply': {
        'packageScopedId': 'String', 'conversationId': 'String', 'parentPackageDigest': 'String',
        'parentPackageScopedId': 'String'},
    'EmbeddedTextItemArtifact': {
        'id': 'String', 'schemaVersion': 'String', 'originalMediaType': 'String', 'text': 'String'},
}
# The raw values of the enums those types use.
SWIFT_ENUMS = {
    'SharedItemType': ITEM_TYPES,
    'SharedSourceIdentity.SourceType': SOURCE_TYPES,
    'SharedItemTransportKind': TRANSPORT_KINDS,
    'SharedItemRightsBasis': RIGHTS_BASES,
    'ImportedCommentaryRevealMode': REVEAL_MODES,
    'AnchorType': ANCHOR_TYPES,
    'SharedInterjectionRepresentationKind': TEXT_REPRESENTATIONS | AUDIO_REPRESENTATIONS,
    'SharedInterjectionProvenance': REPRESENTATION_PROVENANCE,
    'PortableSceneEligibility': SCENE_ELIGIBILITY,
    'PortableSummaryProvenance': SUMMARY_PROVENANCE,
    'EpisodeFingerprintTrigger': FINGERPRINT_TRIGGERS,
    'EpisodeFingerprintProvenance': FINGERPRINT_PROVENANCE,
}
# The artifact each kind decodes as.
KIND_SWIFT_TYPE = {
    'commentary_layer': 'SharedCommentaryLayerArtifact',
    'listening_map_proposal': 'PortableListeningMapProposalArtifact',
    'edition_fingerprint_spine': 'EditionFingerprintSpineArtifact',
    'transcript_phrase_sketch': 'TranscriptPhraseSketchArtifact',
    'embedded_text_item': 'EmbeddedTextItemArtifact',
    'conversation': 'MarginConversationArtifact',
}

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
# ISO8601DateFormatter's internet date-time, with or without fractional seconds.
_ISO_DATE = re.compile(r'([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-]([0-9]{2}):?([0-9]{2}))')


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
    if not isinstance(value, str) or any(_is_swift_space(c) for c in value) or '<' in value or '>' in value:
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


# CharacterSet.whitespacesAndNewlines: category Z*, tab, U+000A-U+000D and U+0085. (str.isspace() also counts
# U+001C-U+001F, which Swift does not.)
def _is_swift_space(char):
    return char in '\t\n\v\f\r\x85' or unicodedata.category(char)[0] == 'Z'


def _canon(text):
    """Swift compares and hashes Strings by canonical equivalence, so `caf\u00e9` and `cafe\u0301` are one id."""
    return unicodedata.normalize('NFC', text)


class _ById(dict):
    """A dictionary keyed by id the way a Swift [String: T] is: by canonical equivalence."""

    def __init__(self, items):
        super().__init__((_canon(k), v) for k, v in items)

    def get(self, key, default=None):
        return super().get(_canon(key), default) if isinstance(key, str) else default


def swift_strip(text):
    """trimmingCharacters(in: .whitespacesAndNewlines)."""
    start, end = 0, len(text)
    while start < end and _is_swift_space(text[start]):
        start += 1
    while end > start and _is_swift_space(text[end - 1]):
        end -= 1
    return text[start:end]


def swift_split(text):
    """components(separatedBy: .whitespacesAndNewlines) without the empty parts."""
    parts, current = [], []
    for char in text:
        if _is_swift_space(char):
            if current:
                parts.append(''.join(current))
            current = []
        else:
            current.append(char)
    if current:
        parts.append(''.join(current))
    return parts


# Extended grapheme clusters (UAX #29), which are Swift's Character and so what String.count counts. Python has no
# grapheme segmenter, so this carries the rules (GB3-GB13) with the property ranges that matter in practice.
_PICTOGRAPHIC = ((0xA9, 0xA9), (0xAE, 0xAE), (0x203C, 0x203C), (0x2049, 0x2049), (0x2122, 0x2122), (0x2139, 0x2139),
                 (0x2194, 0x2199), (0x21A9, 0x21AA), (0x231A, 0x231B), (0x2328, 0x2328), (0x2388, 0x2388),
                 (0x23CF, 0x23CF), (0x23E9, 0x23F3), (0x23F8, 0x23FA), (0x24C2, 0x24C2), (0x25AA, 0x25AB),
                 (0x25B6, 0x25B6), (0x25C0, 0x25C0), (0x25FB, 0x25FE), (0x2600, 0x2605), (0x2607, 0x2612),
                 (0x2614, 0x2685), (0x2690, 0x2705), (0x2708, 0x2712), (0x2714, 0x2714), (0x2716, 0x2716),
                 (0x271D, 0x271D), (0x2721, 0x2721), (0x2728, 0x2728), (0x2733, 0x2734), (0x2744, 0x2744),
                 (0x2747, 0x2747), (0x274C, 0x274C), (0x274E, 0x274E), (0x2753, 0x2755), (0x2757, 0x2757),
                 (0x2763, 0x2767), (0x2795, 0x2797), (0x27A1, 0x27A1), (0x27B0, 0x27B0), (0x27BF, 0x27BF),
                 (0x2934, 0x2935), (0x2B05, 0x2B07), (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55),
                 (0x3030, 0x3030), (0x303D, 0x303D), (0x3297, 0x3297), (0x3299, 0x3299), (0x1F000, 0x1F0FF),
                 (0x1F10D, 0x1F10F), (0x1F12F, 0x1F12F), (0x1F16C, 0x1F171), (0x1F17E, 0x1F17F), (0x1F18E, 0x1F18E),
                 (0x1F191, 0x1F19A), (0x1F1AD, 0x1F1E5), (0x1F201, 0x1F20F), (0x1F21A, 0x1F21A), (0x1F22F, 0x1F22F),
                 (0x1F232, 0x1F23A), (0x1F23C, 0x1F23F), (0x1F249, 0x1F3FA), (0x1F400, 0x1F53D), (0x1F546, 0x1F64F),
                 (0x1F680, 0x1F6FF), (0x1F774, 0x1F77F), (0x1F7D5, 0x1F7FF), (0x1F80C, 0x1F80F), (0x1F848, 0x1F84F),
                 (0x1F85A, 0x1F85F), (0x1F888, 0x1F88F), (0x1F8AE, 0x1F8FF), (0x1F90C, 0x1F93A), (0x1F93C, 0x1F945),
                 (0x1F947, 0x1FAFF), (0x1FC00, 0x1FFFD))
# GB9c (Unicode 15.1): a conjunct such as the Devanagari स्त stays one Character.
_INCB_LINKERS = frozenset([0x94D, 0x9CD, 0xACD, 0xB4D, 0xC4D, 0xD4D])
_INCB_CONSONANTS = ((0x915, 0x939), (0x958, 0x95F), (0x978, 0x97F), (0x995, 0x9A8), (0x9AA, 0x9B0), (0x9B2, 0x9B2),
                    (0x9B6, 0x9B9), (0x9DC, 0x9DF), (0x9F0, 0x9F1), (0xA95, 0xAA8), (0xAAA, 0xAB0), (0xAB2, 0xAB3),
                    (0xAB5, 0xAB9), (0xAF9, 0xAF9), (0xB15, 0xB28), (0xB2A, 0xB30), (0xB32, 0xB33), (0xB35, 0xB39),
                    (0xB5C, 0xB5D), (0xB5F, 0xB5F), (0xB71, 0xB71), (0xC15, 0xC28), (0xC2A, 0xC39), (0xC58, 0xC5A),
                    (0xD15, 0xD3A))
_PREPEND = frozenset([*range(0x600, 0x606), 0x6DD, 0x70F, 0x890, 0x891, 0x8E2, 0xD4E, 0x110BD, 0x110CD])
_ZWJ = 0x200D


def _grapheme_class(char):
    code = ord(char)
    if char == '\r':
        return 'CR'
    if char == '\n':
        return 'LF'
    if code == _ZWJ:
        return 'ZWJ'
    if 0x1F1E6 <= code <= 0x1F1FF:
        return 'RI'
    if code in _PREPEND:
        return 'Prepend'
    if code in _INCB_LINKERS:
        return 'Linker'
    if any(low <= code <= high for low, high in _INCB_CONSONANTS):
        return 'Consonant'
    category = unicodedata.category(char)
    if code in (0xFF9E, 0xFF9F) or code == 0x200C or category in ('Mn', 'Me', 'Mc') or 0x1F3FB <= code <= 0x1F3FF or 0xE0020 <= code <= 0xE007F \
            or code in (0xE33, 0xEB3):
        return 'Extend'
    if category in ('Cc', 'Zl', 'Zp', 'Cf'):
        return 'Control'
    if 0x1100 <= code <= 0x115F or 0xA960 <= code <= 0xA97C:
        return 'L'
    if 0x1160 <= code <= 0x11A7 or 0xD7B0 <= code <= 0xD7C6:
        return 'V'
    if 0x11A8 <= code <= 0x11FF or 0xD7CB <= code <= 0xD7FB:
        return 'T'
    if 0xAC00 <= code <= 0xD7A3:
        return 'LV' if (code - 0xAC00) % 28 == 0 else 'LVT'
    if any(low <= code <= high for low, high in _PICTOGRAPHIC):
        return 'Pict'
    return 'Other'


def graphemes(text):
    """The text split into Characters."""
    clusters, current, previous, regional, pictographic, conjunct = [], '', None, 0, False, 0
    for char in text:
        kind = _grapheme_class(char)
        if previous is None:
            joins = False
        elif previous == 'CR' and kind == 'LF':
            joins = True
        elif previous in ('CR', 'LF', 'Control') or kind in ('CR', 'LF', 'Control'):
            joins = False
        elif previous == 'L' and kind in ('L', 'V', 'LV', 'LVT'):
            joins = True
        elif previous in ('LV', 'V') and kind in ('V', 'T'):
            joins = True
        elif previous in ('LVT', 'T') and kind == 'T':
            joins = True
        elif kind in ('Extend', 'ZWJ', 'Linker'):
            joins = True
        elif kind == 'Consonant' and conjunct == 2:
            joins = True
        elif previous == 'Prepend':
            joins = True
        elif previous == 'ZWJ' and kind == 'Pict' and pictographic:
            joins = True
        elif previous == 'RI' and kind == 'RI':
            joins = regional % 2 == 1
        else:
            joins = False
        if not joins:
            clusters.append(current)
            current, regional, pictographic = '', 0, False
            conjunct = 1 if kind == 'Consonant' else 0
        current += char
        if kind == 'Consonant':
            conjunct = 1
        elif kind == 'Linker' and conjunct:
            conjunct = 2
        elif kind not in ('Extend', 'ZWJ'):
            conjunct = 0
        if kind == 'RI':
            regional += 1
        if kind == 'Pict':
            pictographic = True
        elif kind == 'ZWJ':
            pictographic = pictographic and previous != 'ZWJ'     # ExtPict Extend* ZWJ, one joiner
        elif kind != 'Extend':
            pictographic = False
        previous = kind
    clusters.append(current)
    return [c for c in clusters if c]


def character_count(text):
    """Swift's String.count."""
    return len(graphemes(text))


def preview_markdown(manifest, interjections, proposals=0, spines=0, sketches=0, embedded_text=None):
    """SpokenMarginsPackageArchive.previewMarkdown, which the reader compares byte for byte."""
    sender = ' '.join(swift_split(manifest.get('senderDisplayLabel') or ''))
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

def _path_char(char):
    """CharacterSet.alphanumerics (any letter, mark or number, in any script) or one of ._-"""
    return char in '._-' or unicodedata.category(char)[0] in 'LMN'


def _valid_nested_path(path, prefix, extensions):
    if not path.startswith(prefix) or '..' in path or '\\' in path or '//' in path:
        return False
    component = path[len(prefix):]
    if not component or '/' in component or not all(_path_char(c) for c in component):
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
    return ''.join(c if _path_char(c) else '-' for c in str(descriptor.get('id', ''))) + suffix


# --- the packet check ---------------------------------------------------------------------------------------

def _is_sha(value):
    return isinstance(value, str) and bool(_SHA256.fullmatch(value))


def _is_int(value):
    """A JSON integer Swift's Int (64 bits) decodes."""
    return isinstance(value, int) and not isinstance(value, bool) and -2 ** 63 <= value < 2 ** 63


def _is_date(value):
    """A string the packet decoder turns into a Date: ISO 8601 with a zone, with or without fractional seconds."""
    match = _ISO_DATE.fullmatch(value) if isinstance(value, str) else None
    if not match:
        return False
    year, month, day, hour, minute, second = (int(g) for g in match.groups()[:6])
    zone_hours, zone_minutes = int(match.group(9) or 0), int(match.group(10) or 0)
    try:
        datetime(year, month, day, hour, minute, second)
    except ValueError:
        return False
    return zone_hours < 24 and zone_minutes < 60


def _swift_type(name, owner):
    """The key of a type named in `owner`'s properties: nested in the owner, or at the top."""
    for candidate in (f'{owner}.{name}' if owner else None, name):
        if candidate in SWIFT_TYPES or candidate in SWIFT_ENUMS:
            return candidate
    return name


def decode_problem(value, swift_type, owner=None, path=''):
    """Why Swift's synthesized Codable decoder would refuse `value` as `swift_type`, or None when it decodes. The
    one place that knows what a field's type needs: a missing or null key fails unless the type is optional, an
    Int needs a JSON integer, a Date an ISO 8601 string (the same rule as the manifest's createdAt), an enum one
    of its raw values. Keys the type doesn't list are ignored here; the closed ones are refused elsewhere."""
    optional = swift_type.endswith('?')
    base = swift_type[:-1] if optional else swift_type
    name = path or 'the document'
    if value is None:
        return None if optional else f'{name} is absent'
    if base.startswith('['):
        if not isinstance(value, list):
            return f'{name} is not a list'
        for index, element in enumerate(value):
            problem = decode_problem(element, base[1:-1], owner, f'{path}[{index}]')
            if problem:
                return problem
        return None
    if base == 'String':
        return None if isinstance(value, str) else f'{name} is not text'
    if base == 'Int':
        return None if _is_int(value) else f'{name} is not an integer'
    if base == 'Bool':
        return None if isinstance(value, bool) else f'{name} is not true or false'
    if base == 'Date':
        return None if _is_date(value) else f'{name} is not an ISO-8601 date and time with a zone'
    key = _swift_type(base, owner)
    if key in SWIFT_ENUMS:
        return None if isinstance(value, str) and value in SWIFT_ENUMS[key] else f'{name} is {value!r}, which is not known'
    if not isinstance(value, dict):
        return f'{name} is not an object'
    for field_name, field_type in SWIFT_TYPES[key].items():
        problem = decode_problem(value.get(field_name), field_type, key, f'{path}.{field_name}' if path else field_name)
        if problem:
            return problem
    return None


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


def zip_entry_type(info):
    """ZIPFoundation's Entry.type (0.9.20): from the Unix mode when the archive was made on Unix or macOS, else
    from a trailing slash (and the MS-DOS directory bit). The Swift reader reads only `file` entries, so a symlink
    stored at an allowed path is refused, not read as data."""
    directory = info.filename.endswith('/')
    host = info.create_system
    if host in (3, 19):
        mode = (info.external_attr >> 16) & 0o170000
        if mode == 0o100000:
            return 'file'
        if mode == 0o040000:
            return 'directory'
        if mode == 0o120000:
            return 'symlink'
        return 'directory' if directory else 'file'
    if host == 0:
        directory = directory or (info.external_attr >> 4) == 1
    return 'directory' if directory else 'file'


def _check_zip(report, archive, size):
    if size > MAX_PACKAGE_BYTES:
        _refuse(report, 'too-large', 'the packet is larger than 100 MB')
    entries, seen, total = {}, set(), 0
    for info in archive.infolist():
        name = info.filename
        if name in seen:
            _refuse(report, 'duplicate-entry', f'the archive holds {name} twice')
        seen.add(name)
        if zip_entry_type(info) != 'file' or not allowed_package_path(name):
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
    def not_a_number(constant):
        raise json.JSONDecodeError(f'{constant} is not JSON', '', 0)
    try:
        # Python accepts NaN and Infinity; Swift's JSON parser refuses them, even inside a field it ignores.
        return json.loads(data.decode('utf-8'), parse_constant=not_a_number)
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
    problem = decode_problem(manifest, 'SpokenMarginsPackageManifest')
    if problem:
        _refuse(report, 'invalid-manifest', problem)


def _check_distinct(report, manifest):
    artifacts, assets = manifest['artifacts'], manifest['assets']
    for group in ([_canon(a['id']) for a in artifacts], [_canon(a['id']) for a in assets],
                  [_canon(a['path']) for a in artifacts], [_canon(a['path']) for a in assets]):
        if len(set(group)) != len(group):
            _refuse(report, 'invalid-manifest', 'descriptor identities are not unique')
    names = [_canon(staged_file_name(a).lower()) for a in assets]
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
        problem = decode_problem(value, KIND_SWIFT_TYPE[kind])
        if problem:
            _refuse(report, 'invalid-manifest', f'{kind} does not decode: {problem}', where)
        if _canon(value['id']) != _canon(descriptor['id']) or value.get('schemaVersion') != version:
            _refuse(report, 'invalid-manifest', f'{kind} id or schemaVersion does not match its descriptor', where)
        decoded[kind].append((descriptor, value))
    return decoded


def _check_item(report, item):
    for key in ('canonicalURL', 'originalURL', 'enclosureURL'):
        _check_link(report, item.get(key), f'item.{key}')
    if isinstance(item.get('source'), dict):
        _check_link(report, item['source'].get('canonicalURL'), 'item.source.canonicalURL')
    title = item['title']
    if not 1 <= character_count(title) <= 500 or not swift_strip(title):
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
                or _canon(embedded[0][1]['id']) != _canon(transport.get('embeddedArtifactId') or '')):
            _refuse(report, 'transport-inconsistent', 'embedded_text transport needs one embedded_text_item named by '
                    'embeddedArtifactId, a rightsBasis, fullItemOmitted false, no canonicalURL and a non-podcast item')
        artifact = embedded[0][1]
        text = artifact.get('text')
        if not isinstance(text, str) or not swift_strip(text):
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

    assets_by_id = _ById((a['id'], a) for a in manifest['assets'])
    _check_layer(report, layers[0][1], assets_by_id)
    item_text = embedded[0][1].get('text') if embedded else None
    for descriptor, proposal in decoded['listening_map_proposal']:
        _check_proposal(report, proposal, assets_by_id, descriptor['path'], item_text)
    for descriptor, spine in decoded['edition_fingerprint_spine']:
        _check_spine(report, spine, item, assets_by_id, descriptor['path'])
    shared = _shared_signature(spine for _, spine in decoded['edition_fingerprint_spine'])
    if shared is not None:
        report.warn('older-reader-refuses', f'two fingerprint landmarks name the signature {shared!r}; Build 29 '
                    'stops with a fatal error importing this packet, and Build 30 and later keep one (#536)')
    for descriptor, sketch in decoded['transcript_phrase_sketch']:
        _check_sketch(report, sketch, descriptor['path'])
    if len(decoded['conversation']) > 1:
        _refuse(report, 'invalid-manifest', 'more than one conversation artifact')
    scoped = {_canon(m['packageScopedId']) for m in layers[0][1]['interjections']}
    for descriptor, conversation in decoded['conversation']:
        replies = conversation['replies']
        if not 1 <= len(replies) <= MAX_MARGINS * 4:
            _refuse(report, 'invalid-manifest', 'the conversation is empty or too large', descriptor['path'])
        for reply in replies:
            if (_canon(reply['packageScopedId']) not in scoped or not _is_sha(reply.get('parentPackageDigest'))
                    or not isinstance(reply.get('conversationId'), str) or not 1 <= len(reply['conversationId']) <= 200
                    or not isinstance(reply.get('parentPackageScopedId'), str)
                    or not 1 <= len(reply['parentPackageScopedId']) <= 200):
                _refuse(report, 'invalid-manifest', 'a reply link names no Margin in this packet or is out of bounds',
                        descriptor['path'])


PHRASE_SKETCH_SHINGLE_WIDTH = 3             # TranscriptPhraseSketchBuilder.shingleWidth
PHRASE_SKETCH_MAX_HASHES = 24               # TranscriptPhraseSketchBuilder.maximumHashesPerWindow
PHRASE_SKETCH_WINDOW_MS = 30_000            # TranscriptPhraseSketchBuilder.windowDurationMs
PHRASE_SKETCH_SALT_BYTES = 32
MAX_FINGERPRINT_LANDMARKS = 500
MAX_PHRASE_SKETCH_WINDOWS = 10_000
MAX_LANDMARK_SPAN_MS = 30_000
_SKETCH_HASH = re.compile(r'[0-9a-f]{32}')


def _first_failed(rules):
    """The name of the first rule whose check is false. Swift stops at its first failure (#536 names it), and a
    later rule may rely on the earlier ones having held, so the checks are lazy and run in order."""
    return next((name for name, holds in rules if not holds()), None)


def _check_spine(report, spine, item, assets_by_id, where):
    """SpokenMarginsPackageArchive.validate(_ spine:) (Build 29's frozen copy holds the same rules, unnamed)."""
    landmarks = spine['landmarks']
    failed = _first_failed([
        ('item_id', lambda: 1 <= character_count(spine['itemId']) <= 500),
        ('landmark_count', lambda: len(landmarks) <= MAX_FINGERPRINT_LANDMARKS),
        ('generator_version', lambda: character_count(spine['generatorVersion']) <= 200),
        ('canonical_url', lambda: spine.get('canonicalURL') is None or is_https_url(spine['canonicalURL'])),
        ('episode_guid', lambda: _length_ok(spine.get('episodeGUID'), 1_000)),
        ('duration', lambda: spine.get('producingEditionDurationMs') is None
         or spine['producingEditionDurationMs'] >= 0),
        ('edition_sha256', lambda: spine.get('producingEditionSHA256') is None
         or _is_sha(spine['producingEditionSHA256'])),
        ('landmark_ids', lambda: len({_canon(m['id']) for m in landmarks}) == len(landmarks)),
        ('landmark_order', lambda: [m['order'] for m in landmarks] == list(range(len(landmarks)))),
    ])
    if failed:
        _refuse(report, 'invalid-manifest', f'the episode fingerprint spine is out of bounds: {failed}', where)
    guid = spine.get('episodeGUID')
    if item.get('episodeGUID') is not None and guid is not None and _canon(guid) != _canon(item['episodeGUID']):
        _refuse(report, 'edition-mismatch', 'the fingerprint spine names a different episode from the item', where)
    for index, landmark in enumerate(landmarks):
        failed = _first_failed([
            ('source_range', lambda: landmark['sourceMediaStartMs'] >= 0
             and landmark['sourceMediaEndMs'] >= landmark['sourceMediaStartMs']),
            ('duration', lambda: landmark['sourceMediaEndMs'] - landmark['sourceMediaStartMs'] <= MAX_LANDMARK_SPAN_MS),
            ('anchor_time', lambda: landmark['anchorMediaTimeMs'] >= 0),
            ('continuity_epoch', lambda: landmark['continuityEpoch'] >= 0),
            ('generator_version', lambda: character_count(landmark['generatorVersion']) <= 200),
            ('signature_asset', lambda: (assets_by_id.get(landmark['signatureAssetId']) or {}).get('role')
             == ROLE_SIGNATURE),
        ])
        if failed:
            _refuse(report, 'invalid-manifest', f'fingerprint landmark {index + 1} is invalid: {failed}', where)


def _shared_signature(spines):
    """The first signature id a second landmark names, across every spine. Build 29's import keys the episode map's
    evidence by signature id with `uniqueKeysWithValues`, which traps on a repeat; Build 30 keeps the first, and the
    app's writer keeps one landmark per signature (#536). Found with coop-packet check on the Mac (#1856)."""
    seen = set()
    for spine in spines:
        for landmark in spine['landmarks']:
            key = _canon(landmark['signatureAssetId'])
            if key in seen:
                return landmark['signatureAssetId']
            seen.add(key)
    return None


def _salt_is_32_bytes(salt):
    try:
        return len(base64.b64decode(salt, validate=True)) == PHRASE_SKETCH_SALT_BYTES
    except ValueError:
        return False


def _check_sketch(report, sketch, where):
    """SpokenMarginsPackageArchive.validate(_ sketch:) and the check on each of its windows."""
    windows = sketch['windows']
    failed = _first_failed([
        ('item_id', lambda: 1 <= character_count(sketch['itemId']) <= 500),
        ('normalization_version', lambda: character_count(sketch['normalizationVersion']) <= 200),
        ('shingle_width', lambda: sketch['shingleWidth'] == PHRASE_SKETCH_SHINGLE_WIDTH),
        ('maximum_hashes', lambda: sketch['maximumHashesPerWindow'] == PHRASE_SKETCH_MAX_HASHES),
        ('salt', lambda: _salt_is_32_bytes(sketch['saltBase64'])),
        ('window_count', lambda: len(windows) <= MAX_PHRASE_SKETCH_WINDOWS),
        ('window_ids', lambda: len({_canon(w['id']) for w in windows}) == len(windows)),
    ])
    if failed:
        _refuse(report, 'invalid-manifest', f'the transcript phrase sketch is out of bounds: {failed}', where)
    for index, window in enumerate(windows):
        failed = _first_failed([
            ('start', lambda: window['sourceStartMs'] >= 0),
            ('range', lambda: window['sourceEndMs'] >= window['sourceStartMs']),
            ('span', lambda: window['sourceEndMs'] - window['sourceStartMs'] <= PHRASE_SKETCH_WINDOW_MS),
            ('hash_count', lambda: len(window['hashes']) <= sketch['maximumHashesPerWindow']),
            ('hash_form', lambda: all(isinstance(h, str) and _SKETCH_HASH.fullmatch(h) for h in window['hashes'])),
        ])
        if failed:
            _refuse(report, 'invalid-manifest', f'phrase sketch window {index + 1} is invalid: {failed}', where)


INTERJECTION_KEYS = frozenset({'packageScopedId', 'createdAt', 'anchor', 'defaultRepresentationId', 'representations'})
ANCHOR_KEYS = frozenset({'anchorType', 'startChar', 'endChar', 'exactText', 'prefix', 'suffix', 'mediaTimeMs',
                         'roughPercent', 'transcriptSegmentId', 'chapterTitle', 'machineEvidenceAssetIds'})
REPRESENTATION_KEYS = frozenset({'id', 'kind', 'approvedTranscript', 'assetId', 'provenance'})


def _check_layer(report, layer, assets_by_id):
    where = 'commentary layer'
    for key in sorted(set(layer) - {'id', 'schemaVersion', 'interjections'}):
        report.warn('ignored-field', f'{key!r} is not a commentary layer field; shipped readers ignore it', where)
    interjections = layer['interjections']
    if not 1 <= len(interjections) <= MAX_MARGINS:
        _refuse(report, 'invalid-manifest', f'the commentary layer needs 1-{MAX_MARGINS} Margins', where)
    scoped = [_canon(m['packageScopedId']) for m in interjections]
    if len(set(scoped)) != len(scoped):
        _refuse(report, 'invalid-manifest', 'package-scoped Margin ids are not unique', where)
    for index, margin in enumerate(interjections):
        at = f'{where} Margin {index + 1}'
        for key in sorted(set(margin) - INTERJECTION_KEYS):
            report.warn('ignored-field', f'{key!r} is not a Margin field; shipped readers ignore it', at)
        anchor = margin['anchor']
        for key in sorted(set(anchor) - ANCHOR_KEYS):
            report.warn('ignored-field', f'{key!r} is not an anchor field; shipped readers ignore it', at)
        representations = margin['representations']
        start, end = anchor.get('startChar'), anchor.get('endChar')
        bounded = (1 <= character_count(margin['packageScopedId']) <= 200 and representations
                   and len({_canon(r['id']) for r in representations}) == len(representations)
                   and any(_canon(r['id']) == _canon(margin['defaultRepresentationId']) for r in representations)
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
            transcript, kind = representation['approvedTranscript'], representation['kind']
            if (not 1 <= character_count(representation['id']) <= 200 or not swift_strip(transcript)
                    or character_count(transcript) > 50_000):
                _refuse(report, 'invalid-manifest', 'a representation is empty or out of bounds', at)
            asset_id = representation.get('assetId')
            if kind in TEXT_REPRESENTATIONS and asset_id is not None:
                _refuse(report, 'invalid-manifest', 'a text representation references audio', at)
            if kind in AUDIO_REPRESENTATIONS and not str((assets_by_id.get(asset_id) or {}).get('path', '')).startswith('assets/audio/'):
                _refuse(report, 'invalid-manifest', 'an audio representation names no voice asset', at)


VERBATIM_RUN_WORDS = 10          # PortableListeningMapContract.verbatimRunWords
SUMMARY_FIELDS = ('summaryText', 'summaryAssetId', 'summaryProvenance')


def _words(text):
    """PortableListeningMapContract.words: lowercased runs of letters and digits (exact for ASCII text)."""
    return re.findall(r'[^\W_]+', text.lower())


def _runs(words, length=VERBATIM_RUN_WORDS):
    if len(words) < length:
        return set()
    return {' '.join(words[i:i + length]) for i in range(len(words) - length + 1)}


def _shares_run(text_words, source_runs, length=VERBATIM_RUN_WORDS):
    return bool(source_runs) and len(text_words) >= length and any(
        ' '.join(text_words[i:i + length]) in source_runs for i in range(len(text_words) - length + 1))


def _anchor_quote(anchor):
    return ' '.join(anchor[k] for k in ('prefix', 'exactText', 'suffix') if anchor.get(k) is not None)


# Letters Swift's Character.isLetter (Unicode "Alphabetic") counts although their category is a symbol: circled and
# squared letters.
_SYMBOL_LETTERS = ((0x24B6, 0x24E9), (0x1F130, 0x1F149), (0x1F150, 0x1F169), (0x1F170, 0x1F189))


def _is_word_character(char):
    return unicodedata.category(char)[0] in 'LMN' or any(low <= ord(char) <= high for low, high in _SYMBOL_LETTERS)


def _max_words(text):
    """A count Swift's `words` cannot exceed: the runs of letters, marks and numbers (a Swift word is a run of
    Characters whose first code point is a letter or a number). Unlike _words() it holds for any text, so below the
    10-word minimum a quotation is ruled out whatever the script."""
    count, inside = 0, False
    for char in text:
        word = _is_word_character(char)
        count += word and not inside
        inside = word
    return count


class Quotation:
    """PortableListeningMapContract.quotesSource, and whether this module can decide it. Python splits words
    and counts Characters as Swift does only for ASCII text, so a check whose answer depends on other text is
    `undecided`. Most checks need no guess: a text under ten words can't quote anything, and neither can one whose
    sources hold fewer than ten."""

    def __init__(self, item_text=None):
        self.item_text = item_text or ''
        self.undecided = False      # some check could not be decided
        self.decided = True         # the last check could

    def quotes(self, text, scene):
        self.decided = True
        if _max_words(text) < VERBATIM_RUN_WORDS:
            return False
        anchors = [_anchor_quote(scene[a]) for a in ('startAnchor', 'endAnchor')]
        sources = anchors + [self.item_text]
        if all(_max_words(source) < VERBATIM_RUN_WORDS for source in sources):
            return False
        if not (text.isascii() and all(source.isascii() for source in sources)):
            self.decided = False
            self.undecided = True
        text_words = _words(text)
        if any(_shares_run(text_words, _runs(_words(anchor))) for anchor in anchors):
            return True
        if not self.item_text:
            return False
        start, end = scene['startAnchor'], scene['endAnchor']
        lower = start.get('startChar') if start.get('startChar') is not None else start.get('endChar')
        upper = end.get('endChar') if end.get('endChar') is not None else end.get('startChar')
        characters = graphemes(self.item_text)
        if lower is not None and upper is not None and 0 <= lower < upper <= len(characters):
            return _shares_run(text_words, _runs(_words(''.join(characters[lower:upper]))))
        return _shares_run(text_words, _runs(_words(self.item_text)))


def _position(anchor, is_end):
    first, second = ('endChar', 'startChar') if is_end else ('startChar', 'endChar')
    character = anchor.get(first) if anchor.get(first) is not None else anchor.get(second)
    if anchor.get('mediaTimeMs') is None and character is None:
        return None
    return anchor.get('mediaTimeMs'), character


def _is_past(reached, start):
    return any(left is not None and right is not None and left > right for left, right in zip(reached, start))


def _furthest(reached, position):
    if position is None:
        return reached
    return tuple(max((v for v in pair if v is not None), default=None) for pair in zip(reached, position))


def listening_map_violations(proposal, quotation):
    """PortableListeningMapContract.violations: (scene id, rule, certain) for each scene rule the proposal breaks.
    A rule is certain unless it rests on a quotation check the module could not decide."""
    found = []
    reached_start = reached_end = (None, None)
    for scene in proposal['scenes']:
        scene_id = scene['id']
        has_summary = bool(scene.get('summaryText')) or scene.get('summaryAssetId') is not None
        if scene['eligibility'] == 'eligible':
            if not scene.get('summaryText') or scene.get('summaryProvenance') is None:
                found.append((scene_id, 'an eligible scene lacks a grounded summary', True))
        elif has_summary:
            found.append((scene_id, 'an excluded or unknown scene carries a summary', True))
        start, end = _position(scene['startAnchor'], False), _position(scene['endAnchor'], True)
        if start is not None and end is not None and _is_past(start, end):
            found.append((scene_id, 'the scene ends before it starts', True))
        if start is not None:
            if _is_past(reached_start, start):
                found.append((scene_id, 'the scene starts before an earlier scene', True))
            elif _is_past(reached_end, start):
                found.append((scene_id, 'the scene overlaps an earlier scene', True))
        if scene.get('summaryText') and quotation.quotes(scene['summaryText'], scene):
            found.append((scene_id, f'the summary quotes {VERBATIM_RUN_WORDS} or more words of its source',
                          quotation.decided))
        for note in (scene.get('title'), scene.get('eligibilityReason'), scene['startAnchor'].get('chapterTitle'),
                     scene['endAnchor'].get('chapterTitle')):
            if note is not None and quotation.quotes(note, scene):
                found.append((scene_id, f'a title or eligibility reason quotes {VERBATIM_RUN_WORDS} or more words',
                              quotation.decided))
                break
        reached_start, reached_end = _furthest(reached_start, start), _furthest(reached_end, end)
    return found


def for_sharing(proposal, quotation):
    """PortableListeningMapContract.forSharing for one proposal: summaries stripped from excluded and unknown scenes,
    quoting titles, eligibility reasons and chapter titles dropped. Returns (proposal, []) when it survives, and
    (None, the rules it still breaks) when the shipped reader leaves it out and imports the Margins."""
    scenes = []
    for scene in proposal['scenes']:
        scene = json.loads(json.dumps(scene))
        if scene['eligibility'] != 'eligible':
            for key in SUMMARY_FIELDS:
                scene.pop(key, None)
        for key in ('title', 'eligibilityReason'):
            if scene.get(key) is not None and quotation.quotes(scene[key], scene):
                scene.pop(key)
        for anchor in ('startAnchor', 'endAnchor'):
            title = scene[anchor].get('chapterTitle')
            if title is not None and quotation.quotes(title, scene):
                scene[anchor].pop('chapterTitle')
        scenes.append(scene)
    kept = {**proposal, 'scenes': scenes}
    violations = listening_map_violations(kept, quotation)
    return (None, violations) if violations else (kept, [])


def _proposal_bounds_problem(proposal, assets_by_id, eligible_needs_summary=False):
    """SpokenMarginsPackageArchive.validate(proposal): the first bound the proposal breaks, or None. Build 29's
    frozen reader (Packages/SessionKit/Tests/ShippedReader) runs it, with the eligible-summary rule, on every
    proposal as decoded; later readers run it only on what survives forSharing."""
    scenes = proposal['scenes']
    if (not scenes or character_count(proposal['generator']) > 200 or len({_canon(s['id']) for s in scenes}) != len(scenes)
            or [s['order'] for s in scenes] != list(range(len(scenes)))):
        return 'Listening Map proposal order is invalid'
    for scene in scenes:
        if (not _length_ok(scene.get('title'), 500) or not _length_ok(scene.get('summaryText'), 10_000)
                or not _length_ok(scene.get('eligibilityReason'), 500)):
            return 'Listening Map scene is out of bounds'
        if eligible_needs_summary and scene['eligibility'] == 'eligible' and (
                not scene.get('summaryText') or scene.get('summaryProvenance') is None):
            return 'eligible scene lacks a grounded summary'
        if scene.get('summaryAssetId') is not None and (
                assets_by_id.get(scene['summaryAssetId']) or {}).get('role') != ROLE_SUMMARY_VOICE:
            return 'scene summary asset is absent or has the wrong role'
    return None


def _check_proposal(report, proposal, assets_by_id, where, item_text=None):
    """SpokenMarginsPackageArchive.read: a proposal that breaks a scene rule after forSharing is left out (#480), and
    only a proposal that survives meets validate(proposal), where a broken bound refuses the packet. Build 29 has
    no forSharing step and refuses the packet instead, which is a warning here: Build 30 and later import it."""
    quotation = Quotation(item_text)
    kept, broken = for_sharing(proposal, quotation)
    # The structural rules and every decided quotation check are exact; a quotation check on text this module
    # can't split into words as Swift does is a guess, so what rests on one is a warning, not a verdict.
    exact = not quotation.undecided
    if kept is None:
        sure = [(i, r) for i, r, certain in broken if certain]
        if sure:
            note = ('proposal-dropped', f'scene {sure[0][0]!r}: {sure[0][1]}; the app leaves this Listening Map '
                    'proposal out on import and keeps the Margins')
        else:
            note = ('not-checked', 'the Listening Map quotation rule on non-ASCII text is left to the Swift reader')
    else:
        problem = _proposal_bounds_problem(kept, assets_by_id)
        if problem is not None and exact:
            _refuse(report, 'invalid-manifest', problem, where)
        note = problem and ('not-checked', f'{problem}, unless the Swift reader finds a quotation in non-ASCII text '
                            'and leaves the proposal out')
        if note is None and not exact:
            note = ('not-checked', 'the Listening Map quotation rule on non-ASCII text is left to the Swift reader')
    older = _proposal_bounds_problem(proposal, assets_by_id, eligible_needs_summary=True)
    if older:
        report.warn('older-reader-refuses', f'Build 29 refuses this packet ({older}); Build 30 and later read the '
                    'Listening Map proposal through forSharing', where)
    if note:
        report.warn(*note, where)


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
        default = next(r for r in margin['representations'] if _canon(r['id']) == _canon(margin['defaultRepresentationId']))
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
    return _zip(entries)


def _deflated_size(body):
    """The size zipfile's ZIP_DEFLATED writes for `body` (raw deflate at the default level)."""
    compressor = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -15)
    return len(compressor.compress(body) + compressor.flush())


def compression_for(name, body):
    """The Swift writer's choice (SpokenMarginsPackageArchive.write, addDeflatedWithinReaderLimit): assets are
    stored as they are; every other entry is deflated unless that would pass the 100x ratio the readers refuse
    (very repetitive text does), in which case it is stored too."""
    if name.startswith('assets/'):
        return zipfile.ZIP_STORED
    deflated = _deflated_size(body)
    if deflated > 0 and len(body) // max(1, deflated) > MAX_COMPRESSION_RATIO:
        return zipfile.ZIP_STORED
    return zipfile.ZIP_DEFLATED


def _zip(entries):
    """Zip (name, bytes) pairs in order with a fixed date, compressed the way the Swift writer does."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        for name, body in entries:
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_DATE)
            info.compress_type = compression_for(name, body)
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

    # Listening Map proposals pass through PortableListeningMapContract.forSharing before the reader checks them.
    def media(ms):
        return {'anchorType': 'media', 'mediaTimeMs': ms, 'machineEvidenceAssetIds': []}

    def with_proposal(edit):
        manifest, artifacts, assets = copy(podcast)
        scenes = [
            {'id': 'scene-intro', 'order': 0, 'eligibility': 'excluded', 'eligibilityReason': 'the show opens',
             'startAnchor': media(0), 'endAnchor': media(60_000)},
            {'id': 'scene-main', 'order': 1, 'eligibility': 'eligible', 'title': 'The main conversation',
             'summaryText': 'A summary written for this example.', 'summaryProvenance': 'sender_authored',
             'startAnchor': media(60_000), 'endAnchor': media(600_000)},
        ]
        edit(scenes)
        proposal = {'id': 'map-1', 'schemaVersion': LISTENING_MAP_PROPOSAL_VERSION, 'createdAt': '2026-10-16T12:00:00Z',
                    'generator': 'spoken_margins_format.py corpus', 'scenes': scenes}
        manifest['artifacts'].append({'id': 'map-1', 'kind': 'listening_map_proposal', 'path': 'artifacts/map-1.json',
                                      'required': False, 'schemaVersion': LISTENING_MAP_PROPOSAL_VERSION})
        artifacts['artifacts/map-1.json'] = encode_manifest(proposal)
        return write_packet(manifest, artifacts, assets)

    out['proposal-excluded-scene-summary.spokenmargins'] = with_proposal(
        lambda scenes: scenes[0].update(summaryAssetId='asset-not-in-packet'))
    out['proposal-dropped.spokenmargins'] = with_proposal(
        lambda scenes: (scenes[1].pop('summaryText'), scenes[0].update(order=1), scenes[1].update(order=0)))
    out['invalid-proposal-order.spokenmargins'] = with_proposal(
        lambda scenes: (scenes[0].update(order=1), scenes[1].update(order=0)))

    # Fingerprint spines and phrase sketches (#1856). A valid spine needs a real ShazamKit signature, which this
    # module can't write, so only a spine refused before its assets are read is an example.
    def with_artifact(kind, document):
        manifest, artifacts, assets = copy(podcast)
        path = f'artifacts/{document["id"]}.json'
        manifest['artifacts'].append({'id': document['id'], 'kind': kind, 'path': path, 'required': False,
                                      'schemaVersion': ARTIFACT_VERSIONS[kind]})
        artifacts[path] = encode_manifest({**document, 'schemaVersion': ARTIFACT_VERSIONS[kind]})
        return write_packet(manifest, artifacts, assets)

    def sketch(window_end_ms):
        windows = [{'id': f'window-{i}', 'sourceStartMs': i * 30_000, 'sourceEndMs': (i + 1) * 30_000,
                    'hashes': [hashlib.md5(f'{i}-{h}'.encode()).hexdigest() for h in range(PHRASE_SKETCH_MAX_HASHES)]}
                   for i in range(2)]
        windows[-1]['sourceEndMs'] = window_end_ms
        return {'id': 'sketch-1', 'itemId': 'podcast-item', 'createdAt': '2026-10-28T12:00:00Z',
                'saltBase64': base64.b64encode(bytes(range(PHRASE_SKETCH_SALT_BYTES))).decode(),
                'normalizationVersion': 'spoken_margins_format.py corpus', 'shingleWidth': PHRASE_SKETCH_SHINGLE_WIDTH,
                'maximumHashesPerWindow': PHRASE_SKETCH_MAX_HASHES, 'windows': windows}

    out['phrase-sketch.spokenmargins'] = with_artifact('transcript_phrase_sketch', sketch(60_000))
    out['invalid-sketch-window-span.spokenmargins'] = with_artifact('transcript_phrase_sketch', sketch(60_001))
    landmark = {'id': 'landmark-1', 'order': 1, 'sourceMediaStartMs': 60_000, 'sourceMediaEndMs': 70_000,
                'anchorMediaTimeMs': 65_000, 'continuityEpoch': 0, 'trigger': 'initial_playback',
                'provenance': 'observed_decoded_playback', 'signatureAssetId': 'signature-1',
                'generatorVersion': 'spoken_margins_format.py corpus'}
    out['invalid-spine-landmark-order.spokenmargins'] = with_artifact('edition_fingerprint_spine', {
        'id': 'spine-1', 'itemId': 'podcast-item', 'createdAt': '2026-10-28T12:00:00Z',
        'generatorVersion': 'spoken_margins_format.py corpus', 'landmarks': [landmark]})
    return out


def _rezip(manifest, preview, artifacts, assets):
    """Zip a manifest as it is, without recomputing anything: a packet edited after export."""
    return _zip([('manifest.json', encode_manifest(manifest)), ('preview.md', preview)]
                + sorted(artifacts.items()) + sorted(assets.items()))


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
