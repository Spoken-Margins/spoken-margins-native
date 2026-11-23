"""The gated TestFlight upload from GitHub (#4915): build-number refusals, the notice, the archive check, App Store
Connect reads, the tag, and the workflow's trust rules.

History runs real git in a temporary repository. App Store Connect and GitHub's API are replaced at the `get` and
`api` boundaries; the archive check reads a real Info.plist on disk.
"""
import contextlib
import io
import plistlib
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path
from types import SimpleNamespace

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import testflight_upload as tu  # noqa: E402
from test_workflow_files import parse  # noqa: E402

SHA = 'b' * 40
PROJECT = '''targets:
  App:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "{a}"
        MARKETING_VERSION: "0.1"
  Widget:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "{b}"
        MARKETING_VERSION: "0.1"
'''
PBX = 'CURRENT_PROJECT_VERSION = {n};\nMARKETING_VERSION = 0.1;\nCURRENT_PROJECT_VERSION = {n};\n'


def quiet(fn, *args, **kwargs):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = fn(*args, **kwargs)
    return code, out.getvalue()


class BuildNumber(unittest.TestCase):
    def test_every_target_and_the_generated_project_must_agree(self):
        self.assertEqual(tu.project_versions(PROJECT.format(a=37, b=37), PBX.format(n=37)), (37, '0.1'))
        with self.assertRaisesRegex(tu.Failure, 'more than one'):
            tu.project_versions(PROJECT.format(a=37, b=36), PBX.format(n=37))
        with self.assertRaisesRegex(tu.Failure, 'xcodegen generate'):
            tu.project_versions(PROJECT.format(a=37, b=37), PBX.format(n=36))
        with self.assertRaisesRegex(tu.Failure, 'whole number'):
            tu.project_versions(PROJECT.format(a='37a', b='37a'), PBX.format(n='37a'))
        with self.assertRaisesRegex(tu.Failure, 'no CURRENT_PROJECT_VERSION'):
            tu.project_versions('targets: {}\n', PBX.format(n=37))

    def test_the_real_project_reads(self):
        build, version = tu.project_versions((ROOT / 'project.yml').read_text(),
                                             (ROOT / 'SpokenMarginsNative.xcodeproj/project.pbxproj').read_text())
        self.assertGreater(build, 36)
        self.assertEqual(version, '0.1')

    def test_a_used_or_lower_number_is_refused_and_a_new_one_passes(self):
        tags = ['testflight/0.1-build-35', 'testflight/0.1-build-36', 'testflight/notes', 'v1.0']
        with self.assertRaisesRegex(tu.Failure, r'already uploaded \(testflight/0.1-build-36\)'):
            tu.refuse_used(36, tags)
        with self.assertRaisesRegex(tu.Failure, 'lower than the last upload, Build 36'):
            tu.refuse_used(34, tags)
        tu.refuse_used(37, tags)
        tu.refuse_used(1, [])

    def test_a_tag_under_another_version_still_counts(self):
        with self.assertRaisesRegex(tu.Failure, 'already uploaded'):
            tu.refuse_used(37, ['testflight/0.2-build-37'])
        self.assertEqual(tu.tag_numbers(['testflight/0.1-build-7', 'testflight/0.1-build-07x']), {7: 'testflight/0.1-build-7'})


class Repo:
    def __init__(self, folder):
        self.folder = folder
        self.run('init', '-q', '-b', 'main')
        self.run('config', 'user.email', 't@example.invalid')
        self.run('config', 'user.name', 'T')

    def run(self, *args):
        return subprocess.run(['git', '-C', str(self.folder), *args], check=True, capture_output=True, text=True).stdout

    def commit(self, subject, body=''):
        self.run('commit', '-q', '--allow-empty', '-m', subject, *(['-m', body] if body else []))
        return self.run('rev-parse', 'HEAD').strip()

    def merge_pr(self, number, title):
        self.run('checkout', '-q', '-b', f'pr{number}')
        self.commit(f'work for {number}')
        self.commit(f'more work for {number}')
        self.run('checkout', '-q', 'main')
        self.run('merge', '-q', '--no-ff', f'pr{number}', '-m', f'Merge pull request #{number} from org/pr{number}',
                 '-m', title)
        return self.run('rev-parse', 'HEAD').strip()


