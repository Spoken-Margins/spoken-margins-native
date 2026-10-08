#!/usr/bin/env python3
"""Sharing test kit (#848): prepared packets made from public content, and the checks that keep them honest.

The kit is described once, in docs/sharing-test-kit/kit.json: three public items (two episodes of one show
that share a six-second intro, and one web article) and four packets of synthetic Margins. The owner's
ten-minute procedure is docs/sharing-test-kit/procedure.md.

    sharing_kit.py lint                 kit.json and procedure.md agree with each other and with the packet rules (offline)
    sharing_kit.py plans [--work DIR]   write the coop-packet plans (offline)
    sharing_kit.py verify-content       public audio, intro, license and quotes still match kit.json (needs network)
    sharing_kit.py build [--work DIR]   Mac only: fetch audio, write the packets with coop-packet, check them, list their hashes
    sharing_kit.py lint-packets FILE... read built packets without Swift: schema, hashes, kit.json, Build 29 capability rule
    sharing_kit.py stage [--work DIR]   copy checked packets into docs/sharing-test-kit/packets/

Packets are written by `coop-packet` (Packages/SessionKit/Sources/CoopPacket), the same SessionKit code the app uses.
That tool needs macOS: `say` speaks the voices and ShazamKit signs the episode audio. Everything else here runs anywhere.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KIT_DIR = ROOT / 'docs' / 'sharing-test-kit'
KIT_FILE = KIT_DIR / 'kit.json'
PROCEDURE_FILE = KIT_DIR / 'procedure.md'
PACKETS_DIR = KIT_DIR / 'packets'
SCHEMAS = ROOT / 'Contracts' / 'schemas'
DEFAULT_WORK = ROOT / 'artifacts' / 'sharing-kit'
COOP_PACKET = ROOT / 'Packages' / 'SessionKit'

# The limits below come from the code that reads and writes packets.
MAX_MARGINS = 50                      # InterjectionPackageArchive.maximumInterjections
MAX_PACKET_BYTES = 100 * 1024 * 1024  # InterjectionPackageArchive.maximumPackageBytes
MAX_VOICE_MS = 10 * 60 * 1000         # a voice asset longer than 10 minutes is refused
MIN_EVIDENCE_MS = 3_000               # PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs
ANCHOR_GAP_MS = 500                   # PodcastAnchorEvidenceGenerator.anchorGapMs
FLANK_MS = 11_000                     # about 11 s of sound either side of a Margin (ShazamKit takes at most 12 s)
# Build 29 reads these and no other; a packet that needs more would not open there.
BUILD_29_CAPABILITIES = {'spoken-margins.commentary-layer.v1'}
ITEM_TYPES = {'podcast': 'podcast', 'article': 'text'}
SOURCE_TYPES = {'podcast': 'podcast', 'article': 'article'}
ASSET_ROLE_VOICE = 'original_voice'
ASSET_ROLE_SIGNATURE = 'acoustic_signature'
FORBIDDEN_IN_PROCEDURE = ('reinstall', 'reset', 'erase', 'delete app', 'delete the app', 'offload')


class KitError(Exception):
    pass


def load_kit(path=KIT_FILE):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def packet_file_name(packet):
    return f"{packet['file']}.spokenmargins"


def margin_count_phrase(count):
    return f"{count} shared Margin{'' if count == 1 else 's'}"


# --- the shareable-link rule, as SessionKit's ShareableLinkPolicy applies it -----------------------------------

PRIVATE_HOST_SUFFIXES = (
    'patreon.com', 'patreonusercontent.com', 'supercast.com', 'supercast.tech',
    'supportingcast.fm', 'memberful.com', 'memberfulcontent.com',
)
PRIVATE_PATH_MARKERS = {
    'private', 'premium', 'paid', 'subscriber', 'subscribers', 'member', 'members', 'patron', 'patrons',
    'supporter', 'supporters',
}
CREDENTIAL_QUERY_FRAGMENTS = (
    'token', 'auth', 'key', 'secret', 'sig', 'hash', 'pass', 'pwd', 'session', 'credential', 'jwt', 'expire',
    'policy', 'hmac', 'access',
)
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


# --- kit.json rules ----------------------------------------------------------------------------------------------

def _is_https(value):
    return isinstance(value, str) and urllib.parse.urlsplit(value).scheme.lower() == 'https'


def validate_kit(kit):
    """The problems in kit.json, as plain sentences. Empty when it is sound."""
    problems = []
    items = kit.get('items', {})
    if not items:
        return ['kit.json has no items']
    for key, item in items.items():
        kind = item.get('kind')
        identity = item.get('identity', {})
        if kind not in ITEM_TYPES:
            problems.append(f'{key}: kind must be podcast or article')
            continue
        if identity.get('itemType') != ITEM_TYPES[kind]:
            problems.append(f"{key}: a {kind} has itemType {ITEM_TYPES[kind]}")
        if not identity.get('title') or len(identity['title']) > 500:
            problems.append(f'{key}: needs a title of up to 500 characters')
        if not _is_https(identity.get('canonicalURL')):
            problems.append(f'{key}: canonicalURL must be https')
        for field in ('canonicalURL', 'originalURL', 'enclosureURL', 'episodeGUID'):
            value = identity.get(field)
            if value and value.lower().startswith(('http://', 'https://')) and not is_shareable_link(value):
                problems.append(f'{key}: {field} looks private, so the exporter would drop it')
        if len(identity.get('episodeGUID') or '') > 1000 or len(identity.get('publishedAt') or '') > 100:
            problems.append(f'{key}: episodeGUID or publishedAt is too long for a packet')
        if kind == 'podcast':
            if not _is_https(identity.get('enclosureURL')):
                problems.append(f'{key}: enclosureURL must be https')
            if not isinstance(identity.get('durationMs'), int) or identity['durationMs'] <= 0:
                problems.append(f'{key}: needs durationMs')
            audio = item.get('audio', {})
            if audio.get('url') != identity.get('enclosureURL'):
                problems.append(f'{key}: audio.url must be the enclosureURL the listener pastes')
            if not re.fullmatch(r'[0-9a-f]{64}', audio.get('sha256', '')):
                problems.append(f'{key}: audio.sha256 must be 64 hex characters')
            if not isinstance(audio.get('bytes'), int) or audio['bytes'] <= 0:
                problems.append(f'{key}: audio.bytes must be a positive number')
            if not item.get('source', {}).get('license'):
                problems.append(f'{key}: name the license of the audio')
        elif identity.get('enclosureURL') or identity.get('episodeGUID'):
            problems.append(f'{key}: an article has no enclosure or GUID')

    seen_files = set()
    for packet in kit.get('packets', []):
        name = packet.get('file', '?')
        if name in seen_files or not re.fullmatch(r'[a-z0-9-]+', name):
            problems.append(f'{name}: file names are unique and use a-z, 0-9 and dashes')
        seen_files.add(name)
        item = items.get(packet.get('item'))
        if item is None:
            problems.append(f'{name}: item {packet.get("item")!r} is not in items')
            continue
        if 'synthetic' not in packet.get('sender', '').lower() or len(packet['sender']) > 120:
            problems.append(f'{name}: the sender label says "synthetic" so no one mistakes it for a person')
        if not packet.get('voice'):
            problems.append(f'{name}: needs a voice')
        margins = packet.get('margins', [])
        if not 1 <= len(margins) <= MAX_MARGINS:
            problems.append(f'{name}: a packet holds 1 to {MAX_MARGINS} Margins')
        ids = [m.get('id') for m in margins]
        if len(set(ids)) != len(ids) or not all(re.fullmatch(r'[a-z][a-z0-9-]*', i or '') for i in ids):
            problems.append(f'{name}: Margin ids are unique and use a-z, 0-9 and dashes')
        if not any(m.get('spoken', True) for m in margins):
            problems.append(f'{name}: at least one Margin is spoken')
        for margin in margins:
            label = f"{name}/{margin.get('id')}"
            text = margin.get('text', '')
            if not text.strip():
                problems.append(f'{label}: needs text')
            elif margin.get('spoken', True) and len(text.split()) > 40:
                problems.append(f'{label}: a spoken Margin of more than 40 words runs long')
        if item['kind'] == 'podcast':
            _validate_podcast_packet(kit, packet, item, problems)
        else:
            _validate_article_packet(packet, margins, problems)
    if not kit.get('packets'):
        problems.append('kit.json has no packets')
    return problems


def _validate_podcast_packet(kit, packet, item, problems):
    name = packet['file']
    source_key = packet.get('evidenceFrom', packet['item'])
    source = kit['items'].get(source_key)
    if source is None or source.get('kind') != 'podcast':
        problems.append(f'{name}: evidenceFrom must name a podcast item')
        return
    wrong_cut = bool(packet.get('wrongCut'))
    if wrong_cut == (source_key == packet['item']):
        problems.append(f'{name}: evidence from another episode is a wrongCut packet, and only that')
    duration = source['identity']['durationMs']
    margins = packet['margins']
    for margin in margins:
        label = f"{name}/{margin['id']}"
        at = margin.get('atMs')
        if not isinstance(at, int):
            problems.append(f'{label}: a podcast Margin has atMs')
            continue
        if at < MIN_EVIDENCE_MS + ANCHOR_GAP_MS:
            problems.append(f'{label}: before {MIN_EVIDENCE_MS + ANCHOR_GAP_MS} ms there is no sound for the "before" fingerprint')
        if at > duration - MIN_EVIDENCE_MS - ANCHOR_GAP_MS:
            problems.append(f'{label}: too near the end of the audio for the "after" fingerprint')
        if at > item['identity']['durationMs']:
            problems.append(f'{label}: beyond the end of {packet["item"]}')
    if wrong_cut:
        intro_ms = int(min(
            kit['items'][packet['item']]['audio'].get('sharedIntroSeconds', 0),
            source['audio'].get('sharedIntroSeconds', 0),
        ) * 1000)
        if intro_ms <= 0:
            problems.append(f'{name}: a wrongCut packet needs two episodes that share an intro')
        # Each Margin brings a "before" and an "after" fingerprint. Those that overlap the shared intro could
        # match the listener's real episode; the rest cannot. SessionKit places nothing when half or fewer of a
        # packet's fingerprints match, so the packet keeps clear of that line.
        could_match = 0
        for margin in margins:
            at = margin.get('atMs', 0)
            could_match += at - ANCHOR_GAP_MS - FLANK_MS < intro_ms
            could_match += at + ANCHOR_GAP_MS < intro_ms
        if could_match * 2 >= 2 * len(margins):
            problems.append(f'{name}: half or more of the fingerprints could match the shared intro; place most Margins later')
        if not any(m.get('atMs', 0) < intro_ms + FLANK_MS for m in margins):
            problems.append(f'{name}: put one Margin in the shared intro, so the intro is part of the test')


def _validate_article_packet(packet, margins, problems):
    name = packet['file']
    if packet.get('evidenceFrom') or packet.get('wrongCut'):
        problems.append(f'{name}: an article packet has no audio evidence')
    quotes = [m.get('quote') for m in margins]
    for margin in margins:
        if not margin.get('quote'):
            problems.append(f"{name}/{margin.get('id')}: an article Margin quotes the words it sits on")
        elif len(margin['quote']) > 1000 or margin['quote'] != margin['quote'].strip():
            problems.append(f"{name}/{margin.get('id')}: quote is long or has stray spaces")
        if 'atMs' in margin:
            problems.append(f"{name}/{margin.get('id')}: an article Margin has no atMs")
    if len(set(quotes)) != len(quotes):
        problems.append(f'{name}: each quote is used once')


def procedure_problems(kit, text):
    """What the owner's procedure must say for the kit to be usable, checked against kit.json."""
    problems = []
    lowered = text.lower()
    for word in FORBIDDEN_IN_PROCEDURE:
        if word in lowered:
            problems.append(f'procedure.md must not tell the listener to "{word}" (nothing deletes the app or his Library)')
    for issue in (456, 536, 848):
        if f'#{issue}' not in text and f'/issues/{issue}' not in text:
            problems.append(f'procedure.md does not name issue {issue}')
    for key, item in kit['items'].items():
        page = item['source']['page']
        if page not in text:
            problems.append(f'procedure.md has no link to the page for {key}')
        if item.get('listenerMayAdd'):
            url = item['audio']['url'] if item['kind'] == 'podcast' else page
            if f'```\n{url}\n```' not in text:
                problems.append(f'procedure.md has no copy block holding the link for {key}')
    for packet in kit['packets']:
        name = packet_file_name(packet)
        if name not in text:
            problems.append(f'procedure.md never names {name}')
        if packet['sender'] not in text:
            problems.append(f"procedure.md never names the sender {packet['sender']!r}")
        if margin_count_phrase(len(packet['margins'])) not in text:
            problems.append(f"procedure.md never says {margin_count_phrase(len(packet['margins']))!r} for {name}")
        for margin in packet['margins']:
            heard = margin['text'].split('.')[0]
            if heard not in text:
                problems.append(f"procedure.md never says what {packet['file']}/{margin['id']} says ({heard!r})")
    return problems


