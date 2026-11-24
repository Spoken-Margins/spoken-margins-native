"""scripts/deploy_wait_alert.py: the owner hears when a deploy waits for his approval (#5255)."""
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import deploy_wait_alert as dwa  # noqa: E402

REPO = 'owner/app'
NOW = datetime(2026, 11, 23, 16, 45, tzinfo=timezone.utc)
BOT = {'login': 'github-actions[bot]'}


def wf_run(rid, created, status='completed', conclusion=None, updated=None, wf=7, name='deploy-web'):
    return {'id': rid, 'workflow_id': wf, 'name': name, 'head_sha': 'abcdef1234567890' * 2 + 'abcdef12',
            'created_at': created, 'updated_at': updated or created, 'status': status, 'conclusion': conclusion,
            'html_url': f'https://github.com/{REPO}/actions/runs/{rid}'}


OLD = wf_run(100, '2026-11-23T16:15:00Z', status='waiting')
ISSUE = {'number': 9, 'title': dwa.ISSUE_TITLE, 'user': BOT, 'state': 'open'}


class Fake:
    """A `gh api` runner over canned answers; records every write."""

    def __init__(self, waiting=(), siblings=(), issues=(), comments=(), envs=('production',)):
        self.waiting, self.siblings, self.issues = list(waiting), list(siblings), list(issues)
        self.comments, self.envs, self.writes = list(comments), list(envs), []

    def __call__(self, args):
        if '-X' in args:
            method, path = args[1], args[2].split(f'repos/{REPO}/')[1]
            fields = {args[i + 1].split('=', 1)[0]: args[i + 1].split('=', 1)[1]
                      for i, a in enumerate(args) if a == '-f'}
            self.writes.append((method, path, fields))
            return json.dumps({'number': 9} if path == 'issues' else {})
        path = args[-1].split(f'repos/{REPO}/')[1]
        if path.startswith('actions/runs?status=waiting'):
            return json.dumps([{'workflow_runs': self.waiting}])
        if path.endswith('/pending_deployments'):
            return json.dumps([{'environment': {'name': e}} for e in self.envs])
        if path.startswith('actions/workflows/'):
            return json.dumps([{'workflow_runs': self.siblings}])
        if path.startswith('issues?'):
            return json.dumps([self.issues])
        if path.endswith('/comments?per_page=100'):
            return json.dumps([self.comments])
        raise AssertionError(path)

    def comment_bodies(self):
        return [f['body'] for m, p, f in self.writes if p.endswith('/comments')]


def go(fake):
    return dwa.run_once(dwa.Gh(REPO, fake), 'uncomposed', NOW)


def marker_comment(rid, kind='alert'):
    marker = dwa.ALERT_MARKER if kind == 'alert' else dwa.STALE_MARKER
    return {'user': BOT, 'body': marker.format(id=rid) + '\nold'}


