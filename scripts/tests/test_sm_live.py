"""scripts/sm_live.py (#3872): every fact names its source, and what can't be read says `unknown`.

GitHub, the web and git are replaced at the World boundary. Signing uses real openssl with a real throwaway key, and the
tag message reads a real plist, because those are the boundaries that would break.
"""
import base64
import contextlib
import datetime as dt
import hashlib
import io
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import sm_live as live  # noqa: E402

NOW = dt.datetime(2026, 11, 9, 18, 0, tzinfo=dt.timezone.utc)
ARTIFACTS = f'repos/{live.REPO}/actions/artifacts?name={live.ASC_ARTIFACT}&per_page=30'
REFS = f'repos/{live.REPO}/git/matching-refs/tags/testflight/'


def artifact(created='2026-11-09T16:00:00Z', branch='main', repo=1, head=1, expired=False, url='https://api.github.com/zip/1'):
    return {'created_at': created, 'expired': expired, 'archive_download_url': url,
            'workflow_run': {'head_branch': branch, 'repository_id': repo, 'head_repository_id': head}}


def zipped(document):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as archive:
        archive.writestr(live.ASC_FILE, json.dumps(document))
    return out.getvalue()


class FakeWorld:
    def __init__(self, gh=None, web=None, git=None):
        self.now = NOW
        self.gh_answers, self.web_answers, self.git_answers = gh or {}, web or {}, git or {}

    @staticmethod
    def _answer(answer):
        if isinstance(answer, Exception):
            raise answer
        return answer

    def gh(self, path):
        if path not in self.gh_answers:
            raise live.ReadError(f'no answer for {path}')
        return self._answer(self.gh_answers[path])

    def fetch(self, url):
        if url not in self.web_answers:
            raise live.ReadError(f'no answer for {url}')
        return self._answer(self.web_answers[url])

    def git(self, *args):
        for key, answer in self.git_answers.items():
            if args[:len(key)] == key:
                return self._answer(answer)
        raise live.ReadError(f'no answer for git {args}')


def with_tags(extra=None):
    answers = {
        REFS: json.dumps([{'ref': 'refs/tags/testflight/0.1-build-9', 'object': {'type': 'tag', 'sha': 'a9'}},
                          {'ref': 'refs/tags/testflight/0.1-build-36', 'object': {'type': 'tag', 'sha': 'a36'}},
                          {'ref': 'refs/tags/testflight/0.1-build-34', 'object': {'type': 'commit', 'sha': 'deadbeefcafe'}},
                          {'ref': 'refs/tags/testflight/notes', 'object': {'type': 'commit', 'sha': 'ffff'}}]).encode(),
        f'repos/{live.REPO}/git/tags/a36': json.dumps({'object': {'sha': '5688c02abcdef'},
                                                       'message': 'Build 36\n\nflags: SMShareLinkCreation=YES\n'}).encode(),
        f'repos/{live.REPO}/git/tags/a9': json.dumps({'object': {'sha': '1111111aaaa'}, 'message': 'plain'}).encode()}
    answers.update(extra or {})
    return answers


def asc_answers(listing, zip_bytes=None):
    answers = {ARTIFACTS: json.dumps({'artifacts': listing}).encode()}
    if zip_bytes is not None:
        answers['zip/1'] = zip_bytes
    return answers


READING = {'read_at': '2026-11-09T16:00:00Z',
           'builds': [{'build': '36', 'expired': False, 'internal_groups': 1, 'external_groups': 1,
                       'external_state': 'IN_BETA_TESTING', 'internal_state': 'IN_BETA_TESTING'},
                      {'build': '34', 'expired': True, 'internal_groups': 1, 'external_groups': 0}]}