class History(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))
        self.git = lambda *args: self.repo.run(*args)
        self.repo.commit('start')
        self.repo.run('tag', 'testflight/0.1-build-36')
        self.repo.merge_pr(10, 'Fix the Timeline @someone')
        self.repo.commit('Direct commit on main')
        self.head = self.repo.merge_pr(11, 'Second change')

    def tearDown(self):
        self.tmp.cleanup()

    def test_lists_merged_prs_by_title_newest_first_without_their_branch_commits(self):
        self.assertEqual(tu.last_upload_tag(self.head, self.git), 'testflight/0.1-build-36')
        lines, total = tu.changes_since('testflight/0.1-build-36', self.head, self.git)
        self.assertEqual(total, 3)
        self.assertEqual(lines[0], '#11 Second change')
        self.assertTrue(lines[1].endswith('Direct commit on main'))
        self.assertEqual(lines[2], '#10 Fix the Timeline @someone')

    def test_a_long_list_is_capped(self):
        for n in range(tu.SHOWN + 5):
            self.repo.commit(f'c{n}')
        head = self.repo.run('rev-parse', 'HEAD').strip()
        lines, total = tu.changes_since('testflight/0.1-build-36', head, self.git)
        self.assertEqual(total, tu.SHOWN + 8)
        self.assertEqual(len(lines), tu.SHOWN + 1)
        self.assertEqual(lines[-1], 'and 8 more')

    def test_a_tag_not_in_this_history_is_not_the_last_upload(self):
        self.repo.run('checkout', '-q', '-b', 'side', 'testflight/0.1-build-36')
        self.repo.run('tag', 'testflight/0.1-build-99', self.repo.commit('elsewhere'))
        self.assertEqual(tu.last_upload_tag(self.head, self.git), 'testflight/0.1-build-36')

    def test_the_notice_pings_only_the_owner_and_links_the_run(self):
        args = SimpleNamespace(sha=self.head, build=37, version='0.1', last_tag='testflight/0.1-build-36',
                               share_links='on', run_url='https://run.example/1', dry_run=True)
        code, body = quiet(tu.notice, args, run=self.git)
        self.assertEqual(code, 0)
        self.assertEqual(body.count('@uncomposed'), 1)
        self.assertNotIn('@someone', body)
        self.assertIn('Build 37 is ready to upload to TestFlight', body)
        self.assertIn('Share-link creation is on', body)
        self.assertIn('https://run.example/1', body)
        self.assertIn(f'<!-- deploy-notice: testflight {self.head} -->', body)


class FakeApi:
    def __init__(self, refs=()):
        self.refs, self.calls = list(refs), []

    def __call__(self, *args, payload=None):
        self.calls.append((args, payload))
        if 'matching-refs' in args[-1]:
            return self.refs
        if args[-1].endswith('git/tags'):
            return {'sha': 't' * 40}
        return {}


class Tag(unittest.TestCase):
    def test_creates_an_annotated_tag_on_the_commit(self):
        api = FakeApi(refs=[{'ref': 'refs/tags/testflight/0.1-build-370'}])
        tu.create_tag('o/r', 'testflight/0.1-build-37', SHA, 'Build 37 (0.1): TestFlight upload\n\nflags: X=NO\n', api=api)
        posts = [(a[-1], p) for a, p in api.calls if '-X' in a]
        self.assertEqual(posts[0][0], 'repos/o/r/git/tags')
        self.assertEqual(posts[0][1]['object'], SHA)
        self.assertEqual(posts[0][1]['type'], 'commit')
        self.assertEqual(posts[1][1], {'ref': 'refs/tags/testflight/0.1-build-37', 'sha': 't' * 40})

    def test_never_moves_an_existing_tag(self):
        api = FakeApi(refs=[{'ref': 'refs/tags/testflight/0.1-build-37'}])
        with self.assertRaisesRegex(tu.Failure, 'already exists'):
            tu.create_tag('o/r', 'testflight/0.1-build-37', SHA, 'm', api=api)
        self.assertFalse([a for a, _ in api.calls if '-X' in a])

    def test_refuses_a_message_for_another_build(self):
        with tempfile.NamedTemporaryFile('w', suffix='.txt') as message:
            message.write('Build 36 (0.1): TestFlight upload\n\nflags: X=NO\n')
            message.flush()
            args = SimpleNamespace(build=37, version='0.1', sha=SHA, message_file=message.name)
            with self.assertRaisesRegex(tu.Failure, 'does not describe Build 37'):
                tu.tag(args, api=FakeApi())


