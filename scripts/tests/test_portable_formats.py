"""The portable formats' reference reader (Contracts/tools/spoken_margins_format.py, #1386).

The packets these tests read were written by the app's own Swift writer (coop-packet) or derived from those
by the reference writer; Contracts/examples/packets/expectations.json records what the shipped Swift readers
(this build's and Build 29's) did with each one.
"""
import contextlib
import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / 'Contracts' / 'examples' / 'packets'
KIT_PACKETS = ROOT / 'docs' / 'sharing-test-kit' / 'packets'
READER_PATH = ROOT / 'Contracts' / 'tools' / 'spoken_margins_format.py'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, module)
    spec.loader.exec_module(module)
    return module


fmt = load('spoken_margins_format', READER_PATH)
contracts = load('validate_contracts_portable', ROOT / 'scripts' / 'validate-contracts.py')


def example(name):
    return fmt.unpack((EXAMPLES / name).read_bytes())


def verdict(data):
    report = fmt.read_packet(data)
    return 'valid' if not report.errors else report.errors[0].code


SALT_32 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='   # 32 bytes, the size the sketch builder writes
HASH = 'a' * 32


def with_signature(manifest, assets, asset_id='sig'):
    """The packet's manifest and assets with one acoustic signature a fingerprint landmark can name."""
    manifest = json.loads(json.dumps(manifest))
    path = f'assets/evidence/{asset_id}.shazamsignature'
    manifest['assets'] = [*manifest['assets'], {
        'id': asset_id, 'role': fmt.ROLE_SIGNATURE, 'path': path, 'mimeType': fmt.SIGNATURE_MIME_TYPE,
        'durationMs': 10_000, 'anchorOffsetMs': 0, 'provenance': 'observed_decoded_playback'}]
    return manifest, {**assets, path: b'signature'}


def message_of(data):
    report = fmt.read_packet(data)
    return report.errors[0].message if report.errors else ''


class ShippedPacketTests(unittest.TestCase):
    def test_packets_written_by_the_app_read_as_valid(self):
        packets = sorted(KIT_PACKETS.glob('*.spokenmargins')) + [EXAMPLES / 'article-reference.spokenmargins',
                                                                  EXAMPLES / 'podcast-reference.spokenmargins']
        self.assertGreaterEqual(len(packets), 6)
        for path in packets:
            with self.subTest(path.name):
                report = fmt.read_packet(path)
                self.assertEqual(report.errors, [])
                self.assertTrue(report.summary['margins'])

    def test_the_reference_writer_reproduces_the_swift_digest(self):
        for path in sorted(KIT_PACKETS.glob('*.spokenmargins')) + [EXAMPLES / 'podcast-reference.spokenmargins']:
            with self.subTest(path.name):
                manifest, artifacts, assets = fmt.unpack(path.read_bytes())
                rewritten = fmt.unpack(fmt.write_packet(manifest, artifacts, assets))[0]
                self.assertEqual(rewritten['contentDigest'], manifest['contentDigest'])

    def test_every_example_matches_what_the_shipped_readers_did(self):
        expectations = json.loads((EXAMPLES / 'expectations.json').read_text())['packets']
        self.assertEqual({p.name for p in EXAMPLES.glob('*.spokenmargins')}, set(expectations))
        for name, expected in expectations.items():
            with self.subTest(name):
                self.assertEqual(verdict((EXAMPLES / name).read_bytes()), expected['reference'])
                self.assertEqual(expected['swift'].startswith('imports'), expected['reference'] == 'valid')

    def test_the_committed_corpus_is_what_the_generator_writes(self):
        self.assertEqual(contracts.portable_format_problems(), [])

    def test_a_summary_reports_position_and_text(self):
        report = fmt.read_packet(EXAMPLES / 'podcast-reference.spokenmargins')
        times = [m.get('mediaTimeMs') for m in report.summary['margins']]
        self.assertEqual(times, [65000, 600000])
        self.assertEqual(report.summary['transport'], 'reference')