class Flags(unittest.TestCase):
    def test_the_table(self):
        rows = [('flags: SMShareLinkCreation=YES', {'SMShareLinkCreation': True}, 'read from the archive'),
                ('flags: SMShareLinkCreation=NO', {'SMShareLinkCreation': False}, 'read from the archive'),
                ('flags: SMA=YES SMB=NO', {'SMA': True, 'SMB': False}, 'read from the archive'),
                ('title\n\nflags:   SMA=YES\nmore', {'SMA': True}, 'read from the archive'),
                ('flags:', {}, 'read from the archive'),
                ('share-link creation on (SM_SHARE_LINK_CREATION=YES), not Internal Only', {'SMShareLinkCreation': True}, 'typed in the tag'),
                ('SM_SHARE_LINK_CREATION=NO', {'SMShareLinkCreation': False}, 'typed in the tag'),
                ('Share-Link Creation OFF', {'SMShareLinkCreation': False}, 'typed in the tag'),
                ('share link creation on', {'SMShareLinkCreation': True}, 'typed in the tag'),
                ('share links are great', None, None), ('', None, None), (None, None, None),
                ('flagship: SMA=YES', None, None), ('x' * 100000, None, None)]
        for message, flags, how in rows:
            with self.subTest(message=(message or '')[:40]):
                self.assertEqual(live.flags_from_message(message), (flags, how))


class ArtifactTrust(unittest.TestCase):
    def test_only_a_run_of_our_own_trunk_counts(self):
        self.assertTrue(live.artifact_is_ours(artifact()))
        for name, bad in (('branch', artifact(branch='ws/x')), ('fork named main', artifact(head=2)),
                          ('expired', artifact(expired=True)), ('no run', {'created_at': 'x', 'workflow_run': None}),
                          ('no ids', artifact(repo=None, head=None))):
            with self.subTest(name):
                self.assertFalse(live.artifact_is_ours(bad))

    def test_a_forged_artifact_is_never_read(self):
        world = FakeWorld(gh=with_tags(asc_answers([artifact(head=2, created='2026-11-09T17:59:00Z')], zipped(READING))))
        row = live.builds(world)['rows'][0]
        self.assertIn('no reading yet', row['testers']['unknown'])


class Builds(unittest.TestCase):
    def test_newest_first_with_flags_and_testers(self):
        part = live.builds(FakeWorld(gh=with_tags(asc_answers([artifact()], zipped(READING)))))
        self.assertEqual([row['build'] for row in part['rows']], [36, 34, 9])
        first = part['rows'][0]
        self.assertEqual((first['commit'], first['flags'], first['flags_source']),
                         ('5688c02', {'SMShareLinkCreation': True}, 'read from the archive'))
        self.assertEqual(first['testers']['value'], 'internal and external testers (IN_BETA_TESTING)')
        self.assertFalse(first['testers']['stale'])
        self.assertEqual(part['rows'][1]['testers']['value'], 'expired')
        self.assertEqual(part['rows'][1]['commit'], 'deadbee')
        self.assertIn('not among', part['rows'][2]['testers']['value'])

    def test_a_tag_that_records_nothing_is_unknown_not_off(self):
        rows = live.builds(FakeWorld(gh=with_tags(asc_answers([artifact()], zipped(READING)))))['rows']
        self.assertIsNone(rows[1]['flags'])
        self.assertIn('does not record', rows[1]['flags_unknown'])
        text = '\n'.join(live.render_builds({'rows': rows}))
        self.assertIn('Build 34, commit deadbee: flags unknown', text)
        self.assertNotIn('Build 34, commit deadbee: share links off', text)

    def test_an_old_reading_says_so(self):
        reading = dict(READING, read_at='2026-11-09T01:00:00Z')
        rows = live.builds(FakeWorld(gh=with_tags(asc_answers([artifact()], zipped(reading)))))['rows']
        self.assertTrue(rows[0]['testers']['stale'])
        self.assertIn('STALE, 17 hours old', '\n'.join(live.render_builds({'rows': rows})))

    def test_no_reading_leaves_the_tags_readable(self):
        rows = live.builds(FakeWorld(gh=with_tags(asc_answers([]))))['rows']
        self.assertEqual(rows[0]['commit'], '5688c02')
        self.assertIn('unknown', rows[0]['testers'])

    def test_a_corrupt_artifact_is_unknown(self):
        rows = live.builds(FakeWorld(gh=with_tags(asc_answers([artifact()], b'not a zip'))))['rows']
        self.assertIn('unreadable', rows[0]['testers']['unknown'])

    def test_no_tags_readable_is_unknown_for_the_section(self):
        part = live.builds(FakeWorld())
        self.assertIn('unknown', part)
        self.assertIn('unknown:', live.render_builds(part)[0])

    def test_the_tester_words(self):
        rows = [({'internal_groups': 1, 'external_groups': 0, 'internal_state': 'X', 'external_state': 'Y'}, 'internal testers (X)'),
                ({'internal_groups': 0, 'external_groups': 2, 'external_state': 'Y'}, 'external testers (Y)'),
                ({'internal_groups': 0, 'external_groups': 0}, 'in no tester group'),
                ({'expired': True, 'external_groups': 1}, 'expired')]
        for entry, words in rows:
            with self.subTest(words):
                self.assertEqual(live.testers_of(entry), words)


