"""The portable formats' reference reader (Contracts/tools/spoken_margins_format.py, #1386).

The packets these tests read were written by the app's own Swift writer (coop-packet) or derived from those
by the reference writer; Contracts/examples/packets/expectations.json records what the shipped Swift readers
(this build's and Build 29's) did with each one.
"""
import contextlib
import importlib.util
import io
import json
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
                self.assertEqual(expected['swift'] == 'imports', expected['reference'] == 'valid')

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


class CharacterCountTests(unittest.TestCase):
    def test_grapheme_approximation(self):
        for text, expected in [('abc', 3), ('é', 1), ('👍🏽', 1), ('👩‍💻', 1), ('', 0)]:
            with self.subTest(text):
                self.assertEqual(fmt.character_count(text), expected)


if __name__ == '__main__':
    unittest.main()
