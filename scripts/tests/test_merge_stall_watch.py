"""#3502: the stall alarm speaks when merging stops, stays quiet when work flows, and ignores strangers."""
import contextlib
import datetime
import io
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import merge_audit  # noqa: E402
import merge_stall_watch as watch  # noqa: E402

HEAD = 'a' * 40
NOW = datetime.datetime(2026, 11, 6, 12, 0, tzinfo=datetime.timezone.utc)


def ago(minutes: int) -> datetime.datetime:
    return NOW - datetime.timedelta(minutes=minutes)


def stamp(minutes: int) -> str:
    return ago(minutes).isoformat().replace('+00:00', 'Z')


def comment(body: str, minutes: int = 300, login: str = 'github-actions[bot]', association: str = 'NONE') -> dict:
    return {'body': body, 'created_at': stamp(minutes), 'user': {'login': login}, 'author_association': association}


def lane_report(verdict: str, tier: str) -> str:
    """A report in the runner's real format (scripts/lane-runner.py, the lines at `Lane report {request_id}`)."""
    return (f'Lane report pr5-r1 — {verdict}\n'
            f'commit {HEAD[:7]} (tested merged with main at ccccccc) · tier {tier} · hosted · 3m\n'
            f'ran: tests\ncrashes: 0')


def armed(comments=(), running=(), head_minutes=300, state='clean', number=5) -> dict:
    return {'pr': {'number': number, 'head': {'sha': HEAD}, 'mergeable_state': state}, 'comments': list(comments),
            'running': list(running), 'head_time': ago(head_minutes)}