def lint(kit=None, procedure=None):
    kit = kit or load_kit()
    text = procedure if procedure is not None else PROCEDURE_FILE.read_text(encoding='utf-8')
    return validate_kit(kit) + procedure_problems(kit, text)


# --- coop-packet plans -------------------------------------------------------------------------------------------

def plan_for(kit, packet, plan_dir, audio_dir):
    """The coop-packet plan for one packet. Paths in it are relative to the plan file."""
    item = kit['items'][packet['item']]
    plan = {
        'sender': packet['sender'],
        'voice': packet['voice'],
        'createdAt': kit['createdAt'],
        'fileName': packet['file'],
        'item': item['identity'],
        'margins': [],
    }
    if item['kind'] == 'podcast':
        audio = Path(audio_dir) / f"{packet.get('evidenceFrom', packet['item'])}.mp3"
        plan['episodeAudio'] = Path(os.path.relpath(audio, plan_dir)).as_posix()
    for margin in packet['margins']:
        entry = {'id': margin['id'], 'text': margin['text']}
        if 'quote' in margin:
            entry['quote'] = margin['quote']
        else:
            entry['atMs'] = margin['atMs']
        if margin.get('spoken') is False:
            entry['spoken'] = False
        plan['margins'].append(entry)
    return plan


def write_plans(kit, work):
    plan_dir, audio_dir = Path(work) / 'plans', Path(work) / 'audio'
    plan_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for packet in kit['packets']:
        path = plan_dir / f"{packet['file']}.json"
        path.write_text(json.dumps(plan_for(kit, packet, plan_dir, audio_dir), indent=2) + '\n', encoding='utf-8')
        paths.append(path)
    return paths