class DeployWaitAlert(unittest.TestCase):
    def test_none_waiting_and_no_issue_does_nothing(self):
        f = Fake()
        self.assertEqual(go(f), ['nothing waiting'])
        self.assertEqual(f.writes, [])

    def test_one_waiting_new_creates_issue_and_alerts_once(self):
        f = Fake(waiting=[OLD], siblings=[OLD])
        go(f)
        self.assertEqual(f.writes[0][:2], ('POST', 'issues'))
        self.assertEqual(f.writes[0][2]['title'], dwa.ISSUE_TITLE)
        [body] = f.comment_bodies()
        for needle in ('@uncomposed', '<!-- deploy-wait-alert: 100 -->', 'deploy-web', 'production', '`abcdef1`',
                       '30 min', 'actions/runs/100', 'Review deployments'):
            self.assertIn(needle, body)

    def test_already_alerted_run_is_not_mentioned_again(self):
        f = Fake(waiting=[OLD], siblings=[OLD], issues=[ISSUE], comments=[marker_comment(100)])
        go(f)
        self.assertEqual(f.writes, [])

    def test_marker_from_a_non_bot_author_does_not_count(self):
        forged = {'user': {'login': 'someone'}, 'body': dwa.ALERT_MARKER.format(id=100)}
        f = Fake(waiting=[OLD], siblings=[OLD], issues=[ISSUE], comments=[forged])
        go(f)
        self.assertEqual(len(f.comment_bodies()), 1)

    def test_run_without_pending_deployments_is_ignored(self):
        f = Fake(waiting=[OLD], envs=())
        self.assertEqual(go(f), ['nothing waiting'])
        self.assertEqual(f.writes, [])

    def test_stale_old_blocks_newer_pending_names_both_links(self):
        newer = wf_run(200, '2026-11-23T16:40:00Z', status='pending')
        f = Fake(waiting=[OLD], siblings=[OLD, newer], issues=[ISSUE], comments=[marker_comment(100)])
        go(f)
        [body] = f.comment_bodies()
        self.assertIn('<!-- deploy-wait-stale: 100 -->', body)
        self.assertIn('blocking a newer one', body)
        self.assertIn('actions/runs/100', body)
        self.assertIn('actions/runs/200', body)
        self.assertIn('Reject the old run', body)

    def test_stale_followup_comes_once(self):
        newer = wf_run(200, '2026-11-23T16:40:00Z', status='queued')
        f = Fake(waiting=[OLD], siblings=[OLD, newer], issues=[ISSUE],
                 comments=[marker_comment(100), marker_comment(100, 'stale')])
        go(f)
        self.assertEqual(f.writes, [])

    def test_recently_cancelled_newer_run_counts_old_cancel_does_not(self):
        recent = wf_run(200, '2026-11-23T16:30:00Z', conclusion='cancelled', updated='2026-11-23T16:40:00Z')
        ancient = wf_run(201, '2026-11-23T16:20:00Z', conclusion='cancelled', updated='2026-11-20T11:00:00Z')
        self.assertEqual([r['id'] for r in dwa.blocked_runs(OLD, [OLD, recent, ancient], NOW)], [200])

    def test_other_workflow_and_older_runs_do_not_block(self):
        other = wf_run(300, '2026-11-23T16:40:00Z', status='pending', wf=8)
        older = wf_run(301, '2026-11-23T10:00:00Z', status='pending')
        self.assertEqual(dwa.blocked_runs(OLD, [OLD, other, older], NOW), [])

    def test_closed_issue_is_reopened_before_a_new_alert(self):
        f = Fake(waiting=[OLD], siblings=[OLD], issues=[dict(ISSUE, state='closed')])
        go(f)
        self.assertEqual(f.writes[0], ('PATCH', 'issues/9', {'state': 'open'}))
        self.assertEqual(len(f.comment_bodies()), 1)

    def test_closed_issue_with_everything_alerted_stays_closed(self):
        f = Fake(waiting=[OLD], siblings=[OLD], issues=[dict(ISSUE, state='closed')], comments=[marker_comment(100)])
        go(f)
        self.assertEqual(f.writes, [])

    def test_nothing_waiting_closes_an_open_issue_with_a_comment(self):
        f = Fake(issues=[ISSUE])
        go(f)
        self.assertEqual([w[:2] for w in f.writes], [('POST', 'issues/9/comments'), ('PATCH', 'issues/9')])
        self.assertEqual(f.writes[1][2], {'state': 'closed'})

    def test_nothing_waiting_leaves_a_closed_issue_alone(self):
        f = Fake(issues=[dict(ISSUE, state='closed')])
        go(f)
        self.assertEqual(f.writes, [])

    def test_issue_by_someone_else_or_other_title_is_not_ours(self):
        f = Fake(issues=[dict(ISSUE, user={'login': 'uncomposed'}), dict(ISSUE, number=10, title='Other')])
        self.assertIsNone(dwa.find_issue(dwa.Gh(REPO, f)))

    def test_only_issue_and_comment_writes_ever_happen(self):
        newer = wf_run(200, '2026-11-23T16:40:00Z', status='pending')
        f = Fake(waiting=[OLD], siblings=[OLD, newer])
        go(f)
        for _, path, _ in f.writes:
            self.assertTrue(path == 'issues' or path.startswith('issues/'), path)


if __name__ == '__main__':
    unittest.main()