class BothDirectionsTests(unittest.TestCase):
    """Old packets open in the new reader, and what a new writer may add stays readable by old readers."""

    def setUp(self):
        self.manifest, self.artifacts, self.assets = example('podcast-reference.spokenmargins')
        self.layer_path = 'artifacts/commentary-layer.json'

    def packet(self, **changes):
        return fmt.write_packet(self.manifest, self.artifacts, self.assets, **changes)

    def layer(self):
        return json.loads(self.artifacts[self.layer_path])

    def set_layer(self, layer):
        self.artifacts[self.layer_path] = fmt.encode_manifest(layer)

    def test_optional_fields_left_out_or_null_read_the_same(self):
        for key in ('senderDisplayLabel', 'suggestedRevealMode'):
            with self.subTest(left_out=key):
                manifest = dict(self.manifest)
                manifest.pop(key)
                self.assertEqual(verdict(fmt.write_packet(manifest, self.artifacts, self.assets)), 'valid')
        self.manifest['item']['author'] = None
        self.assertEqual(verdict(self.packet()), 'valid')

    def test_a_null_optional_is_left_out_of_the_digest(self):
        plain = fmt.unpack(self.packet())[0]['contentDigest']
        self.manifest['item']['author'] = None
        self.assertEqual(fmt.unpack(self.packet())[0]['contentDigest'], plain)

    def test_dates_with_and_without_fractional_seconds(self):
        for created in ('2026-10-09T12:00:00Z', '2026-10-09T12:00:00.000Z', '2026-10-09T07:00:00-05:00'):
            with self.subTest(created):
                self.manifest['createdAt'] = created
                self.assertEqual(verdict(self.packet()), 'valid')
        self.manifest['createdAt'] = 'October 9'
        self.assertEqual(verdict(self.packet()), 'invalid-manifest')

    def test_every_date_field_decodes_as_a_date(self):
        """Claude audit on 746d96f: the package decoder reads every Date as an ISO-8601 string and refuses the packet
        on anything else, in a Margin and in the closed artifacts as in the manifest."""
        spine = {'id': 'spine', 'schemaVersion': fmt.FINGERPRINT_SPINE_VERSION, 'itemId': 'item',
                 'generatorVersion': 'test', 'landmarks': []}
        # Within the readers' sketch bounds (a 32-byte salt, the builder's widths), which this module doesn't model.
        sketch = {'id': 'sketch', 'schemaVersion': fmt.PHRASE_SKETCH_VERSION, 'itemId': 'item',
                  'saltBase64': 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=', 'normalizationVersion': 'v1',
                  'shingleWidth': 3, 'maximumHashesPerWindow': 24, 'windows': []}
        for label, kind, document in [('a Margin', None, None), ('a fingerprint spine', 'edition_fingerprint_spine',
                                                                  spine),
                                      ('a phrase sketch', 'transcript_phrase_sketch', sketch)]:
            for created, expected in [('2026-10-09T12:00:00Z', 'valid'), ('2026-10-09T12:00:00.250+02:00', 'valid'),
                                      ('October 9', 'invalid-manifest'), ('2026-10-09', 'invalid-manifest'),
                                      (None, 'invalid-manifest')]:
                with self.subTest(label, createdAt=created):
                    manifest, artifacts = json.loads(json.dumps(self.manifest)), dict(self.artifacts)
                    if kind is None:
                        layer = self.layer()
                        layer['interjections'][0]['createdAt'] = created
                        artifacts[self.layer_path] = fmt.encode_manifest(layer)
                    else:
                        path = f'artifacts/{document["id"]}.json'
                        manifest['artifacts'].append({'id': document['id'], 'kind': kind, 'path': path,
                                                      'required': False, 'schemaVersion': document['schemaVersion']})
                        artifacts[path] = fmt.encode_manifest({**document, 'createdAt': created})
                    self.assertEqual(verdict(fmt.write_packet(manifest, artifacts, self.assets)), expected)

    def test_a_very_repetitive_transcript_is_written_the_way_the_readers_accept(self):
        # Claude audit on f529489: deflate squeezes this past the 100x ratio every shipped reader refuses, so the
        # Swift writer stores such an entry uncompressed, and stores every asset uncompressed.
        layer = self.layer()
        layer['interjections'][0]['representations'][0]['approvedTranscript'] = 'ha ' * 16_000
        self.set_layer(layer)
        self.manifest['assets'].append({'id': 'asset-voice', 'mimeType': 'audio/mp4', 'path': 'assets/audio/voice.m4a',
                                        'provenance': 'sender_approved_original', 'role': 'original_voice'})
        self.assets['assets/audio/voice.m4a'] = b'\0\0\0\x18ftypM4A ' + b'\0' * 4096
        packet = self.packet()
        self.assertEqual(verdict(packet), 'valid')
        with zipfile.ZipFile(io.BytesIO(packet)) as archive:
            infos = archive.infolist()
        methods = {info.filename: info.compress_type for info in infos}
        for info in infos:
            self.assertLessEqual(info.file_size // max(1, info.compress_size), fmt.MAX_COMPRESSION_RATIO, info.filename)
        self.assertEqual(methods['preview.md'], zipfile.ZIP_STORED)
        self.assertEqual(methods['assets/audio/voice.m4a'], zipfile.ZIP_STORED)
        self.assertEqual(methods['manifest.json'], zipfile.ZIP_DEFLATED)

    def test_unknown_optional_artifacts_are_skipped_and_required_ones_refused(self):
        for kind, version, required, expected in [
            ('listening_map_proposal', 'spoken-margins.listening-map-proposal.v3', False, 'valid'),
            ('listening_map_proposal', 'spoken-margins.listening-map-proposal.v3', True, 'unsupported-schema'),
            ('conversation', 'spoken-margins.margin-conversation.v2', False, 'valid'),
            ('embedded_text_item', 'spoken-margins.embedded-text-item.v2', False, 'unsupported-schema'),
            ('future_kind', 'x.v1', False, 'valid'),
            ('future_kind', 'x.v1', True, 'unsupported-capability'),
        ]:
            with self.subTest(kind=kind, version=version, required=required):
                manifest = json.loads(json.dumps(self.manifest))
                manifest['artifacts'].append({'id': 'extra', 'kind': kind, 'path': 'artifacts/extra.json',
                                              'required': required, 'schemaVersion': version})
                artifacts = {**self.artifacts, 'artifacts/extra.json': b'{"id":"extra"}'}
                self.assertEqual(verdict(fmt.write_packet(manifest, artifacts, self.assets)), expected)

    def test_unknown_keys_refused_in_the_manifest_ignored_in_the_layer(self):
        for where in ('item', 'itemTransport', 'redactions'):
            with self.subTest(where):
                manifest = json.loads(json.dumps(self.manifest))
                manifest[where]['newKey'] = 1
                self.assertEqual(verdict(fmt.write_packet(manifest, self.artifacts, self.assets)), 'unknown-field')
        layer = self.layer()
        layer['newLayerKey'] = 1
        layer['interjections'][0]['representations'][0]['newRepresentationKey'] = 1
        self.set_layer(layer)
        report = fmt.read_packet(self.packet())
        self.assertEqual(report.errors, [])
        self.assertEqual({w.code for w in report.warnings}, {'ignored-field'})

    def test_reply_links_are_closed_like_the_manifest(self):
        layer = self.layer()
        scoped = layer['interjections'][0]['packageScopedId']
        reply = {'packageScopedId': scoped, 'conversationId': 'thread-1', 'parentPackageDigest': 'a' * 64,
                 'parentPackageScopedId': 'parent-1'}
        for extra, expected in (({}, 'valid'), ({'newReplyKey': 1}, 'unknown-field'),
                                ({'packageScopedId': 'nobody'}, 'invalid-manifest'),
                                ({'parentPackageDigest': 'not-a-digest'}, 'invalid-manifest')):
            with self.subTest(extra=extra):
                manifest = json.loads(json.dumps(self.manifest))
                manifest['artifacts'].append({'id': 'conversation', 'kind': 'conversation', 'required': False,
                                              'path': 'artifacts/conversation.json',
                                              'schemaVersion': fmt.CONVERSATION_VERSION})
                body = {'id': 'conversation', 'schemaVersion': fmt.CONVERSATION_VERSION, 'replies': [{**reply, **extra}]}
                artifacts = {**self.artifacts, 'artifacts/conversation.json': fmt.encode_manifest(body)}
                self.assertEqual(verdict(fmt.write_packet(manifest, artifacts, self.assets)), expected)

    def test_an_unknown_representation_kind_is_refused(self):
        layer = self.layer()
        layer['interjections'][0]['representations'][0]['kind'] = 'hologram_and_text'
        self.set_layer(layer)
        self.assertEqual(verdict(self.packet()), 'invalid-manifest')


class RefusalTests(unittest.TestCase):
    def setUp(self):
        self.manifest, self.artifacts, self.assets = example('podcast-reference.spokenmargins')
        self.good = fmt.write_packet(self.manifest, self.artifacts, self.assets)

    def rezip(self, entries):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, body in entries:
                archive.writestr(name, body)
        return buffer.getvalue()

    def entries(self):
        with zipfile.ZipFile(io.BytesIO(self.good)) as archive:
            return [(info.filename, archive.read(info)) for info in archive.infolist()]

    def test_container_faults(self):
        entries = self.entries()
        cases = {
            'not a zip': (b'plain text', 'malformed-archive'),
            'no manifest': (self.rezip([e for e in entries if e[0] != 'manifest.json']), 'manifest-missing'),
            'undeclared file': (self.rezip(entries + [('artifacts/extra.json', b'{}')]), 'entries-mismatch'),
            'absolute path': (self.rezip(entries + [('/etc/passwd', b'x')]), 'unsafe-entry'),
            'backslash': (self.rezip(entries + [('artifacts\\x.json', b'{}')]), 'unsafe-entry'),
            'wrong extension': (self.rezip(entries + [('assets/audio/x.mp3', b'x')]), 'unsafe-entry'),
            'directory entry': (self.rezip(entries + [('artifacts/', b'')]), 'unsafe-entry'),
            'zip bomb': (self.rezip(entries + [('artifacts/zeros.json', b' ' * 600_000)]), 'excessive-compression'),
            'manifest not JSON': (self.rezip([('manifest.json', b'{')] + entries[1:]), 'invalid-manifest'),
        }
        for label, (data, expected) in cases.items():
            with self.subTest(label):
                self.assertEqual(verdict(data), expected)

    def test_duplicate_entries(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive, contextlib.redirect_stderr(io.StringIO()):
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                for name, body in self.entries() + [('preview.md', b'again')]:
                    archive.writestr(name, body)
        self.assertEqual(verdict(buffer.getvalue()), 'duplicate-entry')

    def test_the_preview_must_match(self):
        self.assertEqual(verdict(fmt.write_packet(self.manifest, self.artifacts, self.assets,
                                                  preview=b'# Something else\n')), 'preview-mismatch')

    def test_a_changed_digest_is_refused(self):
        entries = self.entries()
        manifest = json.loads(entries[0][1])
        manifest['contentDigest'] = '0' * 64
        self.assertEqual(verdict(self.rezip([('manifest.json', fmt.encode_manifest(manifest))] + entries[1:])),
                         'digest-mismatch')

    def test_descriptor_collisions(self):
        for ids in (['voice/a', 'voice?a'], ['Voice', 'voice'], ['same', 'same']):
            with self.subTest(ids):
                manifest = json.loads(json.dumps(self.manifest))
                assets = {}
                for index, asset_id in enumerate(ids):
                    path = f'assets/audio/v{index}.m4a'
                    manifest['assets'].append({'id': asset_id, 'mimeType': 'audio/mp4', 'path': path,
                                               'provenance': 'sender_approved_original', 'role': 'original_voice'})
                    assets[path] = b'\0\0\0\x18ftypM4A ' + bytes(16)
                self.assertEqual(verdict(fmt.write_packet(manifest, self.artifacts, assets)), 'invalid-manifest')

    def test_transport_rules(self):
        cases = [
            ('reference without a link', lambda m: m['item'].pop('canonicalURL'), 'transport-inconsistent'),
            ('recipient supplied with a link', lambda m: m['itemTransport'].update(kind='recipient_supplied'),
             'transport-inconsistent'),
            ('reference with a rights basis', lambda m: m['itemTransport'].update(rightsBasis='app_authored'),
             'transport-inconsistent'),
            ('podcast as embedded text', lambda m: (m['item'].pop('canonicalURL'), m['itemTransport'].update(
                kind='embedded_text', rightsBasis='app_authored', embeddedArtifactId='x'),
                m['redactions'].update(fullItemOmitted=False)), 'transport-inconsistent'),
            ('unknown transport', lambda m: m['itemTransport'].update(kind='carrier_pigeon'), 'invalid-manifest'),
        ]
        for label, change, expected in cases:
            with self.subTest(label):
                manifest = json.loads(json.dumps(self.manifest))
                change(manifest)
                self.assertEqual(verdict(fmt.write_packet(manifest, self.artifacts, self.assets)), expected)

    def test_margin_bounds(self):
        layer = json.loads(self.artifacts['artifacts/commentary-layer.json'])
        margin = layer['interjections'][0]
        cases = [
            ('too many Margins', lambda l: l.update(interjections=[
                {**margin, 'packageScopedId': f'm{i}'} for i in range(51)])),
            ('no Margins', lambda l: l.update(interjections=[])),
            ('same id twice', lambda l: l['interjections'].append(dict(margin))),
            ('negative time', lambda l: l['interjections'][0]['anchor'].update(mediaTimeMs=-1)),
            ('percent over 100', lambda l: l['interjections'][0]['anchor'].update(roughPercent=101)),
            ('end before start', lambda l: l['interjections'][0]['anchor'].update(startChar=5, endChar=4)),
            ('quote too long', lambda l: l['interjections'][0]['anchor'].update(exactText='x' * 1001)),
            ('blank transcript', lambda l: l['interjections'][0]['representations'][0].update(approvedTranscript=' ')),
            ('text that names audio', lambda l: l['interjections'][0]['representations'][0].update(assetId='a')),
            ('audio with no voice', lambda l: l['interjections'][0]['representations'][0].update(
                kind='original_audio_and_text', provenance='sender_approved_original')),
            ('missing default', lambda l: l['interjections'][0].update(defaultRepresentationId='nope')),
            ('evidence that is not a signature', lambda l: l['interjections'][0]['anchor'].update(
                machineEvidenceAssetIds=['nope'])),
            ('a createdAt that is not a date', lambda l: l['interjections'][0].update(createdAt='October 9')),
        ]
        for label, change in cases:
            with self.subTest(label):
                edited = json.loads(json.dumps(layer))
                change(edited)
                artifacts = {**self.artifacts, 'artifacts/commentary-layer.json': fmt.encode_manifest(edited)}
                self.assertEqual(verdict(fmt.write_packet(self.manifest, artifacts, self.assets)), 'invalid-manifest')

    def test_embedded_edition_must_match(self):
        base = fmt.unpack((EXAMPLES / 'article-embedded-text.spokenmargins').read_bytes())
        self.assertEqual(verdict(fmt.write_packet(*base)), 'valid')
        for label, change, expected in [
            ('another edition', lambda m, a: m['item'].update(exactEditionSHA256='a' * 64), 'edition-mismatch'),
            ('normalized hash', lambda m, a: m['item'].update(normalizedContentSHA256='a' * 64), 'edition-mismatch'),
            ('media type', lambda m, a: a.update({'artifacts/embedded-item.json': fmt.encode_manifest(
                {**json.loads(a['artifacts/embedded-item.json']), 'originalMediaType': 'text/plain'})}),
             'transport-inconsistent'),
        ]:
            with self.subTest(label):
                manifest, artifacts, assets = json.loads(json.dumps(base[0])), dict(base[1]), dict(base[2])
                change(manifest, artifacts)
                self.assertEqual(verdict(fmt.write_packet(manifest, artifacts, assets)), expected)


class SpineAndSketchBoundsTests(unittest.TestCase):
    """#1856: the limits the Swift reader enforces inside a fingerprint spine and a phrase sketch. One row per rule
    that fails, named in the message; one row per limit exactly at its edge that stays valid. Both shipped readers
    (this build's and Build 29's frozen copy) hold the same rules, so none of these is an `older-reader-refuses`."""

    DATE = '2026-10-17T12:00:00Z'

    def landmark(self, order=0, **changes):
        return {'id': f'l{order}', 'order': order, 'sourceMediaStartMs': 0, 'sourceMediaEndMs': 10,
                'anchorMediaTimeMs': 5, 'continuityEpoch': 0, 'trigger': 'initial_playback',
                'provenance': 'observed_decoded_playback', 'signatureAssetId': 'sig', 'generatorVersion': 'g',
                **changes}

    def spine(self, landmarks=None, **changes):
        return {'id': 'spine', 'itemId': 'item', 'createdAt': self.DATE, 'generatorVersion': 'g',
                'landmarks': [self.landmark()] if landmarks is None else landmarks, **changes}

    def sketch(self, windows=None, **changes):
        return {'id': 'sketch', 'itemId': 'item', 'saltBase64': SALT_32, 'normalizationVersion': 'v1',
                'shingleWidth': 3, 'maximumHashesPerWindow': 24, 'createdAt': self.DATE,
                'windows': [self.window()] if windows is None else windows, **changes}

    def window(self, index=0, **changes):
        return {'id': f'w{index}', 'sourceStartMs': 0, 'sourceEndMs': 10, 'hashes': [HASH], **changes}

    def packet(self, kind, document):
        # An article, so a spine's episodeGUID has no podcast GUID to disagree with.
        manifest, artifacts, assets = example('article-reference.spokenmargins')
        manifest, assets = with_signature(manifest, assets)
        path = f'artifacts/{kind}.json'
        version = fmt.ARTIFACT_VERSIONS[kind]
        manifest['artifacts'].append({'id': document['id'], 'kind': kind, 'path': path, 'required': False,
                                      'schemaVersion': version})
        artifacts = {**artifacts, path: fmt.encode_manifest({**document, 'schemaVersion': version})}
        return fmt.write_packet(manifest, artifacts, assets)

    def run_rows(self, kind, rows):
        for label, document, rule in rows:
            with self.subTest(label):
                data = self.packet(kind, document)
                if rule is None:
                    self.assertEqual(verdict(data), 'valid', message_of(data))
                else:
                    self.assertEqual(verdict(data), 'invalid-manifest')
                    self.assertIn(f': {rule}', message_of(data))

    def test_a_valid_spine_and_sketch_read_as_valid(self):
        self.run_rows('edition_fingerprint_spine', [('spine', self.spine(), None)])
        self.run_rows('transcript_phrase_sketch', [('sketch', self.sketch(), None)])

    def test_spine_rules(self):
        many = [self.landmark(i, id=f'l{i}') for i in range(501)]
        self.run_rows('edition_fingerprint_spine', [
            ('item_id empty', self.spine(itemId=''), 'item_id'),
            ('item_id 501', self.spine(itemId='x' * 501), 'item_id'),
            ('item_id 500', self.spine(itemId='x' * 500), None),
            ('landmark_count 501', self.spine(many), 'landmark_count'),
            ('landmark_count 500', self.spine(many[:500]), None),
            ('generator_version 201', self.spine(generatorVersion='g' * 201), 'generator_version'),
            ('generator_version 200', self.spine(generatorVersion='g' * 200), None),
            ('canonical_url http', self.spine(canonicalURL='http://example.com/a'), 'canonical_url'),
            ('canonical_url with a password', self.spine(canonicalURL='https://u:p@example.com/a'), 'canonical_url'),
            ('canonical_url https', self.spine(canonicalURL='https://example.com/a'), None),
            ('episode_guid 1001', self.spine(episodeGUID='g' * 1001), 'episode_guid'),
            ('episode_guid 1000', self.spine(episodeGUID='g' * 1000), None),
            ('duration negative', self.spine(producingEditionDurationMs=-1), 'duration'),
            ('duration zero', self.spine(producingEditionDurationMs=0), None),
            ('edition_sha256 upper case', self.spine(producingEditionSHA256='A' * 64), 'edition_sha256'),
            ('edition_sha256 short', self.spine(producingEditionSHA256='a' * 63), 'edition_sha256'),
            ('edition_sha256 lower case', self.spine(producingEditionSHA256='a' * 64), None),
            ('landmark_ids repeated', self.spine([self.landmark(0), self.landmark(1, id='l0')]), 'landmark_ids'),
            ('landmark_order starts at 1', self.spine([self.landmark(1)]), 'landmark_order'),
            ('landmark_order skips', self.spine([self.landmark(0), self.landmark(2)]), 'landmark_order'),
            ('landmark_order out of order', self.spine([self.landmark(1), self.landmark(0)]), 'landmark_order'),
        ])

    def test_the_spine_names_the_items_episode_by_canonical_equivalence(self):
        """Swift compares strings by canonical equivalence: an NFC and an NFD spelling of one GUID are the same."""
        manifest, artifacts, assets = example('podcast-reference.spokenmargins')
        manifest, assets = with_signature(manifest, assets)
        manifest['item']['episodeGUID'] = 'caf\u00e9-1'
        document = self.spine(episodeGUID='cafe\u0301-1')
        path, version = 'artifacts/spine.json', fmt.ARTIFACT_VERSIONS['edition_fingerprint_spine']
        manifest['artifacts'].append({'id': 'spine', 'kind': 'edition_fingerprint_spine', 'path': path,
                                      'required': False, 'schemaVersion': version})
        artifacts = {**artifacts, path: fmt.encode_manifest({**document, 'schemaVersion': version})}
        self.assertEqual(verdict(fmt.write_packet(manifest, artifacts, assets)), 'valid')
        artifacts[path] = fmt.encode_manifest({**self.spine(episodeGUID='other'), 'schemaVersion': version})
        self.assertEqual(verdict(fmt.write_packet(manifest, artifacts, assets)), 'edition-mismatch')

    def test_the_first_failed_spine_rule_is_the_one_named(self):
        data = self.packet('edition_fingerprint_spine', self.spine(itemId='', generatorVersion='g' * 201))
        self.assertIn(': item_id', message_of(data))

    def test_landmark_rules(self):
        self.run_rows('edition_fingerprint_spine', [(label, self.spine([self.landmark(**change)]), rule) for label, change, rule in [
            ('source start negative', {'sourceMediaStartMs': -1}, 'source_range'),
            ('source end before start', {'sourceMediaStartMs': 5, 'sourceMediaEndMs': 4}, 'source_range'),
            ('source end equals start', {'sourceMediaStartMs': 5, 'sourceMediaEndMs': 5}, None),
            ('span 30001', {'sourceMediaEndMs': 30_001}, 'duration'),
            ('span 30000', {'sourceMediaEndMs': 30_000}, None),
            ('anchor time negative', {'anchorMediaTimeMs': -1}, 'anchor_time'),
            ('continuity epoch negative', {'continuityEpoch': -1}, 'continuity_epoch'),
            ('generator 201', {'generatorVersion': 'g' * 201}, 'generator_version'),
            ('generator 200', {'generatorVersion': 'g' * 200}, None),
            ('signature names no asset', {'signatureAssetId': 'nope'}, 'signature_asset'),
        ]])

    def test_sketch_rules(self):
        many = [self.window(i) for i in range(10_001)]
        self.run_rows('transcript_phrase_sketch', [
            ('item_id empty', self.sketch(itemId=''), 'item_id'),
            ('item_id 501', self.sketch(itemId='x' * 501), 'item_id'),
            ('item_id 500', self.sketch(itemId='x' * 500), None),
            ('normalization_version 201', self.sketch(normalizationVersion='v' * 201), 'normalization_version'),
            ('normalization_version 200', self.sketch(normalizationVersion='v' * 200), None),
            ('shingle_width 2', self.sketch(shingleWidth=2), 'shingle_width'),
            ('maximum_hashes 23', self.sketch(maximumHashesPerWindow=23), 'maximum_hashes'),
            ('salt 31 bytes', self.sketch(saltBase64='AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg=='), 'salt'),
            ('salt 33 bytes', self.sketch(saltBase64='AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g'), 'salt'),
            ('salt not base64', self.sketch(saltBase64='not base64!'), 'salt'),
            ('salt unpadded', self.sketch(saltBase64='AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8'), 'salt'),
            ('window_count 10001', self.sketch(many), 'window_count'),
            ('window_count 10000', self.sketch(many[:10_000]), None),
            ('window_ids repeated', self.sketch([self.window(0), self.window(1, id='w0')]), 'window_ids'),
        ])

    def test_window_rules(self):
        self.run_rows('transcript_phrase_sketch', [(label, self.sketch([self.window(**change)]), rule) for label, change, rule in [
            ('start negative', {'sourceStartMs': -1}, 'start'),
            ('end before start', {'sourceStartMs': 5, 'sourceEndMs': 4}, 'range'),
            ('end equals start', {'sourceStartMs': 5, 'sourceEndMs': 5}, None),
            ('span 30001', {'sourceEndMs': 30_001}, 'span'),
            ('span 30000', {'sourceEndMs': 30_000}, None),
            ('25 hashes', {'hashes': [HASH] * 25}, 'hash_count'),
            ('24 hashes', {'hashes': [HASH] * 24}, None),
            ('no hashes', {'hashes': []}, None),
            ('hash 31 characters', {'hashes': ['a' * 31]}, 'hash_form'),
            ('hash 33 characters', {'hashes': ['a' * 33]}, 'hash_form'),
            ('hash upper case', {'hashes': ['A' * 32]}, 'hash_form'),
            ('hash not hex', {'hashes': ['g' * 32]}, 'hash_form'),
            ('hash with digits and a-f', {'hashes': ['0123456789abcdef' * 2]}, None),
        ]])

    def test_the_rules_run_in_swift_order(self):
        """A landmark is read only after the spine's own rules held; a window only after the sketch's."""
        bad_landmark = self.landmark(sourceMediaStartMs=-1)
        data = self.packet('edition_fingerprint_spine', self.spine([bad_landmark], itemId=''))
        self.assertIn(': item_id', message_of(data))
        data = self.packet('transcript_phrase_sketch', self.sketch([self.window(sourceStartMs=-1)], shingleWidth=2))
        self.assertIn(': shingle_width', message_of(data))


class ListeningMapProposalTests(unittest.TestCase):
    """Claude audit on f529489: the reader passes proposals through PortableListeningMapContract.forSharing before
    it checks them, so a proposal that breaks a scene rule is left out, not a reason to refuse the Margins."""

    QUOTE = 'the quick brown fox jumps over the lazy dog every single morning before breakfast'

    def setUp(self):
        self.manifest, self.artifacts, self.assets = example('podcast-reference.spokenmargins')

    @staticmethod
    def media(ms, **extra):
        return {'anchorType': 'media', 'mediaTimeMs': ms, 'machineEvidenceAssetIds': [], **extra}

    def scenes(self):
        return [
            {'id': 's0', 'order': 0, 'eligibility': 'excluded', 'startAnchor': self.media(0),
             'endAnchor': self.media(60_000)},
            {'id': 's1', 'order': 1, 'eligibility': 'eligible', 'summaryText': 'A summary written for this test.',
             'summaryProvenance': 'sender_authored', 'startAnchor': self.media(60_000),
             'endAnchor': self.media(600_000)},
        ]

    def read(self, scenes, assets=(), created='2026-10-17T12:00:00Z'):
        manifest = json.loads(json.dumps(self.manifest))
        manifest['assets'] += list(assets)
        manifest['artifacts'].append({'id': 'map', 'kind': 'listening_map_proposal', 'path': 'artifacts/map.json',
                                      'required': False, 'schemaVersion': fmt.LISTENING_MAP_PROPOSAL_VERSION})
        proposal = {'id': 'map', 'schemaVersion': fmt.LISTENING_MAP_PROPOSAL_VERSION,
                    'createdAt': created, 'generator': 'test', 'scenes': scenes}
        artifacts = {**self.artifacts, 'artifacts/map.json': fmt.encode_manifest(proposal)}
        assets_bytes = {**self.assets, **{a['path']: b'\0\0\0\x18ftypM4A ' + b'\0' * 64 for a in assets}}
        return fmt.read_packet(fmt.write_packet(manifest, artifacts, assets_bytes))

    def outcome(self, scenes, assets=(), created='2026-10-17T12:00:00Z'):
        report = self.read(scenes, assets, created)
        if report.errors:
            return report.errors[0].code
        return ' '.join(['valid'] + sorted({w.code for w in report.warnings}))

    def test_scene_rules_table(self):
        summary_voice = {'id': 'voice-summary', 'role': 'summary_voice', 'path': 'assets/audio/summary.m4a',
                         'mimeType': 'audio/mp4', 'provenance': 'sender_approved_summary'}
        original_voice = {**summary_voice, 'role': 'original_voice'}
        cases = [
            ('a clean proposal', lambda s: None, (), 'valid'),
            ('excluded scene names a missing summary asset', lambda s: s[0].update(summaryAssetId='nope'), (),
             'valid older-reader-refuses'),
            ('excluded scene names an original-voice asset', lambda s: s[0].update(summaryAssetId='voice-summary'),
             (original_voice,), 'valid older-reader-refuses'),
            ('excluded scene carries summary text', lambda s: s[0].update(summaryText='A note.',
                                                                         summaryProvenance='deterministic'), (), 'valid'),
            # The stand-in audio has an ftyp box, which is all this reader checks; the Swift reader decodes it.
            ('eligible scene names a summary voice', lambda s: s[1].update(summaryAssetId='voice-summary'),
             (summary_voice,), 'valid'),
            ('eligible scene names a missing summary asset', lambda s: s[1].update(summaryAssetId='nope'), (),
             'invalid-manifest'),
            ('eligible scene names an original-voice asset', lambda s: s[1].update(summaryAssetId='voice-summary'),
             (original_voice,), 'invalid-manifest'),
            ('eligible scene lacks summary text, order reversed',
             lambda s: (s[1].pop('summaryText'), s[0].update(order=1), s[1].update(order=0)), (),
             'valid older-reader-refuses proposal-dropped'),
            ('eligible scene has an empty summary', lambda s: s[1].update(summaryText=''), (),
             'valid older-reader-refuses proposal-dropped'),
            ('eligible scene lacks summary provenance', lambda s: s[1].pop('summaryProvenance'), (),
             'valid older-reader-refuses proposal-dropped'),
            ('order reversed, every scene rule kept', lambda s: (s[0].update(order=1), s[1].update(order=0)), (),
             'invalid-manifest'),
            ('orders start at 1', lambda s: (s[0].update(order=1), s[1].update(order=2)), (), 'invalid-manifest'),
            ('the same scene id twice', lambda s: s[1].update(id='s0'), (), 'invalid-manifest'),
            ('a title over 500 characters', lambda s: s[1].update(title='t' * 501), (), 'invalid-manifest'),
            ('a scene ends before it starts', lambda s: s[1].update(endAnchor=self.media(30_000)), (),
             'valid proposal-dropped'),
            ('scenes overlap', lambda s: s[1].update(startAnchor=self.media(30_000)), (), 'valid proposal-dropped'),
            ('a scene starts before an earlier one', lambda s: s[0].update(startAnchor=self.media(90_000),
                                                                          endAnchor=self.media(95_000)), (),
             'valid proposal-dropped'),
            ('scenes placed by rough percent only', lambda s: [x.update(startAnchor={'anchorType': 'media',
                                                                                      'roughPercent': 50,
                                                                                      'machineEvidenceAssetIds': []})
                                                               for x in s], (), 'valid'),
            ('a summary quoting its anchor', lambda s: s[1].update(summaryText=self.QUOTE, startAnchor=self.media(
                60_000, exactText=self.QUOTE)), (), 'valid proposal-dropped'),
            ('a summary quoting nine words', lambda s: s[1].update(summaryText=' '.join(self.QUOTE.split()[:9]),
                                                                    startAnchor=self.media(60_000, exactText=self.QUOTE)),
             (), 'valid'),
            ('a quoting title is dropped, a long one with it', lambda s: s[1].update(
                title=self.QUOTE + ' ' + 'x' * 501, startAnchor=self.media(60_000, exactText=self.QUOTE)), (),
             'valid older-reader-refuses'),
            ('a summary quoting non-ASCII text', lambda s: s[1].update(
                summaryText='caf\u00e9 ' + self.QUOTE, startAnchor=self.media(60_000, exactText='caf\u00e9 ' + self.QUOTE)),
             (), 'valid not-checked'),
            # Claude audit on 746d96f: a quotation needs ten words, so non-ASCII text that can't hold one leaves the
            # order rule exact; only a check that could find a quotation in text split differently is a guess.
            ('a non-ASCII title, order reversed', lambda s: (s[1].update(title='Caf\u00e9 talk'), s[0].update(order=1),
                                                             s[1].update(order=0)), (), 'invalid-manifest'),
            ('a decomposed accent in the title, order reversed', lambda s: (
                s[1].update(title='Cafe\u0301 talk'), s[0].update(order=1), s[1].update(order=0)), (),
             'invalid-manifest'),
            ('a curly apostrophe and an em dash in the summary, order reversed', lambda s: (
                s[1].update(summaryText='Don\u2019t skip it \u2014 the best part.'), s[0].update(order=1),
                s[1].update(order=0)), (), 'invalid-manifest'),
            ('a non-ASCII summary under ten words', lambda s: s[1].update(summaryText='Un r\u00e9sum\u00e9 \u00e9crit.'), (),
             'valid'),
            ('a non-ASCII anchor quote of ten words, nothing in the scene to quote it', lambda s: s[1].update(
                startAnchor=self.media(60_000, exactText='caf\u00e9 ' + self.QUOTE)), (), 'valid'),
            ('a long non-ASCII title and no 10-word source, order reversed', lambda s: (
                s[1].update(title='caf\u00e9 ' + self.QUOTE, startAnchor=self.media(60_000, exactText='a short quote')),
                s[0].update(order=1), s[1].update(order=0)), (), 'invalid-manifest'),
            ('a long non-ASCII title beside a long ASCII anchor, order reversed', lambda s: (
                s[1].update(title='caf\u00e9 ' + self.QUOTE, startAnchor=self.media(60_000, exactText=self.QUOTE)),
                s[0].update(order=1), s[1].update(order=0)), (), 'valid not-checked older-reader-refuses'),
            ('a long non-ASCII summary beside a long anchor, order reversed', lambda s: (
                s[1].update(summaryText='caf\u00e9 ' + self.QUOTE, startAnchor=self.media(
                    60_000, exactText='a different sentence of eleven words that shares no run at all')),
                s[0].update(order=1), s[1].update(order=0)), (), 'valid not-checked older-reader-refuses'),
            ('a scene that does not decode', lambda s: s[1].update(eligibility='maybe'), (), 'invalid-manifest'),
            ('a scene order that is text', lambda s: s[1].update(order='1'), (), 'invalid-manifest'),
            ('a scene that is not an object', lambda s: s.append('scene'), (), 'invalid-manifest'),
        ]
        for label, change, assets, expected in cases:
            with self.subTest(label):
                scenes = self.scenes()
                change(scenes)
                self.assertEqual(self.outcome(scenes, assets), expected)

    def test_a_proposal_created_at_must_be_a_date(self):
        """Claude audit on 746d96f: PortableListeningMapProposalArtifact.createdAt is a Date."""
        for created, expected in [('2026-10-17T12:00:00Z', 'valid'), ('2026-10-17T12:00:00.5Z', 'valid'),
                                  ('October 9', 'invalid-manifest'), ('', 'invalid-manifest'), (17, 'invalid-manifest')]:
            with self.subTest(created):
                self.assertEqual(self.outcome(self.scenes(), created=created), expected)

    def test_an_embedded_text_quotation_drops_the_proposal(self):
        base = fmt.unpack((EXAMPLES / 'article-embedded-text.spokenmargins').read_bytes())
        text = json.loads(base[1]['artifacts/embedded-item.json'])['text']
        self.manifest, self.artifacts, self.assets = json.loads(json.dumps(base[0])), dict(base[1]), dict(base[2])
        words = text.split()
        for label, summary, start, end, expected in [
            ('quotes its span', ' '.join(words[:12]), 0, len(text), 'valid proposal-dropped'),
            ('quotes outside its span', ' '.join(words[-12:]), 0, 40, 'valid'),
            ('span does not fit the text, so all of it counts', ' '.join(words[-12:]), 0, len(text) + 1,
             'valid proposal-dropped'),
        ]:
            with self.subTest(label):
                scenes = [{'id': 's0', 'order': 0, 'eligibility': 'eligible', 'summaryText': summary,
                           'summaryProvenance': 'sender_authored',
                           'startAnchor': {'anchorType': 'text', 'startChar': start, 'machineEvidenceAssetIds': []},
                           'endAnchor': {'anchorType': 'text', 'endChar': end, 'machineEvidenceAssetIds': []}}]
                self.assertEqual(self.outcome(scenes), expected)


class DecodeTests(unittest.TestCase):
    """Claude audit on 746d96f: a `createdAt` that isn't a date passed in a Margin and in a proposal. The class is a
    field whose Swift type the reader checked weaker than Swift decodes it, so every field of every Codable type is
    tried here, from the one table (fmt.SWIFT_TYPES) that decode_problem reads."""

    DATE = '2026-10-17T12:00:00Z'

    def sample(self, swift_type, owner=None):
        optional = swift_type.endswith('?')
        base = swift_type[:-1] if optional else swift_type
        if base.startswith('['):
            return [self.sample(base[1:-1], owner)]
        simple = {'String': 'x', 'Int': 1, 'Bool': True, 'Date': self.DATE}
        if base in simple:
            return simple[base]
        key = fmt._swift_type(base, owner)
        if key in fmt.SWIFT_ENUMS:
            return sorted(fmt.SWIFT_ENUMS[key])[0]
        return {name: self.sample(kind, key) for name, kind in fmt.SWIFT_TYPES[key].items()}

    WRONG = {
        'String': [5, True, [], {}], 'Int': ['5', 1.5, True, 2 ** 63, []], 'Bool': [1, 'true', []],
        'Date': ['October 9', 5, '2026-10-17', '2026-10-17T12:00:00', True],
    }

    def test_every_field_of_every_type_is_checked_as_swift_decodes_it(self):
        for type_name, fields in fmt.SWIFT_TYPES.items():
            self.assertIsNone(fmt.decode_problem(self.sample(type_name), type_name), type_name)
            for field, swift_type in fields.items():
                optional = swift_type.endswith('?')
                base = swift_type.rstrip('?')
                wrong = list(self.WRONG.get(base, []))
                if base.startswith('['):
                    wrong += ['x', 5, {}]
                elif base not in self.WRONG:
                    key = fmt._swift_type(base, type_name)
                    wrong += ['nope', 5, []] if key in fmt.SWIFT_ENUMS else ['x', 5, []]
                for label, value in [('missing', fmt.decode_problem), ('null', fmt.decode_problem)][:0]:
                    pass
                with self.subTest(type=type_name, field=field):
                    document = self.sample(type_name)
                    del document[field]
                    self.assertEqual(fmt.decode_problem(document, type_name) is None, optional, 'missing')
                    document[field] = None
                    self.assertEqual(fmt.decode_problem(document, type_name) is None, optional, 'null')
                    for value in wrong:
                        document[field] = value
                        self.assertIsNotNone(fmt.decode_problem(document, type_name), f'{value!r}')
                    document[field] = self.sample(swift_type, type_name)
                    self.assertIsNone(fmt.decode_problem(document, type_name))

    def test_every_swift_date_is_a_date_in_the_table(self):
        structs, _, _ = contracts.swift_declarations(contracts.SWIFT_SOURCES)
        for type_name, fields in fmt.SWIFT_TYPES.items():
            for field, swift_type in structs[type_name].items():
                if swift_type.rstrip('?') == 'Date':
                    self.assertEqual(fields[field], swift_type, f'{type_name}.{field}')

    def test_a_table_that_drifts_from_the_swift_structs_is_caught(self):
        self.assertEqual(contracts.codable_problems(fmt), [])
        drifted = load('spoken_margins_format_types', READER_PATH)
        drifted.SWIFT_TYPES = {**drifted.SWIFT_TYPES, 'EditionFingerprintSpineArtifact': {
            **drifted.SWIFT_TYPES['EditionFingerprintSpineArtifact'], 'createdAt': 'String'}}
        drifted.SWIFT_ENUMS = {**drifted.SWIFT_ENUMS, 'AnchorType': frozenset({'text'})}
        problems = contracts.codable_problems(drifted)
        self.assertTrue(any('EditionFingerprintSpineArtifact differs' in p and 'createdAt' in p for p in problems), problems)
        self.assertTrue(any('AnchorType values differ' in p for p in problems), problems)

    def packet_with(self, kind, document, required=False):
        manifest, artifacts, assets = example('podcast-reference.spokenmargins')
        manifest, assets = with_signature(manifest, assets)
        path = f'artifacts/{kind}.json'
        version = fmt.ARTIFACT_VERSIONS[kind]
        manifest['artifacts'].append({'id': document['id'], 'kind': kind, 'path': path, 'required': required,
                                      'schemaVersion': version})
        artifacts = {**artifacts, path: fmt.encode_manifest({**document, 'schemaVersion': version})}
        return fmt.write_packet(manifest, artifacts, assets)

    def test_a_date_that_is_not_a_date_refuses_the_packet_wherever_it_sits(self):
        spine = {'id': 'spine', 'itemId': 'i', 'createdAt': self.DATE, 'generatorVersion': 'g', 'landmarks': []}
        sketch = {'id': 'sketch', 'itemId': 'i', 'saltBase64': SALT_32, 'normalizationVersion': 'v', 'shingleWidth': 3,
                  'maximumHashesPerWindow': 24, 'createdAt': self.DATE, 'windows': []}
        for kind, document in [('edition_fingerprint_spine', spine), ('transcript_phrase_sketch', sketch)]:
            with self.subTest(kind):
                self.assertEqual(verdict(self.packet_with(kind, document)), 'valid')
                self.assertEqual(verdict(self.packet_with(kind, {**document, 'createdAt': 'October 9'})),
                                 'invalid-manifest')
                self.assertEqual(verdict(self.packet_with(kind, {**document, 'createdAt': None})), 'invalid-manifest')
        landmark = {'id': 'l', 'order': 0, 'sourceMediaStartMs': 0, 'sourceMediaEndMs': 10, 'anchorMediaTimeMs': 5,
                    'continuityEpoch': 0, 'trigger': 'initial_playback', 'provenance': 'observed_decoded_playback',
                    'signatureAssetId': 'sig', 'generatorVersion': 'g'}
        self.assertEqual(verdict(self.packet_with('edition_fingerprint_spine', {**spine, 'landmarks': [landmark]})), 'valid')
        for change in [{'trigger': 'sometimes'}, {'order': '0'}, {'signatureAssetId': None}]:
            with self.subTest(landmark=change):
                self.assertEqual(verdict(self.packet_with('edition_fingerprint_spine', {
                    **spine, 'landmarks': [{**landmark, **change}]})), 'invalid-manifest')

    def test_a_margin_and_a_proposal_need_a_real_date(self):
        manifest, artifacts, assets = example('podcast-reference.spokenmargins')
        path = 'artifacts/commentary-layer.json'
        layer = json.loads(artifacts[path])
        for value in ['October 9', '2026-10-17', 12, None]:
            with self.subTest(createdAt=value):
                changed = json.loads(json.dumps(layer))
                changed['interjections'][0]['createdAt'] = value
                packet = fmt.write_packet(manifest, {**artifacts, path: fmt.encode_manifest(changed)}, assets)
                self.assertEqual(verdict(packet), 'invalid-manifest')
        for value in ['2026-10-17T12:00:00Z', '2026-10-17T12:00:00.250+02:00']:
            with self.subTest(createdAt=value):
                changed = json.loads(json.dumps(layer))
                changed['interjections'][0]['createdAt'] = value
                packet = fmt.write_packet(manifest, {**artifacts, path: fmt.encode_manifest(changed)}, assets)
                self.assertEqual(verdict(packet), 'valid')

    def test_conversation_and_embedded_text_decode_like_swift(self):
        base = fmt.unpack((EXAMPLES / 'article-embedded-text.spokenmargins').read_bytes())
        embedded_path = 'artifacts/embedded-item.json'
        for change in [{'originalMediaType': None}, {'id': 7}]:
            with self.subTest(change):
                artifacts = {**base[1], embedded_path: fmt.encode_manifest({**json.loads(base[1][embedded_path]), **change})}
                self.assertIn(verdict(fmt.write_packet(base[0], artifacts, base[2])),
                              {'invalid-manifest', 'transport-inconsistent'})
        manifest, artifacts, assets = example('podcast-reference.spokenmargins')
        scoped = json.loads(artifacts['artifacts/commentary-layer.json'])['interjections'][0]['packageScopedId']
        reply = {'packageScopedId': scoped, 'conversationId': 'c', 'parentPackageDigest': 'a' * 64,
                 'parentPackageScopedId': 'p'}
        for change, expected in [({}, 'valid'), ({'conversationId': 5}, 'invalid-manifest'),
                                 ({'parentPackageDigest': None}, 'invalid-manifest')]:
            with self.subTest(reply=change):
                packet = self.packet_with('conversation', {'id': 'conversation', 'replies': [{**reply, **change}]})
                self.assertEqual(verdict(packet), expected)


class SwiftTextRuleTests(unittest.TestCase):
    """The same class one level down: where this reader approximates a Swift character rule by hand."""

    def setUp(self):
        self.manifest, self.artifacts, self.assets = example('podcast-reference.spokenmargins')
        self.path = 'artifacts/commentary-layer.json'

    def with_transcript(self, text):
        layer = json.loads(self.artifacts[self.path])
        layer['interjections'][0]['representations'][0]['approvedTranscript'] = text
        return fmt.write_packet(self.manifest, {**self.artifacts, self.path: fmt.encode_manifest(layer)}, self.assets)

    def test_whitespace_is_what_whitespaces_and_newlines_says(self):
        for label, text, expected in [
            ('empty after trimming: spaces, tab, no-break space, line separator', ' \t\u00a0\u2028\r\n', 'invalid-manifest'),
            ('U+001C is not whitespace to Swift', '\x1c', 'valid'),
            ('text', 'hello', 'valid'),
        ]:
            with self.subTest(label):
                self.assertEqual(verdict(self.with_transcript(text)), expected)
        self.assertEqual(fmt.swift_split(' a\x1cb \u00a0 c\n'), ['a\x1cb', 'c'])

    def test_file_names_use_alphanumerics_of_any_script(self):
        for path, expected in [
            ('assets/audio/caf\u00e9.m4a', True), ('assets/audio/\u65e5\u672c.m4a', True),
            ('assets/audio/caf\u0301.m4a', True), ('assets/audio/a b.m4a', False), ('assets/audio/a..m4a', False),
            ('assets/audio/a\u2014b.m4a', False), ('assets/audio/a.mp3', False), ('assets/evidence/\u00e9.shazamsignature', True),
            ('artifacts/caf\u00e9.json', True), ('artifacts/a/b.json', False),
        ]:
            with self.subTest(path):
                self.assertEqual(fmt.allowed_package_path(path), expected)

    def test_assets_that_extract_to_one_file(self):
        def clash(first, second):
            return fmt.staged_file_name({'id': first, 'path': 'assets/audio/x.m4a'}).lower() == \
                fmt.staged_file_name({'id': second, 'path': 'assets/audio/y.m4a'}).lower()
        self.assertFalse(clash('caf\u00e9', 'caf-'))
        self.assertTrue(clash('voice/a', 'voice?a'))
        self.assertTrue(clash('A', 'a'))
        self.assertTrue(clash('a b', 'a-b'))

    def test_a_non_ascii_asset_id_is_not_a_collision(self):
        manifest = json.loads(json.dumps(self.manifest))
        layer = json.loads(self.artifacts[self.path])
        manifest['assets'] = [
            {'id': f'v-{name}', 'mimeType': 'audio/mp4', 'path': f'assets/audio/{name}.m4a',
             'provenance': 'sender_approved_original', 'role': 'original_voice'} for name in ('caf\u00e9', 'caf-')]
        assets = {f'assets/audio/{name}.m4a': b'\0\0\0\x18ftypM4A ' + b'\0' * 64 for name in ('caf\u00e9', 'caf-')}
        self.assertEqual(verdict(fmt.write_packet(manifest, self.artifacts, assets)), 'valid')
        manifest['assets'][0]['id'] = 'v-caf?'
        manifest['assets'][1]['id'] = 'v-caf-'
        self.assertEqual(verdict(fmt.write_packet(manifest, self.artifacts, assets)), 'invalid-manifest')
        del layer

    def test_json_constants_python_accepts_are_refused(self):
        layer = self.artifacts[self.path].decode().replace('"interjections"', '"extra":NaN,"interjections"', 1)
        packet = fmt.write_packet(self.manifest, {**self.artifacts, self.path: layer.encode()}, self.assets)
        self.assertEqual(verdict(packet), 'invalid-manifest')

    def test_dates_are_digits_in_range(self):
        for value, expected in [
            ('2026-10-09T12:00:00Z', True), ('2026-10-09T12:00:00.250+02:00', True), ('2024-02-29T00:00:00Z', True),
            ('\u0662\u0660\u0662\u0666-10-09T12:00:00Z', False), ('2026-13-45T25:61:61Z', False),
            ('2026-02-30T00:00:00Z', False), ('2026-10-09T12:00:00', False), ('2026-10-09', False), (20261009, False),
        ]:
            with self.subTest(value):
                self.assertEqual(fmt._is_date(value), expected)

    def test_ids_match_by_canonical_equivalence_like_swift_strings(self):
        composed, decomposed = 'caf\u00e9', 'cafe\u0301'
        self.assertEqual(fmt._canon(composed), fmt._canon(decomposed))
        manifest = json.loads(json.dumps(self.manifest))
        manifest['assets'] = [
            {'id': f'v-{name}', 'mimeType': 'audio/mp4', 'path': f'assets/audio/{name}.m4a',
             'provenance': 'sender_approved_original', 'role': 'original_voice'} for name in (composed, decomposed)]
        assets = {f'assets/audio/{name}.m4a': b'\0\0\0\x18ftypM4A ' + b'\0' * 64 for name in (composed, decomposed)}
        self.assertEqual(verdict(fmt.write_packet(manifest, self.artifacts, assets)), 'invalid-manifest')
        # An id spelled one way in the descriptor and the other in the layer is the same id.
        layer = json.loads(self.artifacts[self.path])
        first = layer['interjections'][0]
        first['packageScopedId'] = composed
        first['representations'][0]['id'] = composed
        first['defaultRepresentationId'] = decomposed
        self.assertEqual(verdict(fmt.write_packet(self.manifest, {**self.artifacts, self.path: fmt.encode_manifest(layer)},
                                                   self.assets)), 'valid')
        self.assertEqual(fmt.swift_split('\u7530\u4e2d\u3000\u592a\u90ce'), ['\u7530\u4e2d', '\u592a\u90ce'])

    def test_only_regular_files_are_read(self):
        entries = []
        with zipfile.ZipFile(io.BytesIO(fmt.write_packet(self.manifest, self.artifacts, self.assets))) as archive:
            entries = [(info.filename, archive.read(info)) for info in archive.infolist()]

        def rebuild(mode, system=3, name=None):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, 'w') as archive:
                for entry, body in entries:
                    info = zipfile.ZipInfo(entry, fmt.FIXED_ZIP_DATE)
                    info.create_system = system
                    info.external_attr = (mode << 16) if entry == (name or 'preview.md') else (0o100644 << 16)
                    archive.writestr(info, body)
            return buffer.getvalue()
        for label, data, expected in [
            ('a regular file', rebuild(0o100644), 'valid'),
            ('a symlink', rebuild(0o120777), 'unsafe-entry'),
            ('a symlink made on macOS', rebuild(0o120755, system=19), 'unsafe-entry'),
            ('a symlink where the host is MS-DOS', rebuild(0o120777, system=0), 'valid'),
            ('a directory mode', rebuild(0o040755), 'unsafe-entry'),
            ('an unusual mode reads as a file', rebuild(0o010644), 'valid'),
        ]:
            with self.subTest(label):
                self.assertEqual(verdict(data), expected)

    def test_crlf_text_counts_as_swift_counts_it(self):
        base = fmt.unpack((EXAMPLES / 'article-embedded-text.spokenmargins').read_bytes())
        manifest, artifacts, assets = json.loads(json.dumps(base[0])), dict(base[1]), dict(base[2])
        path = 'artifacts/embedded-item.json'
        text = 'First line.\r\nSecond line, a \U0001f1fa\U0001f1f8 flag.\r\nThird.'
        artifacts[path] = fmt.encode_manifest({**json.loads(artifacts[path]), 'text': text})
        manifest['item']['exactEditionSHA256'] = fmt.exact_edition_sha256(text)
        manifest['item']['normalizedContentSHA256'] = fmt.normalized_content_sha256(text)
        report = fmt.read_packet(fmt.write_packet(manifest, artifacts, assets))
        self.assertEqual([e.code for e in report.errors], [])
        # 11 + CRLF + 15 + flag + 6 + CRLF + 6: Swift counts each CRLF and the flag once.
        self.assertIn('(41 characters)', fmt.preview_markdown(
            manifest, json.loads(artifacts['artifacts/commentary-layer.json'])['interjections'], embedded_text=text))

    def test_a_character_is_a_grapheme_cluster(self):
        for text, expected in [
            ('a\r\nb', 3), ('\r\n\r\n', 2), ('\U0001f1fa\U0001f1f8', 1), ('\U0001f1fa\U0001f1f8\U0001f1eb\U0001f1f7', 2),
            ('\U0001f1fa\U0001f1f8\U0001f1eb', 2), ('\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466', 1),
            ('\U0001f44d\U0001f3fd', 1), ('e\u0301', 1), ('\u1100\u1161\u11a8', 1), ('\u0928\u092e\u0938\u094d\u0924\u0947', 3),
            ('\u2764\ufe0f', 1), ('a\u200db', 2), ('\u65e5\u672c', 2), ('\uff8a\uff9e', 1),
            ('\U0001f468\u200d\u200d\U0001f469', 2),
        ]:
            with self.subTest(text):
                self.assertEqual(fmt.character_count(text), expected)


class SchemaPatternTests(unittest.TestCase):
    """The package schema's patterns say what the reader says about links and paths."""

    @classmethod
    def setUpClass(cls):
        schema = json.loads((ROOT / 'Contracts' / 'schemas' / 'spoken-margins-package.schema.json').read_text())
        defs = schema['$defs']
        cls.link = re.compile(defs['httpsURL']['pattern'])
        cls.artifact = re.compile(defs['artifact']['properties']['path']['pattern'])
        cls.asset = re.compile(defs['asset']['properties']['path']['pattern'])

    def test_links_agree_with_the_reader(self):
        for value in ['https://example.com/a', 'https://example.com', 'https://example.com?ref=a@b',
                      'https://example.com#frag', 'https://example.com/a?b=c@d', 'https://user@example.com/a',
                      'https://user:pw@example.com', 'http://example.com', 'https://example.com/a b', 'https:///a']:
            with self.subTest(value):
                self.assertEqual(bool(self.link.search(value)), fmt.is_https_url(value))

    def test_paths_agree_with_the_reader(self):
        for path in ['artifacts/layer.json', 'artifacts/caf\u00e9.json', 'artifacts/a..json', 'artifacts/a b.json',
                     'artifacts/a/b.json', 'assets/audio/caf\u00e9.m4a', 'assets/audio/a.m4a', 'assets/evidence/e.shazamsignature',
                     'assets/audio/a.mp3', 'assets/other/a.m4a']:
            with self.subTest(path):
                pattern = self.artifact if path.startswith('artifacts/') else self.asset
                self.assertEqual(bool(pattern.search(path)), fmt.allowed_package_path(path))


class LinkTests(unittest.TestCase):
    def test_https_links_table(self):
        table = {
            'https://example.com/a': True,
            'HTTPS://Example.com/a': True,
            'https://example.com': True,
            'https://example.com/a?b=c#d': True,
            'https://bücher.example/a': True,
            'http://example.com/a': False,
            'file:///private/a.html': False,
            'https://user:pass@example.com/a': False,
            'https://user@example.com/a': False,
            'https:///a': False,
            'https://example.com/a b': False,
            'https://example.com/<a>': False,
            ' https://example.com/a': False,
            '': False,
        }
        for value, expected in table.items():
            with self.subTest(value):
                self.assertEqual(fmt.is_https_url(value), expected)

    def test_shareable_links_table(self):
        table = {
            'https://example.com/podcast/feed.xml': True,
            'https://example.com/ep/3f2504e0-4f89-11d3-9a0c-0305e82c3301.mp3': True,
            'https://example.com/a.mp3?token=abc': False,
            'https://example.com/a.mp3?X-Amz-Signature=abc': False,
            'https://www.patreon.com/rss/show': False,
            'https://example.com/premium/feed.xml': False,
            'https://example.com/feed/a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8': False,
            'https://rss.amperwave.net/a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6/feed': True,
        }
        for value, expected in table.items():
            with self.subTest(value):
                self.assertEqual(fmt.is_shareable_link(value), expected)


class DriftTests(unittest.TestCase):
    def test_every_manifest_shape_is_found_in_both_swift_readers(self):
        for reader in contracts.SWIFT_READERS:
            with self.subTest(reader.name):
                self.assertTrue(set(contracts.MANIFEST_SHAPES) <= set(contracts.swift_allowed_keys(reader)))

    def test_a_reader_that_drifts_from_the_app_is_caught(self):
        drifted = load('spoken_margins_format_drifted', READER_PATH)
        drifted.MANIFEST_KEYS = drifted.MANIFEST_KEYS | {'newField'}
        drifted.ARTIFACT_VERSIONS = {**drifted.ARTIFACT_VERSIONS, 'commentary_layer': 'x.v2'}
        problems = contracts.portable_format_problems(drifted)
        self.assertTrue(any('manifest keys differ' in p for p in problems), problems)
        self.assertTrue(any('commentary_layer' in p for p in problems), problems)

    def test_swift_version_constants_are_found(self):
        versions = contracts.swift_version_constants()
        for type_name in contracts.PORTABLE_VERSIONS:
            self.assertIn(type_name, versions)
        self.assertEqual(versions['SpokenMarginsPackageArchive'], 'spoken-margins.package.v1')

    def test_the_app_bundles_contracts_and_no_other_copy(self):
        project = (ROOT / 'project.yml').read_text()
        for folder in ('fixtures', 'traces', 'schemas'):
            for line in project.splitlines():
                if line.strip().startswith('- path:') and line.strip().endswith(f' {folder}'):
                    self.fail(f'project.yml bundles a root {folder}/ copy: {line.strip()}')
        self.assertIn('- path: Contracts/fixtures', project)


class DocumentTests(unittest.TestCase):
    def test_documents_are_matched_to_their_schema_by_version(self):
        for path, schema in [
            ('Contracts/fixtures/listening-editions/article.json', 'listening-edition.schema.json'),
            ('Contracts/fixtures/exports/mapless-session.json', 'session-export.schema.json'),
            ('Contracts/fixtures/sharing/listening-map-proposal.json', 'portable-listening-map-proposal.schema.json'),
        ]:
            with self.subTest(path):
                report = fmt.validate_document(ROOT / path)
                self.assertEqual((report.kind, report.errors), (schema, []))

    def test_a_broken_document_names_where(self):
        document = json.loads((ROOT / 'Contracts/fixtures/exports/mapless-session.json').read_text())
        document['session'] = 'not an object'
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'broken.json'
            path.write_text(json.dumps(document))
            report = fmt.validate_document(path)
            self.assertTrue(report.errors)
            self.assertIn('session', {e.where for e in report.errors})
            path.write_text(json.dumps({'schemaVersion': 'someone-else.v9'}))
            self.assertEqual(fmt.validate_document(path).errors[0].code, 'unknown-format')


class FixtureHygieneTests(unittest.TestCase):
    """Public examples hold no user data, real media, tokens or private feeds."""

    def test_examples_are_synthetic(self):
        for path in sorted(EXAMPLES.glob('*.spokenmargins')):
            with self.subTest(path.name):
                manifest, artifacts, assets = fmt.unpack(path.read_bytes())
                self.assertIn('synthetic', manifest['senderDisplayLabel'])
                links = [v for k, v in manifest['item'].items() if k.endswith('URL') and v]
                links += [manifest['item'].get('source', {}).get('canonicalURL')] if manifest['item'].get('source') else []
                for link in links:
                    self.assertTrue(link.split('//', 1)[-1].startswith('example.com'), link)
                    if path.name != 'private-link.spokenmargins':
                        self.assertTrue(fmt.is_shareable_link(link), link)
                for body in assets.values():
                    self.assertLess(len(body), 100, 'an example packet carries no real audio')


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(READER_PATH), *args], capture_output=True, text=True)

    def test_exit_codes_and_output(self):
        good = str(EXAMPLES / 'podcast-reference.spokenmargins')
        bad = str(EXAMPLES / 'invalid-tampered-margin.spokenmargins')
        private = str(EXAMPLES / 'private-link.spokenmargins')
        self.assertEqual(self.run_cli('check', good).returncode, 0)
        result = self.run_cli('check', good, bad)
        self.assertEqual(result.returncode, 1)
        self.assertIn('error [digest-mismatch]', result.stdout)
        self.assertEqual(self.run_cli('check', private).returncode, 0)
        self.assertEqual(self.run_cli('check', '--strict', private).returncode, 1)
        self.assertEqual(self.run_cli('check', 'no-such-file.spokenmargins').returncode, 2)
        listed = json.loads(self.run_cli('check', '--json', bad).stdout)
        self.assertEqual(listed[0]['findings'][0]['code'], 'digest-mismatch')
        inspected = json.loads(self.run_cli('inspect', good).stdout)
        self.assertEqual(len(inspected['summary']['margins']), 2)


class SwiftWordBoundTests(unittest.TestCase):
    """_max_words never finds fewer words than Swift's split (letters or numbers by first code point)."""

    def test_word_bound_table(self):
        for text, expected in [
            ('', False), ('nine words is one short of what runs need', False),
            ('ten words make exactly what one run of text needs', True),
            ('Caf\u00e9 talk', False), ('Cafe\u0301 talk', False), ('Don\u2019t \u2014 stop', False),
            ('\u24d0 ' * 10, True),               # circled letters: Swift letters, not Python word characters
            ('\n\u0bbe' * 10, True),             # a combining vowel sign that starts its own character
            ('\u00e9t\u00e9 ' * 9, False), ('\u00e9t\u00e9 ' * 10, True),
            ('UPPER Case MIXED ' * 4, True),
        ]:
            with self.subTest(repr(text)):
                self.assertEqual(fmt._max_words(text) >= fmt.VERBATIM_RUN_WORDS, expected)


if __name__ == '__main__':
    unittest.main()
