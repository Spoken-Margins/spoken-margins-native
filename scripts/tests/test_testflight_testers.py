"""Giving an uploaded build to its testers after the owner's tap (#5447): the plan, the release gate, group choice,
the idempotent assign, and the two workflows' trust rules.

App Store Connect is replaced at the `get` and `send` boundaries; tags come from a fake `git` that answers the three
commands the script runs.
"""
import contextlib
import datetime as dt
import io
import os
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
import testflight_testers as tt  # noqa: E402
from test_workflow_files import parse  # noqa: E402

SHA = 'c' * 40
TODAY = dt.date(2026, 11, 27)
FLAGS_OFF = 'Build 39 (0.1): TestFlight upload\n\nflags: SMPhoneBuild=NO SMShareLinkCreation=NO\n'
FLAGS_ON = 'Build 39 (0.1): TestFlight upload\n\nflags: SMPhoneBuild=NO SMShareLinkCreation=YES\n'


def fake_git(message, names=('testflight/0.1-build-38', 'testflight/0.1-build-39')):
    def run(*args):
        if args[:2] == ('tag', '-l') and len(args) == 3:
            return '\n'.join(names) + '\n'
        if args[0] == 'rev-list':
            return SHA + '\n'
        if args[:2] == ('tag', '-l'):
            return message
        raise AssertionError(args)
    return run


def group(gid, name, internal=False, all_builds=False, public=False):
    return {'id': gid, 'attributes': {'name': name, 'isInternalGroup': internal, 'hasAccessToAllBuilds': all_builds,
                                      'publicLinkEnabled': public}}


GROUPS = [group('g-int', 'Team', internal=True), group('g-auto', 'Everyone', internal=True, all_builds=True),
          group('g-pub', 'Friends beta', public=True), group('g-ext', 'Old invite list')]


class FakeAsc:
    """A small App Store Connect: one build, the groups above, which groups hold it, What to Test, review state."""

    def __init__(self, holding=(), whats_new='', state='READY_FOR_BETA_SUBMISSION', processing='VALID', groups=GROUPS):
        self.holding, self.whats_new, self.state, self.processing, self.groups = set(holding), whats_new, state, processing, groups
        self.sent = []

    def get(self, path):
        if path.startswith('/v1/apps?'):
            return {'data': [{'id': 'app1', 'attributes': {'bundleId': 'com.spokenmargins.native'}}]}
        if path.startswith('/v1/betaGroups?'):
            return {'data': self.groups}
        if path.startswith('/v1/builds?') and 'betaGroups' in path:
            gid = path.split('filter%5BbetaGroups%5D=')[1].split('&')[0]
            return {'data': [{'id': 'b39', 'attributes': {'version': '39'}}] if gid in self.holding else []}
        if path.startswith('/v1/builds?'):
            return {'data': [{'id': 'b39', 'attributes': {'version': '39', 'processingState': self.processing}}]}
        if path.endswith('/betaBuildLocalizations?limit=50'):
            return {'data': [{'id': 'loc1', 'attributes': {'locale': 'en-US', 'whatsNew': self.whats_new}}]}
        if path.endswith('/buildBetaDetail'):
            return {'data': {'attributes': {'externalBuildState': self.state}}}
        raise AssertionError(path)

    def send(self, method, path, payload):
        self.sent.append((method, path))
        if '/relationships/builds' in path:
            self.holding.add(path.split('/')[3])
        elif 'betaBuildLocalizations' in path:
            self.whats_new = payload['data']['attributes']['whatsNew']
        elif 'betaAppReviewSubmissions' in path:
            self.state = 'WAITING_FOR_BETA_REVIEW'


def quiet(fn, *args, **kwargs):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = fn(*args, **kwargs)
    return code, out.getvalue()


@contextlib.contextmanager
def outputs():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'out'
        path.write_text('')
        with unittest.mock.patch.dict(os.environ, {'GITHUB_OUTPUT': str(path), 'GITHUB_STEP_SUMMARY': ''}):
            yield path


class Groups(unittest.TestCase):
    def test_internal_groups_that_already_get_every_build_are_left_alone_and_the_public_group_is_the_friends_beta(self):
        internal, friends = tt.pick_groups(GROUPS)
        self.assertEqual([g['id'] for g in internal], ['g-int'])
        self.assertEqual(friends['id'], 'g-pub')

    def test_zero_or_two_public_external_groups_are_refused_not_guessed(self):
        for groups in (GROUPS[:2] + [GROUPS[3]], GROUPS + [group('g-pub2', 'Second link', public=True)]):
            with self.subTest(n=len(groups)), self.assertRaisesRegex(tt.Failure, 'one external group with a public link'):
                tt.pick_groups(groups)

    def test_an_internal_group_with_a_public_link_is_not_the_friends_beta(self):
        groups = [group('g-int', 'Team', internal=True, public=True), GROUPS[2]]
        self.assertEqual(tt.pick_groups(groups)[1]['id'], 'g-pub')