class Gate(unittest.TestCase):
    """GitHub makes a missing environment with no rules on first use; the approval job must not pass on that."""

    ENV = {'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': True,
                                 'reviewers': [{'type': 'User', 'reviewer': {'login': 'uncomposed'}}]},
                                {'type': 'branch_policy'}],
           'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True}}
    MAIN = [{'name': 'main', 'type': 'branch'}]
    TAP = [{'state': 'approved', 'user': {'login': 'uncomposed'}, 'environments': [{'name': 'testflight-upload'}]}]

    def test_the_owners_tap_in_a_set_up_environment_passes(self):
        self.assertEqual(tu.gate_problems(self.ENV, self.MAIN, self.TAP), [])

    def test_an_environment_github_made_on_first_use_is_refused(self):
        problems = tu.gate_problems({'protection_rules': [], 'deployment_branch_policy': None}, [], [])
        self.assertEqual(len(problems), 4, problems)

    def test_each_missing_rule_and_any_other_approval_is_named(self):
        import copy
        no_self = copy.deepcopy(self.ENV)
        no_self['protection_rules'][0]['prevent_self_review'] = False
        other = copy.deepcopy(self.ENV)
        other['protection_rules'][0]['reviewers'][0]['reviewer']['login'] = 'someone'
        cases = [
            (no_self, self.MAIN, self.TAP, 'prevent self-review'),
            (other, self.MAIN, self.TAP, "require uncomposed's review"),
            (self.ENV, self.MAIN + [{'name': 'release/*', 'type': 'branch'}], self.TAP, 'main alone'),
            (self.ENV, [{'name': 'main', 'type': 'tag'}], self.TAP, 'main alone'),
            (self.ENV, self.MAIN, [dict(self.TAP[0], user={'login': 'someone'})], 'no approval'),
            (self.ENV, self.MAIN, [dict(self.TAP[0], state='rejected')], 'no approval'),
            (self.ENV, self.MAIN, [dict(self.TAP[0], environments=[{'name': 'web-deploy'}])], 'no approval'),
        ]
        for env, policies, approvals, words in cases:
            with self.subTest(words=words):
                problems = tu.gate_problems(env, policies, approvals)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn(words, problems[0])

    def test_reads_the_environment_its_branch_rule_and_this_runs_approvals(self):
        seen = []

        def api(path):
            seen.append(path)
            if path.endswith('deployment-branch-policies'):
                return {'branch_policies': self.MAIN}
            if path.endswith('/approvals'):
                return self.TAP
            return self.ENV
        with unittest.mock.patch.dict('os.environ', {'GITHUB_REPOSITORY': 'o/r'}):
            code, out = quiet(tu.gate, SimpleNamespace(run_id=42), api=api)
        self.assertEqual(code, 0, out)
        self.assertIn('repos/o/r/actions/runs/42/approvals', seen)
        self.assertIn('repos/o/r/environments/testflight-upload', seen)


class Archive(unittest.TestCase):
    def plist(self, **overrides):
        values = {'CFBundleVersion': '37', 'SMBuildCommit': SHA, 'SMPhoneBuild': 'NO', 'SMShareLinkCreation': 'NO'}
        values.update(overrides)
        return {k: v for k, v in values.items() if v is not None}

    def test_a_plain_release_archive_of_this_build_passes(self):
        self.assertEqual(tu.archive_problems(self.plist(), 37, SHA, 'off'), [])
        self.assertEqual(tu.archive_problems(self.plist(SMShareLinkCreation='YES'), 37, SHA, 'on'), [])

    def test_each_wrong_field_is_named(self):
        cases = {'CFBundleVersion': ('36', 'CFBundleVersion'), 'SMBuildCommit': ('c' * 40, 'SMBuildCommit'),
                 'SMPhoneBuild': ('YES', 'plain Release'), 'SMShareLinkCreation': ('YES', 'asked for off')}
        for key, (value, words) in cases.items():
            with self.subTest(key=key):
                problems = tu.archive_problems(self.plist(**{key: value}), 37, SHA, 'off')
                self.assertEqual(len(problems), 1, problems)
                self.assertIn(words, problems[0])

    def test_a_missing_or_unset_switch_is_refused(self):
        self.assertTrue(tu.archive_problems(self.plist(SMPhoneBuild=None), 37, SHA, 'off'))
        self.assertTrue(tu.archive_problems(self.plist(SMShareLinkCreation=''), 37, SHA, 'off'))
        self.assertTrue(tu.archive_problems(self.plist(SMShareLinkCreation=None), 37, SHA, 'off'))

    def test_reads_a_real_archive_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder, 'X.xcarchive/Products/Applications/SpokenMarginsApp.app')
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps(self.plist(SMPhoneBuild='YES')))
            args = SimpleNamespace(archive=str(app.parents[2]), build=37, sha=SHA, share_links='off')
            code, out = quiet(tu.archive, args)
            self.assertEqual(code, 1)
            self.assertIn('::error::SMPhoneBuild', out)