class Site(unittest.TestCase):
    TRUNK = ('ls-tree',)

    def world(self, **web):
        answers = {(f'{live.SITE}/{k}'): v for k, v in web.items()}
        return FakeWorld(web=answers, git={('fetch',): b'', ('ls-tree',): b'Site/index.html\nSite/join/index.html\nSite/a.css\nSite/terms/index.html\n',
                                           ('show', 'origin/main:Site/index.html'): b'home', ('show', 'origin/main:Site/join/index.html'): b'join',
                                           ('show', 'origin/main:Site/terms/index.html'): b'terms'})

    def test_pages(self):
        world = self.world()
        world.web_answers = {f'{live.SITE}/': (200, {}, b'home'), f'{live.SITE}/join/': (200, {}, b'old join'),
                             f'{live.SITE}/terms/': (404, {}, b''),
                             f'{live.SITE}/deploy.json': (200, {}, b'{"commit":"abc1234","deployed_at":"2026-11-09T00:00:00Z"}')}
        part = live.site(world)
        by = {row['page']: row for row in part['rows']}
        self.assertEqual(sorted(by), ['/', '/join/', '/terms/'])
        self.assertTrue(by['/']['matches_trunk'])
        self.assertFalse(by['/join/']['matches_trunk'])
        text = '\n'.join(live.render_site(part))
        self.assertIn('/join/: DIFFERS FROM MAIN', text)
        self.assertIn('/terms/: NOT LIVE (HTTP 404)', text)
        self.assertIn('last deploy 2026-11-09T00:00:00Z, commit abc1234', text)

    def test_a_page_that_cannot_be_reached_is_unknown_not_missing(self):
        world = self.world()
        world.web_answers = {f'{live.SITE}/': live.ReadError('could not reach it')}
        text = '\n'.join(live.render_site(live.site(world)))
        self.assertIn('/: unknown: could not reach it', text)
        self.assertNotIn('NOT LIVE', text)

    def test_no_git_is_unknown(self):
        self.assertIn('unknown', live.site(FakeWorld()))