class Gate(unittest.TestCase):
    def test_share_links_off_passes_and_a_tag_without_the_flag_is_refused(self):
        self.assertTrue(tt.gate_verdict(39, FLAGS_OFF, TODAY)[0])
        allowed, reasons = tt.gate_verdict(39, 'Build 39 (0.1): TestFlight upload\n', TODAY)
        self.assertFalse(allowed)
        self.assertIn('missing', ' '.join(reasons))

    def test_share_links_on_follows_the_gate_record(self):
        record = {'llc': {'formed': False}}
        with unittest.mock.patch.object(tt.release_gate, 'read_record', return_value=record):
            self.assertFalse(tt.gate_verdict(39, FLAGS_ON, TODAY)[0])
            self.assertTrue(tt.gate_verdict(39, FLAGS_OFF, TODAY)[0])

    def test_a_missing_or_doubled_tag_is_refused(self):
        for names in ((), ('testflight/0.1-build-39', 'testflight/0.2-build-39')):
            with self.subTest(names=names), self.assertRaisesRegex(tt.Failure, 'expected one upload tag'):
                tt.upload_tag(39, fake_git(FLAGS_OFF, names))
        # Build 3 must not match testflight/0.1-build-39.
        with self.assertRaisesRegex(tt.Failure, 'found 0'):
            tt.upload_tag(3, fake_git(FLAGS_OFF))


class Plan(unittest.TestCase):
    def args(self, started_by='spoken-margins-agent[bot]'):
        return SimpleNamespace(build=39, started_by=started_by, timeout=60)

    def test_a_run_the_owner_started_is_refused_before_anything_is_read(self):
        with self.assertRaisesRegex(tt.Failure, 'cannot approve a run his own login started'):
            tt.plan(self.args('uncomposed'), get=lambda p: self.fail(p), run=lambda *a: self.fail(a))

    def test_a_refused_gate_changes_nothing_and_asks_nothing(self):
        with self.assertRaisesRegex(tt.Failure, 'release gate refused'):
            tt.plan(self.args(), get=lambda p: self.fail(p), run=fake_git('no flags'), today=TODAY)

    def test_a_build_already_with_its_testers_needs_no_approval(self):
        asc = FakeAsc(holding={'g-int', 'g-pub'}, whats_new='Try it', state='BETA_APPROVED')
        with outputs() as out:
            code, text = quiet(tt.plan, self.args(), get=asc.get, run=fake_git(FLAGS_OFF), today=TODAY)
            self.assertEqual(code, 0)
            self.assertIn('needed=false', out.read_text())
        self.assertIn('Nothing to do', text)

    def test_a_partly_assigned_build_lists_only_what_is_left(self):
        asc = FakeAsc(holding={'g-int'})
        with outputs() as out:
            code, text = quiet(tt.plan, self.args(), get=asc.get, run=fake_git(FLAGS_OFF), today=TODAY)
            written = out.read_text()
        self.assertEqual(code, 0)
        self.assertIn('needed=true', written)
        self.assertIn('expect=g-int,g-pub', written)
        self.assertIn(f'sha={SHA}', written)
        self.assertIn('to the friends beta', text)
        self.assertNotIn('to the internal group', text)
        for secret_name in ('Team', 'Everyone', 'Friends beta', 'Old invite list'):
            self.assertNotIn(secret_name, text, 'group names stay out of the public log')
        self.assertIn('What to Test', text)
        self.assertIn('beta review', text)
        self.assertEqual(asc.sent, [], 'the plan only reads')

    def test_it_waits_for_processing_and_stops_on_a_failed_build(self):
        asc = FakeAsc(processing='PROCESSING')
        clock = iter(range(0, 1000, 30))
        with self.assertRaisesRegex(tt.Failure, 'not processed within'):
            tt.wait_until_processed(asc.get, 'app1', 39, 60, sleep=lambda s: None, clock=lambda: next(clock))
        asc.processing = 'INVALID'
        with self.assertRaisesRegex(tt.Failure, 'INVALID'):
            tt.wait_until_processed(asc.get, 'app1', 39, 60, sleep=lambda s: None)

    def test_a_build_apple_will_not_take_for_review_is_refused(self):
        asc = FakeAsc(state='MISSING_EXPORT_COMPLIANCE')
        with self.assertRaisesRegex(tt.Failure, 'MISSING_EXPORT_COMPLIANCE'):
            quiet(tt.plan, self.args(), get=asc.get, run=fake_git(FLAGS_OFF), today=TODAY)