# --- reading built packets without Swift ---------------------------------------------------------------------------

def _validator(name):
    try:
        import jsonschema
    except ImportError as error:
        raise KitError('lint-packets needs jsonschema: scripts/bootstrap-python-tools.sh') from error
    schema = json.loads((SCHEMAS / name).read_text(encoding='utf-8'))
    return jsonschema.Draft202012Validator(schema)


def _schema_problems(validator, document, label):
    return [f"{label}: {'/'.join(map(str, e.absolute_path)) or '(top)'} {e.message}" for e in validator.iter_errors(document)]


def lint_packet(path, kit):
    """Problems found by opening a built packet as a zip. The Swift check (`coop-packet check`, which reads the
    packet with the Build 29 reader too) stays the authority; this catches the rest on any machine."""
    path = Path(path)
    packet = next((p for p in kit['packets'] if packet_file_name(p) == path.name), None)
    problems = []
    if packet is None:
        return [f'{path.name}: not a packet named in kit.json']
    if path.stat().st_size > MAX_PACKET_BYTES:
        problems.append(f'{path.name}: larger than 100 MB')
    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        return [f'{path.name}: not a zip archive']
    with archive:
        names = [info.filename for info in archive.infolist()]
        if len(set(names)) != len(names):
            problems.append(f'{path.name}: duplicate entries')
        for entry in names:
            if entry.startswith('/') or '..' in entry.split('/') or entry.endswith('/'):
                problems.append(f'{path.name}: unsafe entry {entry}')
        if 'manifest.json' not in names:
            return problems + [f'{path.name}: no manifest.json']
        manifest = json.loads(archive.read('manifest.json'))
        problems += _schema_problems(_validator('spoken-margins-package.schema.json'), manifest, 'manifest')
        listed = {a['path'] for a in manifest.get('artifacts', [])} | {a['path'] for a in manifest.get('assets', [])}
        for entry in names:
            if entry not in listed and entry not in ('manifest.json', 'preview.md'):
                problems.append(f'{path.name}: {entry} is in the archive but not in the manifest')
        for descriptor in manifest.get('artifacts', []) + manifest.get('assets', []):
            if descriptor['path'] not in names:
                problems.append(f"{path.name}: {descriptor['path']} is listed but missing")
                continue
            data = archive.read(descriptor['path'])
            if len(data) != descriptor['byteCount'] or hashlib.sha256(data).hexdigest() != descriptor['sha256']:
                problems.append(f"{path.name}: {descriptor['path']} does not match its size or hash in the manifest")
        extra_capabilities = set(manifest.get('requiredCapabilities', [])) - BUILD_29_CAPABILITIES
        if extra_capabilities:
            problems.append(f'{path.name}: requires {sorted(extra_capabilities)}, which Build 29 cannot read')
        layer = None
        for artifact in manifest.get('artifacts', []):
            if artifact.get('kind') == 'commentary_layer' and artifact['path'] in names:
                layer = json.loads(archive.read(artifact['path']))
        if layer is None:
            return problems + [f'{path.name}: no commentary layer']
        problems += _schema_problems(_validator('shared-commentary-layer.schema.json'), layer, 'commentary layer')
        problems += _packet_matches_kit(path.name, manifest, layer, packet, kit)
    return problems