class StallTests(unittest.TestCase):
    def test_the_night_of_2026_11_05_alarms(self):
        # Eleven hours of nothing, with the PR's T3 PASS the last thing said.
        note = comment(f'Lane report pr5-r1 — PASS\ncommit `{HEAD[:7]}`', minutes=650)
        lines = watch.stall(NOW, ago(690), [armed([note], running=['automerge'], head_minutes=700)])
        self.assertEqual(len(lines), 1)
        self.assertIn('#5 has not moved for 650 minutes', lines[0])
        self.assertIn('Lane report pr5-r1', lines[0])

    def test_a_recent_merge_means_no_alarm_whatever_the_prs_look_like(self):
        self.assertEqual(watch.stall(NOW, ago(59), [armed()]), [])

    def test_nothing_armed_means_no_alarm_however_quiet_it_is(self):
        self.assertEqual(watch.stall(NOW, ago(6000), []), [])

    def test_a_pr_that_moved_within_the_hour_is_not_stuck(self):
        self.assertEqual(watch.stall(NOW, ago(300), [armed(head_minutes=59)]), [])
        self.assertEqual(watch.stall(NOW, ago(300), [armed([comment('Lane: note', minutes=59)])]), [])

    def test_a_test_running_on_the_head_is_progress_and_a_waiting_merge_job_is_not(self):
        self.assertEqual(watch.stall(NOW, ago(300), [armed(running=['lane'])]), [])
        self.assertEqual(watch.stall(NOW, ago(300), [armed(running=['hosted fast: Mac rest'])]), [])
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed(running=['automerge'])])), 1)

    def test_a_pr_waiting_on_its_author_is_not_the_pipelines_stall(self):
        fail = comment(f'Lane report pr5-r1 — FAIL\ncommit `{HEAD[:7]}`')
        blocking = comment(f'**Claude audit on `{HEAD[:7]}`**\nBlocking: the packet breaks.')
        for item in (armed([fail]), armed([blocking]), armed(state='dirty')):
            self.assertEqual(watch.stall(NOW, ago(300), [item]), [], item)

    def test_a_fail_on_an_older_head_does_not_excuse_the_new_head(self):
        old = comment('Lane report pr5-r1 — FAIL\ncommit `bbbbbbb`')
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed([old])])), 1)

    def test_a_newer_pass_on_the_head_clears_an_older_fail(self):
        fail = comment(f'Lane report pr5-r1 — FAIL\ncommit `{HEAD[:7]}`', minutes=400)
        passed = comment(f'Lane report pr5-r2 — PASS\ncommit `{HEAD[:7]}`', minutes=300)
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed([fail, passed])])), 1)

    def test_a_clean_audit_leaves_the_pr_stuck(self):
        clean = comment(f'**Claude audit on `{HEAD[:7]}`**\nNo blocking findings.')
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed([clean])])), 1)

    def test_a_clean_reaudit_of_the_head_replaces_the_blocking_one(self):
        # The audit of #3507: the watch skipped the clean re-audit and stopped at the older blocking one, so no alarm.
        passed = comment(lane_report('PASS', 'T2'), minutes=500)
        blocking = comment(f'**Claude audit on `{HEAD[:7]}`**\nBlocking: the packet breaks.', minutes=400)
        clean = comment(f'**Claude audit on `{HEAD[:7]}`**\nNo blocking findings.', minutes=300)
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed([passed, blocking, clean])])), 1)

    def test_a_blocking_audit_holds_whatever_the_lane_said_after_it(self):
        # The audit of #3507: reading from newest, the PASS ended the search and the owner was paged for nothing.
        blocking = comment(f'**Claude audit on `{HEAD[:7]}`**\nBlocking: the packet breaks.', minutes=400)
        passed = comment(lane_report('PASS', 'T2'), minutes=300)
        self.assertEqual(watch.stall(NOW, ago(300), [armed([blocking, passed])]), [])

    def test_a_blocking_reaudit_replaces_a_clean_one(self):
        clean = comment(f'**Claude audit on `{HEAD[:7]}`**\nNo blocking findings.', minutes=400)
        blocking = comment(f'**Claude audit on `{HEAD[:7]}`**\nBlocking: the packet breaks.', minutes=300)
        self.assertEqual(watch.stall(NOW, ago(300), [armed([clean, blocking])]), [])

    def test_a_blocking_audit_of_an_older_head_does_not_excuse_the_new_head(self):
        old = comment('**Claude audit on `bbbbbbb`**\nBlocking: the packet breaks.')
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed([old])])), 1)

    def test_a_blocking_codex_audit_holds_as_the_runner_says(self):
        for heading in (f'**Codex audit (Astra) on `{HEAD[:7]}`**', f'## Codex audit of `{HEAD[:7]}`'):
            blocking = comment(f'{heading}\nBlocking: the packet breaks.')
            self.assertEqual(watch.stall(NOW, ago(300), [armed([blocking])]), [], heading)

    def test_a_t3_fail_holds_until_a_t3_passes_however_many_other_passes_follow(self):
        # The runner's t3_gate: a PR that asked for T3 merges only on a T3 PASS, so the author has to act.
        t3_fail = comment(lane_report('FAIL', 'T3'), minutes=500)
        t2_pass = comment(lane_report('PASS', 'T2'), minutes=400)
        t3_pass = comment(lane_report('PASS', 'T3'), minutes=300)
        self.assertEqual(watch.stall(NOW, ago(300), [armed([t3_fail, t2_pass])]), [])
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed([t3_fail, t2_pass, t3_pass])])), 1)

    def test_an_inconclusive_t3_is_the_pipelines_to_retry_so_it_can_stall(self):
        inconclusive = comment(lane_report('INCONCLUSIVE', 'T3'))
        self.assertEqual(len(watch.stall(NOW, ago(300), [armed([inconclusive])])), 1)

    def test_the_audit_formats_match_the_merge_audit_they_were_copied_from(self):
        # The hosted job checks out only three scripts, so the watch can't import these.
        self.assertEqual(watch.AUDIT_HEADINGS, merge_audit.AUDITS[:2])
        self.assertEqual(watch.AUDIT_SHA.pattern, merge_audit.AUDIT_SHA.pattern)
        self.assertEqual(watch.CLEAN_AUDIT.pattern, merge_audit.CLEAN_AUDIT.pattern)
        self.assertEqual(watch.CLEAN_AUDIT.flags, merge_audit.CLEAN_AUDIT.flags)

    def test_a_stranger_cannot_hide_a_stall_or_fake_a_verdict(self):
        stranger = dict(login='someone', association='NONE')
        fresh = comment('still looking', minutes=1, **stranger)
        fake_fail = comment(f'Lane report pr5-r1 — FAIL\ncommit `{HEAD[:7]}`', **stranger)
        lookalike = comment(f'Lane report pr5-r1 — FAIL\ncommit `{HEAD[:7]}`', login='github-actions')
        for item in (armed([fresh]), armed([fake_fail]), armed([lookalike])):
            self.assertEqual(len(watch.stall(NOW, ago(300), [item])), 1, item['comments'])

    def test_the_alarm_mentions_the_owner_and_carries_the_marker(self):
        body = watch.alarm_body(NOW, ago(90), ['- #5 has not moved'])
        self.assertTrue(body.startswith(f'@{watch.OWNER_LOGIN} nothing has merged for 90 minutes'))
        self.assertIn(watch.MARKER, body)
        self.assertIn('- #5 has not moved', body)

    def test_the_owner_login_matches_the_tap_alert(self):
        source = (Path(__file__).resolve().parents[1] / 'owner_tap_alert.py').read_text()
        self.assertIn(f"OWNER_LOGIN = '{watch.OWNER_LOGIN}'", source)