class AppStoreConnect(unittest.TestCase):
    def fake(self, builds_by_call):
        calls = iter(builds_by_call)

        def get(path):
            if path.startswith('/v1/apps'):
                return {'data': [{'id': 'APP', 'attributes': {'bundleId': 'com.spokenmargins.native'}},
                                 {'id': 'OTHER', 'attributes': {'bundleId': 'com.spokenmargins.native.other'}}]}
            self.assertIn('filter%5Bapp%5D=APP', path)
            self.assertIn('filter%5Bversion%5D=37', path)
            return {'data': next(calls)}
        return get

    def test_check_refuses_a_number_apple_already_has(self):
        get = self.fake([[{'attributes': {'version': '37', 'processingState': 'VALID'}}]])
        with self.assertRaisesRegex(tu.Failure, r'already has Build 37 \(VALID\)'):
            tu.asc_check(SimpleNamespace(build=37), get=get)

    def test_check_passes_when_only_a_lookalike_number_exists(self):
        get = self.fake([[{'attributes': {'version': '370'}}]])
        self.assertEqual(quiet(tu.asc_check, SimpleNamespace(build=37), get=get)[0], 0)

    def test_wait_polls_until_the_build_is_listed(self):
        get = self.fake([[], [], [{'attributes': {'version': '37', 'processingState': 'PROCESSING'}}]])
        slept = []
        code, out = quiet(tu.asc_wait, SimpleNamespace(build=37, timeout=600), get=get, sleep=slept.append,
                          clock=lambda: 0)
        self.assertEqual(code, 0)
        self.assertEqual(len(slept), 2)
        self.assertIn('PROCESSING', out)

    def test_wait_fails_on_timeout_or_an_invalid_build(self):
        ticks = iter(range(0, 10000, 100))
        with self.assertRaisesRegex(tu.Failure, 'did not list Build 37'):
            quiet(tu.asc_wait, SimpleNamespace(build=37, timeout=250), get=self.fake([[]] * 10),
                  sleep=lambda s: None, clock=lambda: next(ticks))
        with self.assertRaisesRegex(tu.Failure, 'INVALID'):
            quiet(tu.asc_wait, SimpleNamespace(build=37, timeout=250),
                  get=self.fake([[{'attributes': {'version': '37', 'processingState': 'INVALID'}}]]),
                  sleep=lambda s: None, clock=lambda: 0)

    def test_missing_secrets_fail_without_naming_values(self):
        with unittest.mock.patch.dict('os.environ', {'ASC_KEY_ID': '', 'ASC_ISSUER_ID': '', 'ASC_KEY_P8': ''}):
            with self.assertRaisesRegex(tu.Failure, 'missing ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8'):
                tu.asc_session()