def _packet_matches_kit(name, manifest, layer, packet, kit):
    problems = []
    item = kit['items'][packet['item']]
    identity = item['identity']
    source = manifest.get('source', {})
    expected = {'sourceType': SOURCE_TYPES[item['kind']], 'canonicalURL': identity['canonicalURL'], 'title': identity['title']}
    for field in ('episodeGUID', 'enclosureURL', 'durationMs'):
        if field in identity:
            expected[field] = identity[field]
    for field, value in expected.items():
        if source.get(field) != value:
            problems.append(f'{name}: source.{field} is {source.get(field)!r}, kit.json says {value!r}')
    if manifest.get('senderDisplayLabel') != packet['sender']:
        problems.append(f"{name}: sender is {manifest.get('senderDisplayLabel')!r}, kit.json says {packet['sender']!r}")
    assets = {a['id']: a for a in manifest.get('assets', [])}
    signatures = {i for i, a in assets.items() if a['role'] == ASSET_ROLE_SIGNATURE}
    interjections = layer.get('interjections', [])
    if [i.get('packageScopedId') for i in interjections] != [m['id'] for m in packet['margins']]:
        return problems + [f'{name}: the Margins are not the ones in kit.json, in order']
    for margin, interjection in zip(packet['margins'], interjections):
        label = f"{name}/{margin['id']}"
        representations = interjection.get('representations', [])
        chosen = next((r for r in representations if r['id'] == interjection.get('defaultRepresentationId')), None)
        if chosen is None:
            problems.append(f'{label}: no default representation')
            continue
        spoken = margin.get('spoken', True)
        if chosen['approvedTranscript'] != margin['text']:
            problems.append(f'{label}: the text differs from kit.json')
        if spoken != (chosen['kind'] == 'original_audio_and_text'):
            problems.append(f"{label}: kit.json says {'spoken' if spoken else 'text only'}, the packet has {chosen['kind']}")
        voice = assets.get(chosen.get('assetId'))
        if spoken and (voice is None or voice['role'] != ASSET_ROLE_VOICE or voice['mimeType'] != 'audio/mp4'):
            problems.append(f'{label}: a spoken Margin needs its voice file')
        if spoken and voice is not None and (voice.get('durationMs') or 0) > MAX_VOICE_MS:
            problems.append(f'{label}: voice longer than 10 minutes')
        if not spoken and chosen.get('assetId'):
            problems.append(f'{label}: a text-only Margin carries a voice file')
        anchor = interjection['anchor']
        if item['kind'] == 'podcast':
            if anchor.get('anchorType') != 'media' or anchor.get('mediaTimeMs') != margin['atMs']:
                problems.append(f"{label}: anchored at {anchor.get('mediaTimeMs')} ms, kit.json says {margin['atMs']} ms")
            evidence = anchor.get('machineEvidenceAssetIds', [])
            if not evidence or not set(evidence) <= signatures:
                problems.append(f'{label}: no acoustic fingerprint from the episode audio')
        elif anchor.get('anchorType') != 'text' or anchor.get('exactText') != margin['quote']:
            problems.append(f"{label}: anchored to {anchor.get('exactText')!r}, kit.json says {margin['quote']!r}")
    return problems