class Assign(unittest.TestCase):
    def test_a_lagging_read_after_the_writes_is_read_again_not_failed(self):
        asc = FakeAsc()
        real_get, calls = asc.get, {'n': 0}

        def lagging(path):
            if path.endswith('/buildBetaDetail') and asc.state == 'WAITING_FOR_BETA_REVIEW' and calls['n'] < 2:
                calls['n'] += 1
                return {'data': {'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}}}
            return real_get(path)
        asc.get = lagging
        code, text = quiet(tt.assign, SimpleNamespace(build=39, expect='g-int,g-pub'), asc=asc,
                           run=fake_git(FLAGS_OFF), today=TODAY, sleep=lambda s: None)
        self.assertEqual(code, 0, text)
        self.assertEqual(sum(1 for m, p in asc.sent if 'betaAppReviewSubmissions' in p), 1)

    def test_it_does_each_missing_step_in_order_and_checks_the_result(self):
        asc = FakeAsc()
        code, text = quiet(tt.assign, SimpleNamespace(build=39, expect='g-int,g-pub'), asc=asc,
                           run=fake_git(FLAGS_OFF), today=TODAY)
        self.assertEqual(code, 0, text)
        self.assertEqual(asc.sent, [('POST', '/v1/betaGroups/g-int/relationships/builds'),
                                    ('PATCH', '/v1/betaBuildLocalizations/loc1'),
                                    ('POST', '/v1/betaGroups/g-pub/relationships/builds'),
                                    ('POST', '/v1/betaAppReviewSubmissions')])
        self.assertIn('Build 39', asc.whats_new)

    def test_a_rerun_after_everything_is_done_sends_nothing(self):
        asc = FakeAsc(holding={'g-int', 'g-pub'}, whats_new='x', state='IN_BETA_TESTING')
        code, _ = quiet(tt.assign, SimpleNamespace(build=39, expect='g-int,g-pub'), asc=asc,
                        run=fake_git(FLAGS_OFF), today=TODAY)
        self.assertEqual((code, asc.sent), (0, []))

    def test_groups_that_changed_since_the_approved_plan_are_refused(self):
        asc = FakeAsc()
        with self.assertRaisesRegex(tt.Failure, 'changed since the plan'):
            tt.assign(SimpleNamespace(build=39, expect='g-int,g-other'), asc=asc, run=fake_git(FLAGS_OFF), today=TODAY)
        self.assertEqual(asc.sent, [])

    def test_a_gate_that_now_refuses_sends_nothing(self):
        asc = FakeAsc()
        with self.assertRaisesRegex(tt.Failure, 'now refuses'):
            tt.assign(SimpleNamespace(build=39, expect='g-int,g-pub'), asc=asc, run=fake_git('no flags'), today=TODAY)
        self.assertEqual(asc.sent, [])


class Token(unittest.TestCase):
    def test_reads_and_writes_share_a_token_made_again_after_eight_minutes(self):
        moments = iter([dt.datetime(2026, 11, 27, 12, 0, tzinfo=dt.timezone.utc),
                        dt.datetime(2026, 11, 27, 12, 5, tzinfo=dt.timezone.utc),
                        dt.datetime(2026, 11, 27, 12, 9, tzinfo=dt.timezone.utc)])
        made, used = [], []
        asc = tt.Asc(env={'ASC_KEY_ID': 'k', 'ASC_ISSUER_ID': 'i', 'ASC_KEY_P8': 'p'},
                     mint=lambda *a: made.append(a[-1]) or f't{len(made)}',
                     fetch=lambda path, token: used.append(token) or {},
                     send=lambda method, path, token, payload: used.append(token), now=lambda: next(moments))
        asc.get('/a')
        asc.send('POST', '/b', {})
        asc.get('/c')
        self.assertEqual(used, ['t1', 't1', 't2'])

    def test_a_missing_key_is_named(self):
        with self.assertRaisesRegex(tt.Failure, 'ASC_KEY_P8'):
            tt.Asc(env={'ASC_KEY_ID': 'k', 'ASC_ISSUER_ID': 'i'})


def triggers(doc):
    return next(doc[key] for key in ('on', True, 'true') if key in doc)


class Workflow(unittest.TestCase):
    """The key changes App Store Connect only on main, only after the owner's tap in the upload's own environment."""

    def setUp(self):
        self.doc = parse(ROOT / '.github/workflows/testflight-testers.yml')
        self.jobs = self.doc['jobs']

    def test_hand_started_on_main_only_with_pinned_actions(self):
        self.assertEqual(set(triggers(self.doc)), {'workflow_dispatch'})
        self.assertEqual(self.doc['permissions'], {'contents': 'read'})
        self.assertEqual(self.doc['run-name'], 'Testers for Build ${{ inputs.build }}')
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertIn("github.ref == 'refs/heads/main'", job['if'])
                self.assertIn('refs/heads/main', job['steps'][0]['run'])
                for step in job['steps']:
                    if step.get('uses'):
                        self.assertRegex(step['uses'], r'@[0-9a-f]{40}$')
                    if 'checkout' in step.get('uses', ''):
                        self.assertFalse(step['with']['persist-credentials'])
                    self.assertNotIn('${{ inputs', step.get('run', ''), 'inputs reach the shell only through env')

    def test_the_gate_is_the_uploads_environment_and_every_write_comes_after_it(self):
        approve, assign = self.jobs['approve'], self.jobs['assign']
        self.assertEqual(approve['environment'], 'testflight-upload')
        self.assertNotIn('secrets.', str(approve))
        self.assertNotIn('environment', self.jobs['notice'])
        self.assertNotIn('secrets.', str(self.jobs['notice']))
        self.assertIn('testflight_upload.py gate --run-id', approve['steps'][-1]['run'])
        self.assertIn("needs.check.outputs.needed == 'true'", approve['if'])
        self.assertIn('approve', assign['needs'])
        self.assertIn("needs.approve.result == 'success'", assign['if'])
        self.assertIn('testflight_testers.py assign', assign['steps'][-1]['run'])
        self.assertIn('--expect "$EXPECT"', assign['steps'][-1]['run'])
        # Before the tap only the read-only plan holds the key.
        for name, job in self.jobs.items():
            if 'secrets.' in str(job) and name != 'assign':
                self.assertEqual(name, 'check')
                runs = [s.get('run', '') for s in job['steps'] if 'secrets.' in str(s)]
                self.assertEqual(len(runs), 1)
                self.assertIn('testflight_testers.py plan', runs[0])

    def test_check_refuses_a_run_started_by_the_owners_login_and_its_wait_fits_the_job(self):
        plan = next(s for s in self.jobs['check']['steps'] if s.get('id') == 'plan')
        self.assertEqual(plan['env']['STARTED_BY'], '${{ github.triggering_actor }}')
        self.assertIn('--timeout 2700', plan['run'])
        self.assertGreater(self.jobs['check']['timeout-minutes'] * 60, 2700)


class RequestWorkflow(unittest.TestCase):
    """The hourly relay starts the run as the App, runs no branch code, and never starts a second run for a build."""

    def setUp(self):
        self.doc = parse(ROOT / '.github/workflows/testflight-testers-request.yml')
        self.job = self.doc['jobs']['start']

    def test_schedule_or_hand_start_only_and_no_permissions(self):
        self.assertEqual(set(triggers(self.doc)), {'schedule', 'workflow_dispatch'})
        self.assertEqual(self.doc['permissions'], {})

    def test_it_runs_no_branch_code_and_starts_main_as_the_app_once_per_build(self):
        steps = self.job['steps']
        self.assertFalse([s for s in steps if 'checkout' in s.get('uses', '')])
        for step in steps:
            if step.get('uses'):
                self.assertRegex(step['uses'], r'@[0-9a-f]{40}$')
        self.assertEqual(self.job['environment'], 'agent-identity')
        last = steps[-1]
        self.assertEqual(last['env']['GH_TOKEN'], '${{ steps.app-token.outputs.token }}')
        self.assertIn('set -euo pipefail', last['run'])
        self.assertIn('grep -qx "Testers for Build $build"', last['run'])
        self.assertIn('testflight-testers.yml/dispatches" \\\n  -f ref=main', last['run'].replace('            ', '  '))
        self.assertNotIn('|| true', last['run'], 'a failed read of past runs must not start a duplicate')


if __name__ == '__main__':
    unittest.main()
