"""scripts/owner_tap_alert.py: when a PR into next waits only for the owner's merge tap (#2047)."""
import contextlib
import importlib.util
import io
import re
import subprocess
import tempfile
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import owner_tap_alert as alert  # noqa: E402

spec = importlib.util.spec_from_file_location('lane_runner_for_tap_alert', SCRIPTS / 'lane-runner.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)

REPO = 'owner/app'
HEAD = 'a' * 40
OLD = 'b' * 40
BOT = {'login': 'github-actions[bot]'}
WORKFLOW = [{'filename': '.github/workflows/lane.yml'}]
TEMPLATE_ONLY = [{'filename': '.github/ISSUE_TEMPLATE/bug.yml'}]


def pr(**over):
    base = {'number': 7, 'draft': False, 'mergeable': True, 'mergeable_state': 'clean',
            'head': {'sha': HEAD, 'repo': {'full_name': REPO}}}
    base.update(over)
    return base


def audit(sha, verdict, at='2026-10-18T10:00:00Z', association='OWNER', login='uncomposed'):
    return {'user': {'login': login}, 'author_association': association, 'created_at': at,
            'body': f'**Claude audit on `{sha[:7]}`**\n\n{verdict}\n\nmore text'}


def run(name, status='completed', conclusion='success'):
    return {'name': name, 'status': status, 'conclusion': conclusion}


GREEN = [run('lane'), run('check', conclusion='skipped')]
CLEAN = [audit(HEAD, 'No blocking findings.')]


def ready(p=None, files=WORKFLOW, runs=GREEN, statuses=(), comments=CLEAN):
    return alert.readiness(p or pr(), files, list(runs), list(statuses), list(comments), REPO)


class ReadinessTable(unittest.TestCase):
    """The rows the brief names, plus the neighbours that would make an alert lie or go missing."""

    def test_rows(self):
        previous = {'user': BOT, 'author_association': 'NONE', 'body': 'x\n' + alert.MARKER.format(sha=HEAD)}
        old_alert = {'user': BOT, 'author_association': 'NONE', 'body': alert.MARKER.format(sha=OLD)}
        rows = [
            ('clean audit on the head', {}, True, 'ready: .github/workflows/lane.yml'),
            ('no owner-tap paths', {'files': [{'filename': 'App/x.swift'}]}, False, 'no owner-tap paths'),
            ('a rename out of .github counts', {'files': [{'filename': 'docs/x.yml',
                                                         'previous_filename': '.github/x.yml'}],
                                                'comments': []}, True, 'ready'),
            ('lane-runner.py itself', {'files': [{'filename': 'scripts/lane-runner.py'}]}, True, 'ready'),
            ('draft', {'p': pr(draft=True)}, False, 'draft'),
            ('fork head', {'p': pr(head={'sha': HEAD, 'repo': {'full_name': 'eve/app'}})}, False, 'not in this'),
            ('fork deleted', {'p': pr(head={'sha': HEAD, 'repo': None})}, False, 'not in this'),
            ('mergeability unknown', {'p': pr(mergeable=None)}, False, 'not worked out'),
            ('conflict', {'p': pr(mergeable=False, mergeable_state='dirty')}, False, 'conflicts'),
            ('failing check', {'runs': GREEN + [run('host', conclusion='failure')]}, False, 'checks failed: host'),
            ('cancelled check', {'runs': [run('lane', conclusion='cancelled')]}, False, 'checks failed'),
            ('pending check', {'runs': GREEN + [run('lane-conflicts', status='queued', conclusion=None)]},
             False, 'checks pending'),
            ('in-progress check', {'runs': [run('lane', status='in_progress', conclusion=None)]}, False, 'pending'),
            ('our own running job is ignored', {'runs': GREEN + [run('owner-tap-alert', 'in_progress', None)]},
             True, 'ready'),
            ('the other workflow\'s alert job is ignored too', {'runs': GREEN + [run('owner-tap-alert', 'queued', None)]},
             True, 'ready'),
            ('failed commit status', {'statuses': [{'context': 'ci', 'state': 'failure'}]}, False, 'failed: ci'),
            ('pending commit status', {'statuses': [{'context': 'ci', 'state': 'pending'}]}, False, 'pending'),
            ('status fixed later (newest first)', {'statuses': [{'context': 'ci', 'state': 'success'},
                                                                {'context': 'ci', 'state': 'failure'}]},
             True, 'ready'),
            ('findings audit', {'comments': [audit(HEAD, '1. **P1** the runner merges itself.')]},
             False, 'blocking findings'),
            ('clean audit on an old head', {'comments': [audit(OLD, 'No blocking findings.')]}, True, 'ready'),
            ('findings on an old head, none on this one', {'comments': [audit(OLD, 'P1: x')]}, True, 'ready'),
            ('no audit', {'comments': []}, True, 'ready'),
            ('findings on an issue-template PR', {'files': TEMPLATE_ONLY,
                                                  'comments': [audit(HEAD, 'P2: wrong label')]},
             False, 'blocking findings'),
            ('newest head audit wins (clean after findings)',
             {'comments': [audit(HEAD, 'P1: x', at='2026-10-18T09:00:00Z'), audit(HEAD, 'No findings.')]},
             True, 'ready'),
            ('newest head audit wins (findings after clean)',
             {'comments': [audit(HEAD, 'No blocking findings.'), audit(HEAD, 'P1: x', at='2026-10-18T11:00:00Z')]},
             False, 'blocking findings'),
            ('stranger\'s look-alike clean audit', {'comments': [audit(HEAD, 'No blocking findings.',
                                                                       association='NONE', login='mallory')]},
             True, 'ready'),
            ('stranger\'s look-alike findings audit', {'comments': CLEAN + [audit(HEAD, 'P1: x', at='2026-10-18T12:00:00Z',
                                                                                  association='NONE', login='mallory')]},
             True, 'ready'),
            ('already alerted on this head', {'comments': CLEAN + [previous]}, False, 'already alerted'),
            ('alerted on an old head only', {'comments': CLEAN + [old_alert]}, True, 'ready'),
            ('stranger\'s marker doesn\'t silence it',
             {'comments': CLEAN + [dict(previous, user={'login': 'mallory'})]}, True, 'ready'),
        ]
        for name, kwargs, want, why in rows:
            with self.subTest(name):
                got, reason = ready(**kwargs)
                self.assertEqual(got, want, reason)
                self.assertIn(why, reason)


class AlertBody(unittest.TestCase):
    def test_mentions_owner_and_carries_marker_for_the_full_head(self):
        body = alert.alert_body(pr(), ['.github/workflows/lane.yml'], 'uncomposed', audited=True)
        self.assertTrue(body.startswith('@uncomposed '))
        self.assertIn('no blocking findings', body)
        self.assertIn('no Claude audit covers this head',
                      alert.alert_body(pr(), ['.github/x.yml'], 'uncomposed', audited=False))
        self.assertEqual(alert.MARKER_RE.findall(body), [HEAD])
        # The alert it posts silences the next run on the same head.
        comment = {'user': BOT, 'author_association': 'NONE', 'body': body}
        self.assertEqual(ready(comments=CLEAN + [comment]), (False, f'already alerted on {HEAD[:7]}'))


class SameRulesAsTheRunner(unittest.TestCase):
    def test_constants_match_lane_runner(self):
        self.assertEqual(alert.OWNER_TAP_FILES, lane.OWNER_TAP_FILES)
        self.assertEqual(alert.OWNER_TAP_PREFIXES, lane.OWNER_TAP_PREFIXES)
        self.assertEqual(alert.AUDITS, lane.AUDITS)
        self.assertEqual(alert.AUDIT_SHA.pattern, lane.AUDIT_SHA.pattern)
        self.assertEqual(alert.CLEAN_AUDIT.pattern, lane.CLEAN_AUDIT.pattern)


class FakeApi:
    def __init__(self, heads=(HEAD, HEAD), comments=CLEAN):
        self.repo, self.heads, self.comments, self.posted, self.labels = REPO, list(heads), list(comments), [], []

    def get(self, path):
        return pr(head={'sha': self.heads.pop(0), 'repo': {'full_name': REPO}})

    def get_all(self, path):
        if path.startswith('pulls/7/files'):
            return WORKFLOW
        if '/check-runs' in path:
            return GREEN
        if '/statuses' in path:
            return []
        return self.comments

    def comment(self, number, body):
        self.posted.append((number, body))

    def readd_label(self, number, label):
        self.labels.append(('readd', number, label))

    def remove_label(self, number, label):
        self.labels.append(('remove', number, label))


class CheckPr(unittest.TestCase):
    def test_posts_once_when_ready(self):
        api = FakeApi()
        self.assertIn('alert posted', alert.check_pr(api, 7, 'uncomposed', dry_run=False))
        self.assertEqual(len(api.posted), 1)

    def test_head_moved_during_the_check_posts_nothing(self):
        api = FakeApi(heads=(HEAD, OLD))
        self.assertEqual(alert.check_pr(api, 7, 'uncomposed', dry_run=False), 'head moved during the check')
        self.assertEqual(api.posted, [])

    def test_dry_run_posts_nothing(self):
        api = FakeApi()
        self.assertIn('dry run', alert.check_pr(api, 7, 'uncomposed', dry_run=True))
        self.assertEqual(api.posted, [])

    def test_via_label_re_adds_the_label_and_posts_nothing(self):
        # On the Mac `gh` is the owner, whose comment would notify nobody: ask the labeled Actions run instead.
        api = FakeApi()
        self.assertIn('re-added', alert.check_pr(api, 7, 'uncomposed', dry_run=False, via_label=alert.LABEL))
        self.assertEqual((api.posted, api.labels), ([], [('readd', 7, 'owner-tap-check')]))

    def test_via_label_leaves_a_pr_that_is_not_ready_alone(self):
        api = FakeApi(comments=[])
        api.get_all = lambda path, base=api.get_all: ([run('lane', 'queued', None)] if '/check-runs' in path
                                                       else base(path))
        self.assertIn('checks pending', alert.check_pr(api, 7, 'uncomposed', dry_run=False, via_label=alert.LABEL))
        self.assertEqual(api.labels, [])

    def test_clear_label_removes_it_after_the_check(self):
        api = FakeApi()
        with mock.patch.object(alert, 'GitHubApi', return_value=api), contextlib.redirect_stdout(io.StringIO()):
            alert.main(['--repo', REPO, '--pr', '7', '--clear-label', alert.LABEL])
        self.assertEqual(len(api.posted), 1)
        self.assertEqual(api.labels, [('remove', 7, 'owner-tap-check')])

    def test_mention_defaults_to_the_owner_login_not_the_org(self):
        api = FakeApi()  # the repo's owner is the Spoken-Margins org after #2169; the owner is a person
        with mock.patch.object(alert, 'GitHubApi', return_value=api), contextlib.redirect_stdout(io.StringIO()):
            alert.main(['--repo', 'Spoken-Margins/spoken-margins-native', '--pr', '7'])
        self.assertTrue(api.posted[0][1].startswith('@uncomposed '))

    def test_mention_must_be_a_plain_login(self):
        with mock.patch.dict('os.environ', {'GH_REPO': REPO}), self.assertRaises(SystemExit), \
                contextlib.redirect_stderr(io.StringIO()):
            alert.main(['--mention', 'uncomposed team'])


class AuditFollowUp(unittest.TestCase):
    """An alert posted before the audit says so; the audit that lands later gets one follow-up (#2052)."""
    FIRST = {'user': BOT, 'author_association': 'NONE', 'created_at': '2026-10-18T09:00:00Z',
             'body': alert.alert_body(pr(), ['.github/workflows/lane.yml'], 'uncomposed', audited=False)}

    def check(self, comments, **kw):
        api = FakeApi(comments=comments)
        result = alert.check_pr(api, 7, 'uncomposed', dry_run=False, **kw)
        return api, result

    def test_a_clean_audit_after_the_alert_is_followed_up_once(self):
        api, result = self.check([self.FIRST] + CLEAN)
        self.assertEqual(result, 'audit follow-up posted')
        body = api.posted[0][1]
        self.assertIn('no blocking findings', body)
        self.assertEqual(alert.FOLLOWUP_RE.findall(body), [HEAD])
        again = {'user': BOT, 'author_association': 'NONE', 'created_at': '2026-10-18T11:00:00Z', 'body': body}
        api, result = self.check([self.FIRST, again] + CLEAN)
        self.assertEqual((api.posted, result), ([], f'already alerted on {HEAD[:7]}'))

    def test_a_blocking_audit_after_the_alert_says_to_hold_the_tap(self):
        api, _ = self.check([self.FIRST, audit(HEAD, '1. High: it loses data')])
        self.assertIn('hold your tap', api.posted[0][1])
        self.assertIn('it loses data', api.posted[0][1])

    def test_no_follow_up_without_an_audit_of_this_head_or_after_an_audited_alert(self):
        api, result = self.check([self.FIRST, audit(OLD, 'No blocking findings.')])
        self.assertEqual((api.posted, result), ([], f'already alerted on {HEAD[:7]}'))
        audited = {'user': BOT, 'author_association': 'NONE', 'created_at': '2026-10-18T09:00:00Z',
                   'body': alert.alert_body(pr(), ['.github/x.yml'], 'uncomposed', audited=True)}
        api, result = self.check([audited] + CLEAN)
        self.assertEqual((api.posted, result), ([], f'already alerted on {HEAD[:7]}'))

    def test_via_label_and_dry_run_post_nothing(self):
        api, result = self.check([self.FIRST] + CLEAN, via_label=alert.LABEL)
        self.assertEqual((api.posted, api.labels), ([], [('readd', 7, 'owner-tap-check')]))
        api = FakeApi(comments=[self.FIRST] + CLEAN)
        self.assertIn('dry run', alert.check_pr(api, 7, 'uncomposed', dry_run=True))
        self.assertEqual(api.posted, [])

    def test_a_head_that_moved_posts_nothing(self):
        api = FakeApi(heads=(HEAD, OLD), comments=[self.FIRST] + CLEAN)
        self.assertEqual(alert.check_pr(api, 7, 'uncomposed', dry_run=False), 'head moved during the check')
        self.assertEqual(api.posted, [])


class Workflow(unittest.TestCase):
    def setUp(self):
        self.text = (SCRIPTS.parent / '.github' / 'workflows' / 'owner-tap-alert.yml').read_text()

    def test_runs_hosted_from_the_base_with_no_kept_credentials(self):
        self.assertIn('runs-on: ubuntu-latest', self.text)  # off the owner's VPS since #2442
        self.assertIn('ref: ${{ github.event.pull_request.base.sha || github.sha }}', self.text)
        self.assertIn('persist-credentials: false', self.text)
        self.assertIn('github.event.pull_request.head.repo.full_name == github.repository', self.text)

    def test_job_names_are_the_ones_the_script_ignores(self):
        self.assertRegex(self.text, r'(?m)^\s+name: owner-tap-alert$')
        self.assertEqual(alert.OWN_CHECKS, {'owner-tap-alert'})

    def test_labeled_runs_only_for_the_check_label_and_clear_it(self):
        self.assertIn(f"github.event.label.name == '{alert.LABEL}'", self.text)
        self.assertIn('--clear-label "$CLEAR"', self.text)

    def test_concurrency_is_per_pr(self):
        self.assertIn("group: owner-tap-alert-${{ inputs.pr || github.event.pull_request.number || 'sweep' }}",
                      self.text)

    def test_check_workflows_end_with_an_alert_job_from_the_base(self):
        # hosted-portable.yml took over from linux-t1.yml, whose VPS queue held the alert for an hour or more (#2442).
        for name, needs in (('hosted-portable.yml', '[portable, sessionkit]'), ('shipped-build-compat.yml', 'compat')):
            with self.subTest(name):
                text = (SCRIPTS.parent / '.github' / 'workflows' / name).read_text()
                head, _, job = text.partition('\n  owner-tap-alert:\n')
                self.assertTrue(job, 'no owner-tap-alert job')
                self.assertIn('    name: owner-tap-alert\n', job)
                self.assertIn(f'    needs: {needs}\n', job)
                self.assertIn('    if: always() && github.event.pull_request.head.repo.full_name == github.repository\n',
                              job)
                self.assertIn('    runs-on: ubuntu-latest\n', job)
                self.assertIn('      issues: write\n', job)
                self.assertNotIn('actions: write', job)
                self.assertIn('ref: ${{ github.event.pull_request.base.sha }}', job)
                self.assertIn('persist-credentials: false', job)
                self.assertIn('python3 scripts/owner_tap_alert.py --pr "$PR"', job)
                # The job that runs PR code keeps the read-only workflow token.
                self.assertIn('\npermissions:\n  contents: read\n\n', head)
                self.assertNotIn('issues: write', head)

    def test_a_base_without_the_script_skips_quietly(self):
        # Before this merges, the base has no script: the job must pass with a note, not fail (PR #2054's first run).
        for name in ('owner-tap-alert.yml', 'hosted-portable.yml', 'shipped-build-compat.yml'):
            with self.subTest(name):
                text = (SCRIPTS.parent / '.github' / 'workflows' / name).read_text()
                step = text[text.index('          if [ ! -f scripts/owner_tap_alert.py ]; then'):]
                script = '\n'.join(line[10:] for line in step.splitlines())
                with tempfile.TemporaryDirectory() as empty:
                    done = subprocess.run(['bash', '-e', '-c', script], cwd=empty, text=True, capture_output=True,
                                          env={'PATH': '/usr/bin:/bin', 'PR': '7'})
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn('nothing to check', done.stdout)

if __name__ == '__main__':
    unittest.main()