# --- fetching, building, staging ------------------------------------------------------------------------------------

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, destination):
    request = urllib.request.Request(url, headers={'User-Agent': 'spoken-margins-sharing-kit'})
    with urllib.request.urlopen(request, timeout=120) as response, open(destination, 'wb') as out:
        for chunk in iter(lambda: response.read(1 << 20), b''):
            out.write(chunk)


def fetch_audio(kit, audio_dir, fetch=download):
    """Each episode's audio, pinned by hash: the evidence in a packet is only right for this exact file."""
    audio_dir = Path(audio_dir)
    audio_dir.mkdir(parents=True, exist_ok=True)
    paths = {}
    for key, item in kit['items'].items():
        if item['kind'] != 'podcast':
            continue
        path = audio_dir / f'{key}.mp3'
        if not path.exists() or sha256_file(path) != item['audio']['sha256']:
            fetch(item['audio']['url'], path)
        if sha256_file(path) != item['audio']['sha256']:
            path.unlink()
            raise KitError(f"{key}: the audio at {item['audio']['url']} is not the file kit.json pins; "
                           'run verify-content, then update kit.json and the procedure together')
        paths[key] = path
    return paths


def installed_voices(run=subprocess.run):
    result = run(['say', '-v', '?'], capture_output=True, text=True)
    return {line.split()[0] for line in result.stdout.splitlines() if line.strip()}