class WebAndServer(unittest.TestCase):
    def test_a_missing_stamp_is_unknown(self):
        for reply in ((404, {}, b''), (200, {}, b'<html>'), (200, {}, b'[1]'), (200, {}, b'{"commit":""}')):
            with self.subTest(reply=reply):
                part = live.web(FakeWorld(web={f'{live.WEB}/deploy.json': reply}))
                self.assertIn('no deploy stamp', part['unknown'])

    def test_the_web_stamp(self):
        world = FakeWorld(web={f'{live.WEB}/deploy.json': (200, {}, b'{"commit":"abc1234","deployed_at":"T"}')},
                          git={('rev-list',): b'3\n'})
        part = live.web(world)
        self.assertEqual((part['commit'], part['behind']), ('abc1234', 3))
        self.assertIn('3 commit(s) behind main', live.render_web(part)[0])

    def health(self, doc, git=None):
        return FakeWorld(web={f'{live.SITE}/api/v1/health': (200, {}, json.dumps(doc).encode())}, git=git)

    def test_the_server(self):
        part = live.server(self.health({'status': 'ok', 'version': 'v', 'commit': 'abc1234', 'built': 'T',
                                        'services': {'links': 'on', 'maps': 'off'}}, {('rev-list',): b'0\n'}))
        self.assertEqual((part['commit'], part['services_on'], part['services_off']), ('abc1234', ['links'], ['maps']))
        self.assertIn('same as main', live.render_server(part)[0])

    def test_a_server_from_before_the_stamp(self):
        for doc in ({'status': 'ok', 'version': 'v', 'services': {}}, {'status': 'ok', 'version': 'v', 'commit': '', 'services': {}}):
            with self.subTest(doc=doc):
                line = live.render_server(live.server(self.health(doc)))[0]
                self.assertIn('commit unknown (', line)

    def test_a_dirty_or_foreign_commit_gets_no_behind_count(self):
        for commit in ('abc1234-dirty', 'zzz', '', None):
            with self.subTest(commit=commit):
                self.assertIsNone(live.changes_since(FakeWorld(git={('rev-list',): b'3\n'}), commit, 'Web'))

    def test_an_unreachable_server_is_unknown(self):
        self.assertIn('unknown', live.server(FakeWorld()))
        self.assertIn('unknown', live.server(FakeWorld(web={f'{live.SITE}/api/v1/health': (200, {}, b'nope')})))


class TagMessage(unittest.TestCase):
    def test_it_round_trips_through_the_reader(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'B.xcarchive' / 'Products' / 'Applications' / 'X.app'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '37', 'CFBundleShortVersionString': '0.2',
                                                            'SMShareLinkCreation': 'YES', 'SMOther': 'NO',
                                                            'SMNotAFlag': 'hello', 'Other': 'YES'}))
            message = live.tag_message(app.parent.parent.parent)
        self.assertTrue(message.startswith('Build 37 (0.2)'))
        self.assertEqual(live.flags_from_message(message),
                         ({'SMOther': False, 'SMShareLinkCreation': True}, 'read from the archive'))

    def test_a_bad_archive_fails_clearly(self):
        out = io.StringIO()
        with contextlib.redirect_stderr(out):
            self.assertEqual(live.main(['--tag-message', '/nonexistent.xcarchive'], FakeWorld()), 1)
        self.assertIn('sm_live:', out.getvalue())


class Signing(unittest.TestCase):
    def test_der_to_raw(self):
        rows = [(bytes([0x30, 6, 2, 1, 5, 2, 1, 7]), b'\0' * 31 + b'\x05' + b'\0' * 31 + b'\x07'),
                (bytes([0x30, 70, 2, 33, 0]) + b'\xaa' * 32 + bytes([2, 33, 0]) + b'\xbb' * 32, b'\xaa' * 32 + b'\xbb' * 32)]
        for der, raw in rows:
            with self.subTest(size=len(der)):
                self.assertEqual(live.der_to_raw(der), raw)

    def test_bad_signatures_are_refused(self):
        for der in (b'', b'\x31\x00', bytes([0x30, 3, 3, 1, 1]), bytes([0x30, 37, 2, 33]) + b'\x01' * 33):
            with self.subTest(der=der[:6]), self.assertRaises(live.ReadError):
                live.der_to_raw(der)

    def test_a_token_openssl_verifies(self):
        with tempfile.TemporaryDirectory() as folder:
            key, public = Path(folder) / 'k.p8', Path(folder) / 'k.pub'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(key)],
                           check=True, capture_output=True)
            subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', str(public)], check=True, capture_output=True)
            token = live.asc_token('KID', 'ISS', key.read_text(), NOW)
            head, claims, signature = token.split('.')
            raw = base64.urlsafe_b64decode(signature + '=' * (-len(signature) % 4))
            self.assertEqual(len(raw), 64)

            def integer(part):
                part = part.lstrip(b'\0') or b'\0'
                if part[0] & 0x80:
                    part = b'\0' + part
                return bytes([2, len(part)]) + part
            body = integer(raw[:32]) + integer(raw[32:])
            (Path(folder) / 's').write_bytes(bytes([0x30, len(body)]) + body)
            done = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public), '-signature', str(Path(folder) / 's')],
                                  input=f'{head}.{claims}'.encode(), capture_output=True)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        decoded = json.loads(base64.urlsafe_b64decode(claims + '=' * (-len(claims) % 4)))
        self.assertEqual((decoded['iss'], decoded['aud'], decoded['exp'] - decoded['iat']), ('ISS', 'appstoreconnect-v1', 600))
        self.assertEqual(json.loads(base64.urlsafe_b64decode(head + '=' * (-len(head) % 4)))['kid'], 'KID')

    def test_a_bad_key_fails_without_repeating_it(self):
        with self.assertRaises(live.ReadError) as caught:
            live.asc_token('K', 'I', 'SECRET-NOT-A-KEY', NOW)
        self.assertNotIn('SECRET', str(caught.exception))

    def test_write_asc_names_missing_settings_only(self):
        out = io.StringIO()
        with contextlib.redirect_stderr(out), unittest.mock.patch.dict('os.environ', {'ASC_KEY_ID': '', 'ASC_ISSUER_ID': '', 'ASC_KEY_P8': ''}):
            self.assertEqual(live.main(['--write-asc', '/nonexistent/x'], FakeWorld()), 1)
        self.assertIn('missing ASC_KEY_ID', out.getvalue())