class AlarmIssueTests(unittest.TestCase):
    def issues(self, *issues):
        original = watch.api
        watch.api = lambda path: [list(issues)]
        self.addCleanup(setattr, watch, 'api', original)

    def test_only_the_bots_own_issue_with_the_marker_counts(self):
        mine = {'number': 9, 'user': {'login': watch.BOT}, 'body': f'x {watch.MARKER}'}
        stranger = {'number': 7, 'user': {'login': 'someone'}, 'body': watch.MARKER}
        other = {'number': 8, 'user': {'login': watch.BOT}, 'body': 'another bot issue'}
        self.issues(stranger, other, mine)
        self.assertEqual(watch.open_alarm('o/r')['number'], 9)
        self.issues(stranger, other)
        self.assertIsNone(watch.open_alarm('o/r'))


class AlarmClosingTests(unittest.TestCase):
    """The audit of #3507: a late or dropped scheduled run must still see the merge that ended the stall."""

    def run_watch(self, merged_hours_ago: float, alarm_hours_ago: float) -> list[tuple]:
        now = datetime.datetime.now(datetime.timezone.utc)
        when = lambda hours: (now - datetime.timedelta(hours=hours)).strftime('%Y-%m-%dT%H:%M:%SZ')  # noqa: E731
        alarm = {'number': 9, 'user': {'login': watch.BOT}, 'body': watch.MARKER, 'created_at': when(alarm_hours_ago)}
        tip = {'commit': {'committer': {'date': when(merged_hours_ago)}}}
        calls = []
        patches = {'api': lambda path: [[alarm]] if '/issues' in path else tip,
                   'gh': lambda *args, stdin=None: calls.append(args) or '',
                   'trunk_branch': lambda: 'main'}
        for name, replacement in patches.items():
            self.addCleanup(setattr, watch, name, getattr(watch, name))
            setattr(watch, name, replacement)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(watch.main([]), 0)
        return calls

    def test_a_merge_after_the_alarm_closes_it_even_when_the_next_run_is_hours_late(self):
        calls = self.run_watch(merged_hours_ago=3, alarm_hours_ago=4)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ('issue', 'close', '9'))

    def test_a_merge_before_the_alarm_leaves_it_open(self):
        self.assertEqual(self.run_watch(merged_hours_ago=4, alarm_hours_ago=3), [])

    def test_a_merge_right_after_the_alarm_closes_it(self):
        calls = self.run_watch(merged_hours_ago=0.1, alarm_hours_ago=0.2)
        self.assertEqual(calls[0][:3], ('issue', 'close', '9'))


if __name__ == '__main__':
    unittest.main()