def hash_list(folder):
    lines = [f'{sha256_file(p)}  {p.name}' for p in sorted(Path(folder).glob('*.spokenmargins'))]
    return '\n'.join(lines) + '\n'


def build(kit, work, run=subprocess.run, fetch=download, platform=sys.platform):
    if platform != 'darwin':
        raise KitError('build needs a Mac: coop-packet speaks the voices with `say` and signs audio with ShazamKit')
    work = Path(work)
    voices = installed_voices(run)
    missing = sorted({p['voice'] for p in kit['packets']} - voices)
    if missing:
        raise KitError(f'these voices are not installed: {missing}; `say -v ?` lists what is')
    fetch_audio(kit, work / 'audio', fetch)
    plans = write_plans(kit, work)
    out = work / 'out'
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob('*.spokenmargins'):
        old.unlink()
    package = str(COOP_PACKET)
    run(['swift', 'build', '--package-path', package, '--product', 'coop-packet'], check=True)
    bin_path = run(['swift', 'build', '--package-path', package, '--show-bin-path'],
                   check=True, capture_output=True, text=True).stdout.strip()
    tool = str(Path(bin_path) / 'coop-packet')
    for plan in plans:
        run([tool, 'build', str(plan), '--out', str(out)], check=True)
    packets = [out / packet_file_name(p) for p in kit['packets']]
    run([tool, 'check', *map(str, packets)], check=True)
    problems = [problem for packet in packets for problem in lint_packet(packet, kit)]
    if problems:
        raise KitError('built packets disagree with kit.json:\n  ' + '\n  '.join(problems))
    (out / 'SHA256SUMS').write_text(hash_list(out), encoding='utf-8')
    return packets


def stage(work, destination=PACKETS_DIR):
    out = Path(work) / 'out'
    kit = load_kit()
    packets = [out / packet_file_name(p) for p in kit['packets']]
    absent = [p.name for p in packets if not p.exists()]
    if absent:
        raise KitError(f'build first: {absent} are not in {out}')
    problems = [problem for packet in packets for problem in lint_packet(packet, kit)]
    if problems:
        raise KitError('\n'.join(problems))
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for old in destination.glob('*.spokenmargins'):
        old.unlink()
    for packet in packets:
        (destination / packet.name).write_bytes(packet.read_bytes())
    (destination / 'SHA256SUMS').write_text(hash_list(destination), encoding='utf-8')
    return [destination / p.name for p in packets]


# --- public content still matches kit.json (network) -----------------------------------------------------------------

def shared_prefix_seconds(first, second, sample_rate=8000, frame_ms=100, tolerance=0.5):
    """How long two decoded recordings (16-bit samples) start with the same sound, in seconds.
    A frame is the same when what differs between the recordings is under `tolerance` of its loudness.
    MP3 decoding leaves a few percent of noise on identical audio; different speech differs by far more."""
    size = sample_rate * frame_ms // 1000
    frames = 0
    for start in range(0, min(len(first), len(second)) - size + 1, size):
        loud = sum(v * v for v in first[start:start + size])
        diff = sum((first[start + i] - second[start + i]) ** 2 for i in range(size))
        if loud == 0 or (diff / loud) ** 0.5 >= tolerance:
            break
        frames += 1
    return frames * frame_ms / 1000