class Workflow(unittest.TestCase):
    """The signing key reaches only main, only after the owner's tap, and the upload stays a plain Release build."""

    def setUp(self):
        self.path = ROOT / '.github/workflows/testflight-upload.yml'
        self.text = self.path.read_text()
        self.doc = parse(self.path)
        self.jobs = self.doc['jobs']

    def test_hand_started_on_main_only(self):
        triggers = next(self.doc[key] for key in ('on', True, 'true') if key in self.doc)
        self.assertEqual(set(triggers), {'workflow_dispatch'})
        self.assertEqual(self.doc['permissions'], {'contents': 'read'})
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertIn("github.ref == 'refs/heads/main'", job['if'])
                self.assertIn('refs/heads/main', job['steps'][0]['run'])
                for step in job['steps']:
                    uses = step.get('uses', '')
                    if uses:
                        self.assertRegex(uses, r'@[0-9a-f]{40}$', f'{uses} is not pinned to a commit')
                    if 'checkout' in uses:
                        self.assertFalse(step['with']['persist-credentials'])
                    if 'actions/cache' in uses:
                        # Only phone-build's main-only Swift package sources, read-only (#4664); never compiled code.
                        self.assertEqual(name, 'upload')
                        self.assertIn('actions/cache/restore@', uses)
                        self.assertEqual(step['with']['path'], '${{ env.SPM }}')
                        self.assertTrue(step['with']['key'].startswith('phone-spm-'))

    def test_the_gate_holds_no_secret_and_everything_with_the_key_after_it_needs_it(self):
        self.assertEqual(self.jobs['approve']['environment'], 'testflight-upload')
        self.assertNotIn('secrets.', str(self.jobs['approve']))
        self.assertNotIn('environment', self.jobs['notice'])
        self.assertNotIn('secrets.', str(self.jobs['notice']))
        self.assertIn('approve', self.jobs['upload']['needs'])
        self.assertIn("needs.approve.result == 'success'", self.jobs['upload']['if'])
        self.assertIn('upload', self.jobs['tag']['needs'])
        self.assertIn("needs.upload.result == 'success'", self.jobs['tag']['if'])
        self.assertIn("needs.check.result == 'success'", self.jobs['approve']['if'])
        self.assertIn('testflight_upload.py gate --run-id', self.jobs['approve']['steps'][-1]['run'])
        for name, job in self.jobs.items():
            if 'secrets.' in str(job) and name not in ('upload', 'tag'):
                # Before the tap only GET requests to App Store Connect may hold the key.
                self.assertEqual(name, 'check')
                runs = [s.get('run', '') for s in job['steps'] if 'secrets.' in str(s)]
                self.assertEqual(len(runs), 1)
                self.assertIn('testflight_upload.py asc-check', runs[0])

    def test_the_upload_is_the_macs_upload_and_is_checked_before_and_after(self):
        steps = self.jobs['upload']['steps']
        names = [s.get('name', '') for s in steps]
        runs = [s.get('run', '') for s in steps]
        export = next(i for i, r in enumerate(runs) if '-exportArchive' in r)
        self.assertIn('-exportOptionsPlist scripts/TestFlightUploadOptions.plist', runs[export])
        self.assertIn('-allowProvisioningUpdates', runs[export])
        self.assertLess(next(i for i, r in enumerate(runs) if 'asc-check' in r), export)
        self.assertLess(next(i for i, r in enumerate(runs) if 'testflight_upload.py archive' in r), export)
        self.assertGreater(next(i for i, r in enumerate(runs) if 'asc-wait' in r), export)
        self.assertIn('Remove the signing key', names)
        archive = runs[next(i for i, n in enumerate(names) if n == 'Archive the Release app')]
        self.assertIn('-configuration Release', archive)
        self.assertNotIn('-xcconfig', archive)
        self.assertNotIn('SM_PHONE_BUILD', archive)
        self.assertIn('SM_SHARE_LINK_CREATION=YES', archive)
        self.assertIn('[ "$SHARE_LINKS" = "on" ]', archive)

    def test_the_upload_plist_is_app_store_connect_upload_not_internal_only(self):
        options = plistlib.loads((ROOT / 'scripts/TestFlightUploadOptions.plist').read_bytes())
        self.assertEqual(options['method'], 'app-store-connect')
        self.assertEqual(options['destination'], 'upload')
        self.assertIs(options['testFlightInternalTestingOnly'], False)
        self.assertIs(options['manageAppVersionAndBuildNumber'], False)

    def test_the_share_link_input_defaults_off(self):
        triggers = next(self.doc[key] for key in ('on', True, 'true') if key in self.doc)
        share = triggers['workflow_dispatch']['inputs']['share_link_creation']
        self.assertEqual(share['default'], 'off')
        self.assertEqual(share['options'], ['off', 'on'])

    def test_the_tag_is_made_as_the_app(self):
        tag = self.jobs['tag']
        self.assertEqual(tag['environment'], 'agent-identity')
        token = next(s for s in tag['steps'] if 'create-github-app-token' in s.get('uses', ''))
        self.assertEqual(token['id'], 'app-token')
        last = tag['steps'][-1]
        self.assertEqual(last['env']['GH_TOKEN'], '${{ steps.app-token.outputs.token }}')
        self.assertIn('testflight_upload.py tag', last['run'])


if __name__ == '__main__':
    unittest.main()