class Summary(unittest.TestCase):
    DOCUMENT = {'data': [{'type': 'builds', 'id': 'b1',
                          'attributes': {'version': '36', 'uploadedDate': 'T', 'processingState': 'VALID', 'expired': False},
                          'relationships': {'betaGroups': {'data': [{'type': 'betaGroups', 'id': 'g1'}, {'type': 'betaGroups', 'id': 'g2'}]},
                                            'buildBetaDetail': {'data': {'type': 'buildBetaDetails', 'id': 'd1'}},
                                            'preReleaseVersion': {'data': {'type': 'preReleaseVersions', 'id': 'v1'}}}},
                         {'type': 'builds', 'id': 'b2', 'attributes': {'version': '35'}, 'relationships': {}}],
                'included': [{'type': 'betaGroups', 'id': 'g1', 'attributes': {'name': 'Friends of Cole', 'isInternalGroup': False, 'publicLink': 'https://x'}},
                             {'type': 'betaGroups', 'id': 'g2', 'attributes': {'name': 'Family', 'isInternalGroup': True}},
                             {'type': 'buildBetaDetails', 'id': 'd1', 'attributes': {'internalBuildState': 'I', 'externalBuildState': 'E'}},
                             {'type': 'preReleaseVersions', 'id': 'v1', 'attributes': {'version': '0.1'}}]}

    def test_counts_only(self):
        out = live.asc_summary(self.DOCUMENT, NOW)
        first = out['builds'][0]
        self.assertEqual((first['build'], first['version'], first['internal_groups'], first['external_groups'], first['external_state']),
                         ('36', '0.1', 1, 1, 'E'))
        self.assertEqual(out['builds'][1]['external_groups'], 0)
        text = json.dumps(out)
        for private in ('Friends', 'Family', 'publicLink', 'https://x'):
            self.assertNotIn(private, text)


class Output(unittest.TestCase):
    def test_json_and_the_warning_line(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(live.main(['--section', 'server', '--json'], FakeWorld()), 0)
        self.assertIn('unknown', json.loads(out.getvalue())['server'])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(live.main(['--section', 'server'], FakeWorld()), 0)
        self.assertIn('do not fill it in from a comment', out.getvalue())

    def test_the_page_hash_is_over_bytes(self):
        self.assertEqual(hashlib.sha256('é'.encode()).digest(), hashlib.sha256(b'\xc3\xa9').digest())


if __name__ == '__main__':
    unittest.main()