def _decode(path, seconds=30, sample_rate=8000):
    import array
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-t', str(seconds), '-ac', '1',
                          '-ar', str(sample_rate), '-f', 's16le', '-'], capture_output=True, check=True).stdout
    samples = array.array('h')
    samples.frombytes(raw[:len(raw) // 2 * 2])
    return samples


def _page_text(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 spoken-margins-sharing-kit'})
    import html
    page = urllib.request.urlopen(request, timeout=60).read().decode('utf-8', 'replace')
    title = re.search(r'<title>(.*?)</title>', page, re.S)
    body = re.sub(r'(?is)<(script|style).*?</\1>', '', page)
    text = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', body)))
    return (html.unescape(title.group(1)).strip() if title else ''), text


def verify_content(kit, work, fetch=download, page_text=_page_text, log=print):
    """Re-checks every claim kit.json and the procedure make about the public content. Returns the problems."""
    problems = []
    work = Path(work)
    audio_dir = work / 'audio'
    paths = {}
    try:
        paths = fetch_audio(kit, audio_dir, fetch)
    except KitError as error:
        problems.append(str(error))
    for key, path in paths.items():
        item = kit['items'][key]
        if path.stat().st_size != item['audio']['bytes']:
            problems.append(f'{key}: {path.stat().st_size} bytes, kit.json says {item["audio"]["bytes"]}')
        if subprocess.run(['which', 'ffprobe'], capture_output=True).returncode == 0:
            seconds = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                            str(path)], capture_output=True, text=True).stdout)
            if abs(seconds * 1000 - item['identity']['durationMs']) > 50:
                problems.append(f"{key}: lasts {seconds * 1000:.0f} ms, kit.json says {item['identity']['durationMs']} ms")
        title, text = page_text(item['source']['page'])
        if 'CC-BY-SA' not in text and 'CC BY-SA' not in text:
            problems.append(f"{key}: the episode page no longer says CC BY-SA")
        if f"Hosted by {item['source']['host']}" not in text:
            problems.append(f"{key}: the episode page no longer names {item['source']['host']} as host")
        log(f'{key}: audio, length, license and host checked')
    podcasts = [k for k, v in kit['items'].items() if v['kind'] == 'podcast']
    if len(podcasts) >= 2 and all(k in paths for k in podcasts) and subprocess.run(['which', 'ffmpeg'], capture_output=True).returncode == 0:
        first = _decode(paths[podcasts[0]])
        for other in podcasts[1:]:
            seconds = shared_prefix_seconds(first, _decode(paths[other]))
            declared = kit['items'][other]['audio']['sharedIntroSeconds']
            log(f'{podcasts[0]} and {other} start with the same {seconds:.1f} s of sound')
            if abs(seconds - declared) > 1.0:
                problems.append(f'{other}: shares {seconds:.1f} s of intro with {podcasts[0]}, kit.json says {declared} s')
    for key, item in kit['items'].items():
        if item['kind'] != 'article':
            continue
        title, text = page_text(item['source']['page'])
        if title != item['source']['pageTitle']:
            problems.append(f"{key}: the page is now titled {title!r}")
        for packet in kit['packets']:
            if packet['item'] != key:
                continue
            for margin in packet['margins']:
                count = text.count(margin['quote'])
                if count != 1:
                    problems.append(f"{packet['file']}/{margin['id']}: the quote appears {count} times on the page, it must be once")
        log(f'{key}: title and quotes checked')
    return problems


# --- command line --------------------------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('lint')
    for name in ('plans', 'verify-content', 'build', 'stage'):
        sub = commands.add_parser(name)
        sub.add_argument('--work', default=str(DEFAULT_WORK), help='scratch folder (default: artifacts/sharing-kit, git-ignored)')
    packets_cmd = commands.add_parser('lint-packets')
    packets_cmd.add_argument('files', nargs='+')
    args = parser.parse_args(argv)
    kit = load_kit()
    try:
        if args.command == 'lint':
            problems = lint(kit)
        elif args.command == 'plans':
            for path in write_plans(kit, args.work):
                print(path)
            problems = []
        elif args.command == 'verify-content':
            problems = verify_content(kit, args.work)
        elif args.command == 'build':
            problems = lint(kit)
            if not problems:
                for packet in build(kit, args.work):
                    print(packet)
        elif args.command == 'stage':
            for packet in stage(args.work):
                print(packet)
            problems = []
        else:
            problems = [p for f in args.files for p in lint_packet(f, kit)]
    except (KitError, subprocess.CalledProcessError) as error:
        print(f'sharing_kit: {error}', file=sys.stderr)
        return 1
    for problem in problems:
        print(f'sharing_kit: {problem}', file=sys.stderr)
    if not problems:
        print('ok')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
