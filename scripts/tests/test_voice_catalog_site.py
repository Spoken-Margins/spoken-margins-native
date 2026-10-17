"""scripts/voice_catalog_site.py (#1818): check, build, sign, page and publish for the voice catalog.

`check` runs against a real local HTTP server through the real urllib transport, on real files in a temporary
folder; nothing here touches the network. Signing uses a throwaway key (the real one lives in the owner's
Keychain) and skips when the `cryptography` package is missing. Tests that need the catalog schema copy it from the
repository and skip when it is absent.
"""
import base64
import contextlib
import copy
import datetime as dt
import hashlib
import io
import json
import shutil
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
from http.client import BadStatusLine, IncompleteRead
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import voice_catalog_site as site  # noqa: E402

REPO = SCRIPTS.parent
SCHEMA = REPO / 'Contracts/schemas/voice-model-catalog.schema.json'
ENVELOPE_SCHEMA = REPO / 'Contracts/schemas/voice-model-catalog-envelope.schema.json'

try:
    import cryptography  # noqa: F401
    HAVE_CRYPTO = True
except ImportError:
    HAVE_CRYPTO = False


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Server:
    """Serves `routes`: path -> {'body': bytes, 'etag': str, 'status': int, 'head': int, 'fail': int}.
    `fail` answers 503 that many times first; `head` overrides the status of HEAD requests."""

    def __init__(self):
        self.routes = {}
        self.log = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _serve(self, method):
                owner.log.append((method, self.path, self.headers.get('User-Agent'), sorted(k.lower() for k in self.headers.keys())))
                route = owner.routes.get(self.path)
                if route is None:
                    self.send_response(404)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                if route.get('fail', 0) > 0:
                    route['fail'] -= 1
                    self.send_response(route.get('fail_status', 503))
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                status = route.get('head', route.get('status', 200)) if method == 'HEAD' else route.get('status', 200)
                body = route['body']
                if method == 'GET' and self.headers.get('Range') and status == 200:
                    status = 206
                    body = body[:1]
                    self.send_response(206)
                    self.send_header('Content-Range', f'bytes 0-0/{len(route["body"])}')
                else:
                    self.send_response(status)
                self.send_header('Content-Length', str(len(body) + (10 if route.get('short') and method == 'GET' else 0)))
                if route.get('etag'):
                    self.send_header('ETag', route['etag'])
                self.end_headers()
                if method == 'GET':
                    self.wfile.write(body)

            def do_GET(self):
                self._serve('GET')

            def do_HEAD(self):
                self._serve('HEAD')

        self.httpd = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = f'http://127.0.0.1:{self.httpd.server_address[1]}'
        self.thread = threading.Thread(target=self.httpd.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
        self.thread.start()

    def gets(self, path):
        return [entry for entry in self.log if entry[0] == 'GET' and entry[1] == path]

    def stop(self):
        if self.thread.is_alive():
            self.httpd.shutdown()
            self.thread.join()
            self.httpd.server_close()


MODEL = b'model bytes ' * 50
LICENCE = b'Licence text.\nYou may use this.\n'


def make_sources(server_url: str, tmp: Path) -> dict:
    licence_path = tmp / 'Contracts/voice-models/licenses/lic.txt'
    licence_path.parent.mkdir(parents=True, exist_ok=True)
    licence_path.write_bytes(LICENCE)
    return {
        'schemaVersion': 'voice-model-sources.v1',
        'catalogId': 'voices',
        'mirrorBase': server_url + '/voices/files/',
        'appRuntimes': ['onnxruntime'],
        'voices': [{
            'id': 'test-voice', 'displayName': 'Test Voice', 'publisher': 'Tester', 'version': '1',
            'runtime': {'name': 'onnxruntime', 'version': '1.0'}, 'minimumIOSVersion': '26.0', 'minimumMemoryMegabytes': 1024,
            'status': 'available', 'bundled': False, 'notes': ['not published'],
            'mirror': {'allowed': True, 'basis': 'test', 'directory': 'test-voice/1/', 'localDirectory': 'mirror-source'},
            'files': [{'path': 'model.bin', 'byteCount': len(MODEL), 'sha256': sha(MODEL), 'upstream': [server_url + '/up/model.bin'],
                       'mirrored': True, 'licenseId': 'lic'}],
            'licenses': [{'id': 'lic', 'name': 'Test licence', 'spdxId': 'MIT', 'textURL': server_url + '/lic.txt', 'textSHA256': sha(LICENCE),
                          'requiresAcceptance': False, 'reviewedText': 'Contracts/voice-models/licenses/lic.txt'}],
        }],
    }


class SiteTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = site.Paths(self.tmp)
        self.server = Server()
        self.addCleanup(self.server.stop)
        self.sources = make_sources(self.server.url, self.tmp)
        self.serve_good()

    def serve_good(self):
        self.server.routes['/up/model.bin'] = {'body': MODEL, 'etag': '"m1"'}
        self.server.routes['/voices/files/test-voice/1/model.bin'] = {'body': MODEL, 'etag': '"m1"'}
        self.server.routes['/lic.txt'] = {'body': LICENCE, 'etag': '"l1"'}

    def http(self, attempts=1):
        return site.HTTP(timeout=5, attempts=attempts, sleep=lambda seconds: None)

    def check(self, **kwargs):
        return site.check_sources(self.sources, self.http(**kwargs), self.paths, '2026-10-17T00:00:00Z')

    def https_sources(self):
        """The same list with example.com for the local server, which the validator would refuse."""
        return json.loads(json.dumps(self.sources).replace(self.server.url, 'https://example.com'))

    def copy_schema(self):
        if not SCHEMA.is_file():
            self.skipTest('catalog schema not in this checkout')
        target = self.tmp / 'Contracts/schemas'
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy(SCHEMA, target / SCHEMA.name)


class CheckTests(SiteTestCase):
    def held_kinds(self, report):
        return sorted((item['subject'], item['kind']) for voice in report['voices'] for item in voice['held'])

    def test_a_clean_run_holds_nothing_and_keeps_no_downloads(self):
        report = self.check()
        self.assertEqual(report['voices'][0]['held'], [])
        self.assertEqual(report['voices'][0]['warnings'], [])
        self.assertEqual(list((self.paths.out / 'downloads').rglob('*.bin')), [])
        self.assertEqual(json.loads(self.paths.held.read_text())['held'], [])
        self.assertTrue(site.summary_lines(report)[0].startswith('test-voice: ok'))

    def test_a_second_run_trusts_an_unchanged_etag_and_downloads_nothing(self):
        self.check()
        before = len(self.server.gets('/up/model.bin')) + len(self.server.gets('/voices/files/test-voice/1/model.bin'))
        report = self.check()
        after = len(self.server.gets('/up/model.bin')) + len(self.server.gets('/voices/files/test-voice/1/model.bin'))
        self.assertEqual((before, after), (2, 2))
        self.assertEqual(report['voices'][0]['counts']['unchanged'], 2)

    def test_changed_bytes_are_held_re_downloaded_into_artifacts_and_reported(self):
        self.check()
        changed = b'x' * len(MODEL)  # same size, different content: only the hash can tell
        self.server.routes['/up/model.bin'] = {'body': changed, 'etag': '"m2"'}
        report = self.check()
        self.assertEqual(self.held_kinds(report), [('model.bin', 'changed')])
        detail = report['voices'][0]['held'][0]['detail']
        self.assertIn(sha(changed), detail)
        self.assertIn(sha(MODEL), detail)
        kept = list((self.paths.out / 'downloads' / 'test-voice').iterdir())
        self.assertEqual([path.read_bytes() for path in kept], [changed])
        self.assertTrue(site.summary_lines(report)[0].startswith('test-voice: HELD'))
        self.assertEqual(json.loads(self.paths.held.read_text())['held'][0]['kind'], 'changed')

    def test_a_source_with_no_etag_is_downloaded_every_run_and_a_wrong_length_is_caught(self):
        self.server.routes['/up/model.bin'] = {'body': MODEL, 'etag': None}
        self.check()
        self.check()
        self.assertEqual(len(self.server.gets('/up/model.bin')), 2)  # nothing to trust, so it is read again
        self.server.routes['/up/model.bin'] = {'body': MODEL + b'!', 'etag': None}
        self.assertEqual(self.held_kinds(self.check()), [('model.bin', 'changed')])

    def test_a_new_reviewed_hash_forces_a_fresh_download_despite_the_same_etag(self):
        self.check()
        newer = b'n' * len(MODEL)  # same length: only the reviewed hash differs
        self.server.routes['/up/model.bin'] = {'body': newer, 'etag': '"m1"'}
        self.server.routes['/voices/files/test-voice/1/model.bin'] = {'body': newer, 'etag': '"m1"'}
        self.sources['voices'][0]['files'][0].update(byteCount=len(newer), sha256=sha(newer))
        report = self.check()
        self.assertEqual(report['voices'][0]['held'], [])
        self.assertEqual(report['voices'][0]['counts']['unchanged'], 0)

    def test_an_upstream_file_that_disappears_is_held(self):
        del self.server.routes['/up/model.bin']
        self.assertEqual(self.held_kinds(self.check()), [('model.bin', 'source-missing')])

    def test_an_unpublished_mirror_is_a_warning_not_a_hold(self):
        del self.server.routes['/voices/files/test-voice/1/model.bin']
        report = self.check()
        self.assertEqual(report['voices'][0]['held'], [])
        self.assertEqual([(w['subject'], w['kind']) for w in report['voices'][0]['warnings']], [('model.bin (mirror)', 'mirror-missing')])
        self.assertIn('mirror-missing', site.summary_lines(report)[0])

    def test_a_server_that_refuses_head_is_asked_for_one_byte_instead(self):
        self.server.routes['/up/model.bin']['head'] = 405
        report = self.check()
        self.assertEqual(report['voices'][0]['held'], [])

    def test_a_503_is_retried_and_a_dead_server_is_reported_as_unreachable(self):
        self.server.routes['/up/model.bin']['fail'] = 2
        self.assertEqual(self.check(attempts=3)['voices'][0]['held'], [])
        self.server.stop()
        report = self.check()
        self.assertEqual(self.held_kinds(report), [('licence lic', 'licence-unreachable'), ('model.bin', 'unreachable')])
        self.assertEqual(report['voices'][0]['warnings'][0]['kind'], 'unreachable')  # the mirror is a warning

    def test_requests_carry_only_the_fixed_user_agent(self):
        self.check()
        for method, path, agent, header_names in self.server.log:
            self.assertEqual(agent, site.USER_AGENT)
            self.assertNotIn('cookie', header_names)
            self.assertNotIn('authorization', header_names)
            self.assertNotIn('?', path)

    def test_a_changed_licence_text_is_held_with_a_diff_and_the_new_text(self):
        newer = b'Licence text.\nYou may NOT use this.\n'
        self.server.routes['/lic.txt'] = {'body': newer}
        report = self.check()
        self.assertEqual(self.held_kinds(report), [('licence lic', 'licence-changed')])
        diff = (self.paths.out / 'licences/lic.diff').read_text()
        self.assertIn('-You may use this.', diff)
        self.assertIn('+You may NOT use this.', diff)
        self.assertEqual((self.paths.out / 'licences/lic.new.txt').read_bytes(), newer)
        self.assertEqual(report['voices'][0]['held'][0]['newSHA256'], sha(newer))

    def test_a_licence_that_goes_missing_is_held(self):
        del self.server.routes['/lic.txt']
        self.assertEqual(self.held_kinds(self.check()), [('licence lic', 'licence-unreachable')])

    def test_one_issue_per_changed_licence_and_none_when_it_already_exists(self):
        self.server.routes['/lic.txt'] = {'body': b'Different licence.\n'}
        report = self.check()
        calls = []

        def run(command, **kwargs):
            calls.append(command)

            class Result:
                returncode = 0
                stdout = '[]' if command[2] == 'list' else 'https://github.com/o/r/issues/9\n'
                stderr = ''
            return Result()

        messages = site.file_licence_issues(report, self.sources, self.paths, run)
        self.assertEqual([c[2] for c in calls], ['list', 'create'])
        title = calls[1][calls[1].index('--title') + 1]
        self.assertEqual(title, f'Voice licence changed: lic ({sha(b"Different licence.\n")[:8]})')
        body = Path(calls[1][calls[1].index('--body-file') + 1]).read_text()
        for heading in ('**Outcome.**', '**Evidence.**', '**Done when.**', '**Must not break:'):
            self.assertIn(heading, body)
        self.assertIn('+Different licence.', body)
        self.assertIn('opened https://github.com/o/r/issues/9', messages[0])

        calls.clear()

        def existing(command, **kwargs):
            calls.append(command)

            class Result:
                returncode = 0
                stdout = json.dumps([{'title': title}])
                stderr = ''
            return Result()

        messages = site.file_licence_issues(report, self.sources, self.paths, existing)
        self.assertEqual([c[2] for c in calls], ['list'])
        self.assertIn('already exists', messages[0])

    def run_main(self, *argv, store=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                unittest.mock.patch.object(site, 'validate_sources', return_value=[]):
            code = site.main(list(argv), self.paths, http=self.http(), store=store)
        return code, out.getvalue(), err.getvalue()

    def test_the_cli_exits_0_when_clean_and_1_with_one_line_per_voice_when_held(self):
        self.paths.sources.write_text(json.dumps(self.sources))
        code, out, _ = self.run_main('check')
        self.assertEqual(code, 0)
        self.assertEqual([line.split(':')[0] for line in out.splitlines()[:1]], ['test-voice'])
        self.server.routes['/up/model.bin'] = {'body': b'x' * len(MODEL), 'etag': '"m2"'}
        code, out, _ = self.run_main('check')
        self.assertEqual(code, 1)
        self.assertIn('test-voice: HELD - model.bin: changed', out)

    def test_a_crashed_check_leaves_no_clean_result_behind(self):
        self.check()
        self.assertTrue(self.paths.held.is_file())
        with unittest.mock.patch.object(site, '_check_one_source', side_effect=RuntimeError('boom')):
            with self.assertRaises(RuntimeError):
                self.check()
        self.assertFalse(self.paths.held.exists())

    def test_a_connection_that_drops_mid_body_is_unreachable_not_changed_and_leaves_no_file(self):
        self.server.routes['/up/model.bin'] = {'body': MODEL, 'etag': '"m9"', 'short': True}
        report = self.check()
        self.assertEqual(self.held_kinds(report), [('model.bin', 'unreachable')])
        self.assertEqual(list((self.paths.out / 'downloads').rglob('*.bin')), [])

    def test_http_client_errors_are_reported_not_raised(self):
        with unittest.mock.patch.object(site.HTTP, 'download', side_effect=IncompleteRead(b'abc')):
            self.assertEqual(self.held_kinds(self.check()), [('model.bin', 'unreachable')])
        with unittest.mock.patch.object(site.HTTP, 'text', side_effect=BadStatusLine('x')):
            self.assertIn(('licence lic', 'licence-unreachable'), self.held_kinds(self.check()))

    def test_a_non_200_download_writes_no_file(self):
        destination = self.tmp / 'out.bin'
        self.server.routes['/up/model.bin'] = {'body': b'nope', 'status': 403, 'head': 200}
        self.assertEqual(self.http().download(self.server.url + '/up/model.bin', destination), (403, 0, ''))
        self.assertFalse(destination.exists())

    def test_a_429_is_retried(self):
        self.server.routes['/up/model.bin']['fail'] = 1
        self.server.routes['/up/model.bin']['fail_status'] = 429
        self.assertEqual(self.check(attempts=2)['voices'][0]['held'], [])

    def test_a_licence_with_a_pinned_text_url_is_watched_at_its_watch_url(self):
        pinned = self.sources['voices'][0]['licenses'][0]
        pinned['textURL'] = self.server.url + '/pinned/lic.txt'
        pinned['watchURL'] = self.server.url + '/main/lic.txt'
        self.server.routes['/pinned/lic.txt'] = {'body': LICENCE}
        self.server.routes['/main/lic.txt'] = {'body': LICENCE}
        self.assertEqual(self.check()['voices'][0]['held'], [])
        self.server.routes['/main/lic.txt'] = {'body': b'Changed on main.\n'}
        self.assertEqual(self.held_kinds(self.check()), [('licence lic', 'licence-changed')])

    def test_a_missing_mirror_is_a_warning_before_the_voice_is_live_and_a_hold_after_when_it_is_the_only_source(self):
        self.sources['voices'][0]['files'][0]['upstream'] = []
        del self.server.routes['/voices/files/test-voice/1/model.bin']
        report = self.check()
        self.assertEqual((report['voices'][0]['held'], len(report['voices'][0]['warnings'])), ([], 1))
        BuildTests.publish_envelope(self, site.build_catalog(self.sources, 1, '2026-10-17T10:00:00Z'))
        self.assertEqual(self.held_kinds(self.check()), [('model.bin (mirror)', 'source-missing')])

    def test_one_licence_text_shared_by_two_voices_opens_one_issue(self):
        second = copy.deepcopy(self.sources['voices'][0])
        second['id'] = 'second-voice'
        second['mirror']['directory'] = 'second-voice/1/'
        self.sources['voices'].append(second)
        self.server.routes['/lic.txt'] = {'body': b'Changed ```fenced``` text.\n'}
        self.server.routes['/voices/files/second-voice/1/model.bin'] = {'body': MODEL, 'etag': '"m1"'}
        report = self.check()
        calls = []

        def run(command, **kwargs):
            calls.append(command)

            class Result:
                returncode = 0
                stdout = '[]' if command[2] == 'list' else 'url\n'
                stderr = ''
            return Result()

        site.file_licence_issues(report, self.sources, self.paths, run)
        self.assertEqual([c[2] for c in calls], ['list', 'create'])
        body = Path(calls[1][calls[1].index('--body-file') + 1]).read_text()
        self.assertIn('````diff', body)  # a fence longer than any backtick run in the diff


class BuildTests(SiteTestCase):
    def test_voice_entry_drops_notes_and_mirror_settings_and_appends_the_mirror(self):
        entry = site.voice_entry(self.sources, self.sources['voices'][0])
        self.assertEqual(entry['files'][0]['sources'], [self.server.url + '/up/model.bin', self.server.url + '/voices/files/test-voice/1/model.bin'])
        for gone in ('notes', 'mirror'):
            self.assertNotIn(gone, entry)
        self.assertNotIn('reviewedText', entry['licenses'][0])
        self.assertNotIn('upstream', entry['files'][0])

    def test_a_file_that_is_not_mirrored_lists_only_its_upstream(self):
        self.sources['voices'][0]['files'][0]['mirrored'] = False
        entry = site.voice_entry(self.sources, self.sources['voices'][0])
        self.assertEqual(entry['files'][0]['sources'], [self.server.url + '/up/model.bin'])

    def publish_envelope(self, catalog):
        (self.paths.site / 'v1').mkdir(parents=True, exist_ok=True)
        envelope = {'schemaVersion': 'voice-model-catalog-envelope.v1', 'keyId': 'k', 'algorithm': 'ed25519',
                    'payload': base64.b64encode(site.payload_bytes(catalog)).decode(), 'signature': 'A' * 88}
        (self.paths.site / site.CATALOG_PATH).write_text(json.dumps(envelope))

    def test_catalog_version_rises_only_when_the_voices_change(self):
        first, note = site.build(self.sources, self.paths, '2026-10-17T10:00:00Z')
        self.assertEqual((first['catalogVersion'], first['issuedAt']), (1, '2026-10-17T10:00:00Z'))
        self.publish_envelope(first)
        same, note = site.build(self.sources, self.paths, '2026-10-24T10:00:00Z')
        self.assertEqual((same['catalogVersion'], same['issuedAt']), (1, '2026-10-17T10:00:00Z'))
        self.assertIn('unchanged', note)
        self.assertEqual(site.payload_bytes(same), site.payload_bytes(first))
        self.sources['voices'][0]['version'] = '2'
        changed, _ = site.build(self.sources, self.paths, '2026-10-24T10:00:00Z')
        self.assertEqual((changed['catalogVersion'], changed['issuedAt']), (2, '2026-10-24T10:00:00Z'))

    def test_validate_sources_accepts_the_good_list_and_names_each_fault(self):
        self.copy_schema()
        self.sources = self.https_sources()
        self.assertEqual(site.validate_sources(self.sources, self.paths), [])

        def faults(change):
            sources = copy.deepcopy(self.sources)
            change(sources)
            return site.validate_sources(sources, self.paths)

        def disallow(s): s['voices'][0]['mirror']['allowed'] = False
        def drop_basis(s): del s['voices'][0]['mirror']['basis']
        def tamper_hash(s): s['voices'][0]['licenses'][0]['textSHA256'] = 'a' * 64
        def stray_licence(s): s['voices'][0]['files'][0]['licenseId'] = 'nope'
        def duplicate(s): s['voices'].append(copy.deepcopy(s['voices'][0]))
        def http_source(s): s['voices'][0]['files'][0]['upstream'] = ['http://example.com/a']
        def bad_hash(s): s['voices'][0]['files'][0]['sha256'] = 'A' * 64
        def no_source(s): s['voices'][0]['files'][0].update(upstream=[], mirrored=False)
        def no_text(s): s['voices'][0]['licenses'][0]['reviewedText'] = 'Contracts/voice-models/licenses/missing.txt'
        def acceptance(s): s['voices'][0]['licenses'][0]['requiresAcceptance'] = True

        for change, fragment in [
            (disallow, 'mirror is not allowed'), (drop_basis, 'mirror.basis'), (tamper_hash, 'does not hash to textSHA256'),
            (stray_licence, 'is not one of the voice'), (duplicate, 'duplicate id'), (http_source, 'built catalog'),
            (bad_hash, 'built catalog'), (no_source, 'no upstream URL'), (no_text, 'no reviewedText file'),
            (acceptance, 'restrictionsSummary')]:
            with self.subTest(change.__name__):
                self.assertTrue(any(fragment in error for error in faults(change)), faults(change))

    def test_the_apps_runtime_list_is_read_from_the_swift_verifier(self):
        verifier = self.tmp / 'Packages/SessionKit/Sources/SessionKit/VoiceModelCatalogVerifier.swift'
        verifier.parent.mkdir(parents=True)
        verifier.write_text('public static let supportedRuntimes: Set<String> = ["onnxruntime", "other"]\n')
        self.assertEqual(site.supported_runtimes_in_app(self.tmp), ['onnxruntime', 'other'])
        self.copy_schema()
        self.sources = self.https_sources()
        self.assertTrue(any('appRuntimes' in error for error in site.validate_sources(self.sources, self.paths)))
        self.sources['appRuntimes'] = ['other', 'onnxruntime']
        self.assertEqual(site.validate_sources(self.sources, self.paths), [])


@unittest.skipUnless(HAVE_CRYPTO, 'the cryptography package is not installed')
class SignTests(SiteTestCase):
    SEED = bytes(range(32))

    class Store:
        def __init__(self, seed):
            self.seed = seed

        def load(self, key_id):
            return self.seed

    def build_payload(self, version=1):
        catalog = site.build_catalog(self.sources, version, '2026-10-17T10:00:00Z')
        self.paths.out.mkdir(parents=True, exist_ok=True)
        self.paths.payload.write_bytes(site.payload_bytes(catalog))
        return catalog

    def test_the_signed_envelope_verifies_and_carries_exactly_the_payload_bytes(self):
        self.build_payload()
        message = site.sign(self.paths, self.Store(self.SEED), 'k1')
        self.assertIn('signed catalogVersion 1', message[0])
        envelope = json.loads((self.paths.site / site.CATALOG_PATH).read_text())
        self.assertEqual(site.verify_envelope(envelope, site.public_key_of(self.SEED)), self.paths.payload.read_bytes())
        self.assertEqual((envelope['keyId'], envelope['algorithm']), ('k1', 'ed25519'))

    def test_the_envelope_matches_its_schema(self):
        if not ENVELOPE_SCHEMA.is_file():
            self.skipTest('envelope schema not in this checkout')
        from jsonschema import Draft202012Validator
        self.build_payload()
        site.sign(self.paths, self.Store(self.SEED), 'k1')
        envelope = json.loads((self.paths.site / site.CATALOG_PATH).read_text())
        self.assertEqual(list(Draft202012Validator(json.loads(ENVELOPE_SCHEMA.read_text())).iter_errors(envelope)), [])

    def test_a_tampered_payload_or_the_wrong_key_does_not_verify(self):
        self.build_payload()
        site.sign(self.paths, self.Store(self.SEED), 'k1')
        envelope = json.loads((self.paths.site / site.CATALOG_PATH).read_text())
        tampered = dict(envelope, payload=base64.b64encode(base64.b64decode(envelope['payload']) + b' ').decode())
        with self.assertRaises(site.ToolError):
            site.verify_envelope(tampered, site.public_key_of(self.SEED))
        with self.assertRaises(site.ToolError):
            site.verify_envelope(envelope, site.public_key_of(bytes(reversed(range(32)))))

    def test_the_manifest_describes_the_catalog_file_it_sits_beside(self):
        self.build_payload()
        site.sign(self.paths, self.Store(self.SEED), 'k1')
        catalog_file = (self.paths.site / site.CATALOG_PATH).read_bytes()
        manifest = json.loads((self.paths.site / site.MANIFEST_PATH).read_text())
        self.assertEqual(manifest['catalogChecksumSHA256'], sha(catalog_file))
        self.assertEqual((manifest['catalogByteCount'], manifest['entryCount'], manifest['contentVersion']), (len(catalog_file), 1, 1))
        self.assertEqual(manifest['catalogURL'], site.SITE_BASE + 'v1/catalog.json')

    def test_a_lower_catalog_version_is_refused_and_an_identical_payload_is_not_signed_again(self):
        self.build_payload(version=2)
        site.sign(self.paths, self.Store(self.SEED), 'k1')
        self.assertIn('nothing to sign', site.sign(self.paths, self.Store(self.SEED), 'k1')[0])
        self.build_payload(version=1)
        with self.assertRaisesRegex(site.ToolError, 'rollback'):
            site.sign(self.paths, self.Store(self.SEED), 'k1')

    def test_the_same_version_with_different_voices_is_refused(self):
        self.build_payload(version=1)
        site.sign(self.paths, self.Store(self.SEED), 'k1')
        self.sources['voices'][0]['version'] = '2'
        self.build_payload(version=1)
        with self.assertRaisesRegex(site.ToolError, 'same catalogVersion'):
            site.sign(self.paths, self.Store(self.SEED), 'k1')

    def test_a_missing_key_points_at_keygen_and_a_missing_payload_at_build(self):
        with self.assertRaisesRegex(site.ToolError, 'build'):
            site.sign(self.paths, self.Store(None), 'k1')
        self.build_payload()
        with self.assertRaisesRegex(site.ToolError, 'keygen'):
            site.sign(self.paths, self.Store(None), 'k1')

    def test_keychain_store_keeps_the_seed_out_of_the_command_line(self):
        calls = []
        saved = {}

        def run(command, input=None, **kwargs):
            calls.append((command, input))

            class Result:
                returncode = 0
                stdout = ''
                stderr = ''
            result = Result()
            if command[:2] == ['security', '-i']:
                saved['seed'] = input.split('-w ')[1].strip()
            elif command[1] == 'find-generic-password':
                if 'seed' not in saved:
                    result.returncode = 44
                else:
                    result.stdout = saved['seed'] + '\n'
            return result

        store = site.KeychainKeyStore(run, platform='darwin')
        self.assertIsNone(store.load('k1'))
        seed = store.create('k1')
        self.assertEqual(len(seed), 32)
        for command, _ in calls:
            self.assertNotIn(saved['seed'], ' '.join(command))
        self.assertEqual(store.load('k1'), seed)
        add = next(entry for entry in calls if entry[0] == ['security', '-i'])
        self.assertIn(f'-s {site.KEYCHAIN_SERVICE} -a k1', add[1])
        lines = site.keygen(store, 'k1')
        self.assertIn(base64.b64encode(site.public_key_of(seed)).decode(), lines[1])
        self.assertNotIn(saved['seed'], '\n'.join(lines))
        self.assertTrue(lines[0].startswith('Found'))

    def test_keychain_store_refuses_to_run_off_the_mac(self):
        with self.assertRaisesRegex(site.ToolError, "Mac's login Keychain"):
            site.KeychainKeyStore(platform='linux').load('k1')


class PageTests(SiteTestCase):
    def catalog(self):
        catalog = site.build_catalog(self.sources, 3, '2026-10-17T10:00:00Z')
        return catalog

    def test_the_page_names_each_voice_its_size_publisher_sources_and_licences(self):
        page = site.render_page(self.catalog(), ['onnxruntime'])
        for text in ('Test Voice', 'Tester', 'version 1', '127.0.0.1', 'Test licence', 'Catalog version 3', 'issued 2026-10-17'):
            self.assertIn(text, page)
        self.assertIn('href="../assets/site.css"', page)
        self.assertIn('under 1 MB', page)

    def test_sizes_are_in_the_same_megabytes_the_owner_quotes(self):
        self.assertEqual(site.format_size(148065254), '141 MB')
        self.assertEqual(site.format_size(1), 'under 1 MB')

    def test_everything_from_the_catalog_is_escaped(self):
        self.sources['voices'][0]['displayName'] = '<script>alert(1)</script>'
        self.sources['voices'][0]['licenses'][0].update(requiresAcceptance=True, restrictionsSummary='no <b>harm</b> & no javascript:')
        self.sources['voices'][0]['licenses'][0]['textURL'] = 'https://example.com/a"onmouseover="x'
        page = site.render_page(self.catalog(), ['onnxruntime'])
        self.assertNotIn('<script>alert', page)
        self.assertNotIn('<b>harm', page)
        self.assertIn('&lt;script&gt;', page)
        self.assertNotIn('"onmouseover="x', page)
        self.assertIn('What you agree to', page)

    def test_a_licence_that_is_not_https_is_text_not_a_link(self):
        self.sources['voices'][0]['licenses'][0]['textURL'] = 'javascript:alert(1)'
        page = site.render_page(self.catalog(), ['onnxruntime'])
        self.assertNotIn('href="javascript', page)

    def test_bundled_retired_and_unrunnable_voices_say_so_and_retired_voices_come_last(self):
        withdrawn = copy.deepcopy(self.sources['voices'][0])
        withdrawn.update(id='old-voice', displayName='Old Voice', status='withdrawn')
        bundled = copy.deepcopy(self.sources['voices'][0])
        bundled.update(id='built-in', displayName='Built In', bundled=True, files=[])
        future = copy.deepcopy(self.sources['voices'][0])
        future.update(id='future', displayName='Future Voice', runtime={'name': 'other', 'version': '1'})
        self.sources['voices'] = [withdrawn, bundled, future, self.sources['voices'][0]]
        page = site.render_page(self.catalog(), ['onnxruntime'])
        self.assertIn('included in the app, no download', page)
        self.assertIn('Not in the app yet.', page)
        self.assertIn('Withdrawn.', page)
        self.assertLess(page.index('Built In'), page.index('Old Voice'))
        self.assertLess(page.index('Test Voice'), page.index('Old Voice'))

    def test_the_lede_names_the_built_in_voice_and_promises_no_screen_that_may_not_exist(self):
        bundled = copy.deepcopy(self.sources['voices'][0])
        bundled.update(id='built-in', displayName='Built In', bundled=True, files=[])
        self.sources['voices'].append(bundled)
        page = site.render_page(self.catalog(), ['onnxruntime'])
        self.assertIn('Built In is built into the app.', page)
        self.assertNotIn('Settings', page)

    def test_rendering_twice_gives_the_same_bytes(self):
        self.assertEqual(site.render_page(self.catalog(), ['onnxruntime']), site.render_page(self.catalog(), ['onnxruntime']))


class PublishTests(SiteTestCase):
    def prepare(self):
        """A published catalog, its page, a clean check and the mirror source file."""
        catalog = site.build_catalog(self.sources, 1, '2026-10-17T10:00:00Z')
        (self.paths.site / 'v1').mkdir(parents=True)
        catalog_file = site.pretty({'schemaVersion': 'voice-model-catalog-envelope.v1', 'keyId': 'k', 'algorithm': 'ed25519',
                                    'payload': base64.b64encode(site.payload_bytes(catalog)).decode(), 'signature': 'A' * 88})
        (self.paths.site / site.CATALOG_PATH).write_bytes(catalog_file)
        (self.paths.site / site.MANIFEST_PATH).write_bytes(site.pretty({'catalogChecksumSHA256': sha(catalog_file)}))
        (self.paths.site / 'index.html').write_text(site.render_page(catalog, self.sources['appRuntimes']), encoding='utf-8')
        self.paths.out.mkdir(parents=True, exist_ok=True)
        self.paths.held.write_text(json.dumps({'held': [], 'checkedAt': site.utc_now()}))
        source = self.tmp / 'mirror-source'
        source.mkdir()
        (source / 'model.bin').write_bytes(MODEL)
        return source

    def test_a_clean_state_lists_the_mirror_uploads_and_stages_them_as_links(self):
        self.prepare()
        problems, uploads = site.plan_publish(self.sources, self.paths)
        self.assertEqual(problems, [])
        self.assertEqual([remote for _, remote in uploads], ['test-voice/1/model.bin'])
        stage = site.stage_mirror(self.paths, uploads)
        self.assertEqual((stage / 'test-voice/1/model.bin').read_bytes(), MODEL)

    def test_an_old_or_undated_check_stops_the_publish(self):
        self.prepare()
        stamp = lambda t: self.paths.held.write_text(json.dumps({'held': [], 'checkedAt': t}))  # noqa: E731
        stamp('2026-10-17T00:00:00Z')
        self.assertEqual(site.plan_publish(self.sources, self.paths, now='2026-10-17T20:00:00Z')[0], [])
        problems = site.plan_publish(self.sources, self.paths, now='2026-10-18T01:00:00Z')[0]
        self.assertTrue(any('more than a day old' in p for p in problems))
        self.paths.held.write_text(json.dumps({'held': []}))
        self.assertTrue(any('more than a day old' in p for p in site.plan_publish(self.sources, self.paths)[0]))

    def test_a_live_catalog_newer_than_this_checkout_stops_the_publish(self):
        self.prepare()
        live = {'status': 200, 'body': json.dumps({'contentVersion': 2}).encode()}

        class Http:
            def text(self, url):
                self.url = url
                return live['status'], live['body']
        http = Http()
        problems, _ = site.plan_publish(self.sources, self.paths, http=http)
        self.assertEqual(http.url, site.SITE_BASE + 'v1/manifest.json')
        self.assertTrue(any('live catalog is version 2' in p for p in problems))
        live.update(status=404, body=b'')
        self.assertEqual(site.plan_publish(self.sources, self.paths, http=http)[0], [])

    def test_the_stage_uses_files_not_symlinks_and_world_readable_modes(self):
        self.prepare()
        _, uploads = site.plan_publish(self.sources, self.paths)
        stage = site.stage_mirror(self.paths, uploads)
        staged = stage / 'test-voice/1/model.bin'
        self.assertFalse(staged.is_symlink())
        self.assertEqual(staged.stat().st_mode & 0o777, 0o644)
        self.assertEqual((stage / 'test-voice').stat().st_mode & 0o777, 0o755)

    def test_publish_dry_run_prints_the_plan_and_uploads_nothing(self):
        self.prepare()
        self.paths.held.write_text(json.dumps({'held': [], 'checkedAt': site.utc_now()}))
        self.paths.sources.write_text(json.dumps(self.sources))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                unittest.mock.patch.object(site, 'validate_sources', return_value=[]), \
                unittest.mock.patch.object(site.subprocess, 'run') as run:
            code = site.main(['publish'], self.paths, http=self.http_that_has_no_live_catalog())
        self.assertEqual((code, run.called), (0, False), err.getvalue())
        self.assertIn('Dry run: nothing uploaded', out.getvalue())
        self.assertIn('1 mirror files', out.getvalue())

    def http_that_has_no_live_catalog(self):
        class Http:
            def text(self, url):
                return 404, b''
        return Http()

    def test_anything_held_stops_the_publish_and_names_it(self):
        self.prepare()
        self.paths.held.write_text(json.dumps({'checkedAt': site.utc_now(), 'held': [{'voice': 'test-voice', 'subject': 'licence lic', 'kind': 'licence-changed'}]}))
        problems, _ = site.plan_publish(self.sources, self.paths)
        self.assertEqual(len(problems), 1)
        self.assertIn('licence lic: licence-changed', problems[0])

    def test_no_check_result_stops_the_publish(self):
        self.prepare()
        self.paths.held.unlink()
        self.assertIn('run `scripts/voice-catalog check`', site.plan_publish(self.sources, self.paths)[0][0])

    def test_nothing_signed_yet_stops_the_publish(self):
        self.prepare()
        (self.paths.site / site.CATALOG_PATH).unlink()
        self.assertIn('Nothing signed yet', site.plan_publish(self.sources, self.paths)[0][0])

    def test_a_catalog_out_of_step_with_the_list_or_a_stale_page_stops_the_publish(self):
        self.prepare()
        self.sources['voices'][0]['version'] = '2'
        problems, _ = site.plan_publish(self.sources, self.paths)
        self.assertTrue(any('does not match sources.json' in problem for problem in problems))
        self.sources['voices'][0]['version'] = '1'
        (self.paths.site / 'index.html').write_text('old page')
        self.assertTrue(any('index.html' in problem for problem in site.plan_publish(self.sources, self.paths)[0]))

    def test_a_missing_lfs_pointer_or_altered_mirror_file_stops_the_publish(self):
        source = self.prepare()
        (source / 'model.bin').unlink()
        self.assertTrue(any('mirror file missing' in p for p in site.plan_publish(self.sources, self.paths)[0]))
        (source / 'model.bin').write_bytes(b'version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 5\n')
        self.assertTrue(any('git lfs pull' in p for p in site.plan_publish(self.sources, self.paths)[0]))
        (source / 'model.bin').write_bytes(MODEL[:-1] + b'!')
        self.assertTrue(any('does not match the reviewed size' in p for p in site.plan_publish(self.sources, self.paths)[0]))

    def test_mirror_from_points_at_another_folder(self):
        source = self.prepare()
        elsewhere = self.tmp / 'elsewhere'
        shutil.move(str(source), str(elsewhere))
        problems, uploads = site.plan_publish(self.sources, self.paths, {'test-voice': elsewhere})
        self.assertEqual((problems, len(uploads)), ([], 1))


class DeployScriptTests(unittest.TestCase):
    def test_the_deploy_script_excludes_the_mirror_from_delete_and_takes_it_from_the_stage(self):
        script = (SCRIPTS / 'deploy-spoken-margins-site.sh').read_text()
        self.assertIn("--exclude '/voices/files/'", script)
        self.assertNotIn('--delete-excluded', script)
        mirror_upload = script.index('SPOKEN_MARGINS_MIRROR_STAGE')
        self.assertNotIn('--delete', script[mirror_upload:script.index('echo "Uploading ${site_directory}/."')])

    @unittest.skipUnless(shutil.which('rsync'), 'rsync is not installed')
    def test_rsync_with_that_exclude_deletes_stale_pages_but_not_the_mirror(self):
        import subprocess
        with tempfile.TemporaryDirectory() as folder:
            sender, receiver = Path(folder) / 'Site', Path(folder) / 'web'
            (sender / 'voices/v1').mkdir(parents=True)
            (sender / 'index.html').write_text('new')
            (receiver / 'voices/files/v/1').mkdir(parents=True)
            (receiver / 'voices/files/v/1/model.bin').write_bytes(b'bytes')
            (receiver / 'stale.html').write_text('old')
            subprocess.run(['rsync', '--archive', '--delete', '--exclude', '/voices/files/', f'{sender}/', f'{receiver}/'], check=True)
            self.assertTrue((receiver / 'voices/files/v/1/model.bin').is_file())
            self.assertFalse((receiver / 'stale.html').exists())
            self.assertTrue((receiver / 'index.html').is_file())


if __name__ == '__main__':
    unittest.main()
