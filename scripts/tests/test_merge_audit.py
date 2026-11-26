import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import merge_audit as audit  # noqa: E402

HEAD = '92533d3' + 'a' * 33
MERGED_AT = '2026-09-29T16:20:47Z'


def comment(body, created_at='2026-09-29T16:12:22Z'):
    return {'body': body, 'created_at': created_at, 'author_association': 'OWNER'}


CHECK = '**Merge check (triage desk) on `92533d3`: green.**\n- Full `scripts/tests` with the venv Python: 118 OK, twice.'


class MergeCheckTests(unittest.TestCase):
    """The rule from the owner's spec: prefix, head sha7, posted before the merge."""

    def test_a_check_on_the_merged_head_before_the_merge_passes(self):
        self.assertTrue(audit.has_merge_check([comment('Lane report …'), comment(CHECK)], HEAD, MERGED_AT))
        self.assertTrue(audit.has_merge_check([comment('\n  ' + CHECK)], HEAD, MERGED_AT))

    def test_no_check_or_a_check_on_another_head_fails(self):
        self.assertFalse(audit.has_merge_check([comment('Lane report pr254 — PASS')], HEAD, MERGED_AT))
        self.assertFalse(audit.has_merge_check([comment(CHECK.replace('92533d3', '8635de8'))], HEAD, MERGED_AT))
        self.assertFalse(audit.has_merge_check([], HEAD, MERGED_AT))

    def test_a_check_posted_after_the_merge_fails(self):
        # #253: "recorded after the merge, for the audit trail" doesn't count.
        self.assertFalse(audit.has_merge_check([comment(CHECK, '2026-09-29T16:21:16Z')], HEAD, MERGED_AT))
        self.assertFalse(audit.has_merge_check([comment(CHECK, MERGED_AT)], HEAD, MERGED_AT))

    def test_a_comment_with_another_prefix_fails(self):
        for body in ('**Merged under the owner\'s out-of-diff rule** on `92533d3`',
                     'Merge check (triage desk) on `92533d3`: green.',
                     'Looks good. **Merge check (triage desk) on `92533d3`** later.'):
            with self.subTest(body=body):
                self.assertFalse(audit.has_merge_check([comment(body)], HEAD, MERGED_AT))

    def test_the_failure_comment_is_the_specified_text(self):
        self.assertEqual(audit.failure_comment(HEAD), 'Merged into main without a triage-desk merge check on 92533d3. '
                                                      'If the owner merged this directly, remove the label.')


class ClaudeAuditTests(unittest.TestCase):
    def test_claude_audit_counts_only_before_merge(self):
        clean = '**Claude audit on `92533d3`**\n\nNo blocking findings.'
        merged = audit.parse_time(MERGED_AT)
        self.assertEqual(audit.audit_verdict([comment(clean)], HEAD, merged), 'No blocking findings.')
        self.assertIsNone(audit.audit_verdict([comment(clean, MERGED_AT)], HEAD, merged))

    def test_newest_head_audit_wins_across_reviewers(self):
        clean = comment('**Claude audit on `92533d3`**\n\nNo blocking findings.')
        blocked = comment('**Codex audit (Astra) on `92533d3`**\n\n[P1] Broken.')
        merged = audit.parse_time(MERGED_AT)
        self.assertEqual(audit.audit_verdict([blocked, clean], HEAD, merged), 'No blocking findings.')
        self.assertEqual(audit.audit_verdict([clean, blocked], HEAD, merged), '[P1] Broken.')


class PushTests(unittest.TestCase):
    """Which merged PRs a push to main brought in, and whether its tip came from no PR."""

    def pr(self, number, merge_sha, base='main', merged=True):
        return {'number': number, 'merge_commit_sha': merge_sha, 'base': {'ref': base},
                'merged_at': MERGED_AT if merged else None, 'head': {'sha': HEAD}}

    def test_a_pr_merge_is_found_by_its_merge_commit(self):
        merged, direct = audit.classify_push(['c1', 'c2', 'm254'], 'm254',
                                             [self.pr(254, 'm254'), self.pr(253, 'm253'), self.pr(1, 'x', merged=False)])
        self.assertEqual((sorted(merged), direct), ([254], False))

    def test_a_push_whose_tip_is_no_pr_merge_is_direct(self):
        merged, direct = audit.classify_push(['c9'], 'c9', [self.pr(254, 'm254')])
        self.assertEqual((merged, direct), ({}, True))
        # A local merge commit on top of a real PR merge still leaves the tip unexplained.
        merged, direct = audit.classify_push(['m254', 'local'], 'local', [self.pr(254, 'm254')])
        self.assertEqual((sorted(merged), direct), ([254], True))

    def test_prs_into_other_branches_are_ignored(self):
        merged, direct = audit.classify_push(['m1'], 'm1', [self.pr(7, 'm1', base='next')])
        self.assertEqual((merged, direct), ({}, True))


class FakePulls(audit.GitHub):
    """The two PR lookups merge_audit makes, answered from lists: the recently-updated window and the per-commit table."""

    def __init__(self, closed, by_commit=None):
        self.repo, self.closed, self.by_commit, self.asked, self.pages_read = 'o/r', closed, by_commit or {}, [], 0

    def api(self, *args, check=True):
        path = args[0]
        if '/commits/' in path:
            sha = path.split('/commits/')[1].split('/')[0]
            self.asked.append(sha)
            return json.dumps(self.by_commit.get(sha, []))
        page = int(path.split('&page=')[1])
        self.pages_read += 1
        return json.dumps(self.closed[(page - 1) * 100:page * 100])


class BusyHourTests(unittest.TestCase):
    """#4668: 13 PRs hand-merged in 100 s were each flagged "reached main without a pull request".

    Lane comments and labels touch many PRs, so a PR merged a minute ago sat outside the 50 most recently updated.
    """

    def pr(self, number, merge_sha, updated='2026-11-18T18:36:00Z', base='main'):
        return {'number': number, 'merge_commit_sha': merge_sha, 'base': {'ref': base}, 'merged_at': MERGED_AT,
                'updated_at': updated, 'head': {'sha': HEAD}}

    def busy_hour(self, n=60):
        return [self.pr(1000 + i, f'other{i}', updated='2026-11-18T18:40:00Z') for i in range(n)]

    def test_a_merged_pr_outside_the_recently_updated_window_is_not_a_direct_push(self):
        merged_pr = self.pr(4488, 'merge4488')
        # The PR is in the closed list, but behind 120 PRs updated more recently: past the 50 the audit used to read,
        # and past the 100 of the one page it reads now, so only the per-commit lookup can find it.
        github = FakePulls(self.busy_hour(120) + [merged_pr], {'merge4488': [merged_pr]})
        old_window = github.recently_closed_into('main')[:50]
        self.assertNotIn(4488, [p['number'] for p in old_window])
        _, direct_in_window = audit.classify_push(['merge4488'], 'merge4488', old_window, 'main')
        self.assertTrue(direct_in_window)  # what the push audit decided before: a false "no pull request"
        merged, direct = audit.merges_in_push(github, ['merge4488'], 'merge4488', 'main')
        self.assertEqual((sorted(merged), direct), ([4488], False))
        self.assertEqual(github.asked, ['merge4488'])  # the lookup, not the window, found it

    def test_a_commit_pushed_straight_to_main_is_still_direct(self):
        github = FakePulls(self.busy_hour(), {})
        merged, direct = audit.merges_in_push(github, ['c1', 'c2'], 'c2', 'main')
        self.assertEqual((merged, direct), ({}, True))
        self.assertEqual(github.asked[0], 'c2')  # the tip is asked about first

    def test_a_commit_that_belongs_to_some_other_prs_branch_does_not_explain_the_tip(self):
        # The lookup also names PRs a commit sits inside; only one whose merge commit was pushed counts.
        inside = self.pr(77, 'merge77')
        github = FakePulls([], {'local': [inside]})
        merged, direct = audit.merges_in_push(github, ['local'], 'local', 'main')
        self.assertEqual((merged, direct), ({}, True))

    def test_a_pr_the_window_already_has_costs_no_lookups(self):
        github = FakePulls([self.pr(5, 'm5')])
        merged, direct = audit.merges_in_push(github, ['m5'], 'm5', 'main')
        self.assertEqual((sorted(merged), direct, github.asked), ([5], False, []))

    def test_a_merge_pushes_its_branch_commits_but_only_the_merge_commit_is_asked_about(self):
        """A PR with 12 branch commits, merged by hand: the tip is explained by the window, so no lookup at all; if the
        window missed it, one lookup (the tip), never one per branch commit."""
        branch = [f'b{i}' for i in range(12)]
        compare = {'commits': [{'sha': sha, 'parents': [{'sha': 'x'}]} for sha in branch]
                   + [{'sha': 'merge9', 'parents': [{'sha': 'a'}, {'sha': 'b0'}]}]}
        github = FakePulls([self.pr(9, 'merge9')], {'merge9': [self.pr(9, 'merge9')]})
        github.api_compare = json.dumps(compare)
        orig = github.api
        github.api = lambda *a, **k: github.api_compare if '/compare/' in a[0] else orig(*a, **k)
        pushed = github.pushed_commits('before', 'merge9')
        self.assertEqual(len(pushed), 13)
        merged, direct = audit.merges_in_push(github, pushed, 'merge9', 'main')
        self.assertEqual((sorted(merged), direct, github.asked), ([9], False, []))
        # window misses it: one lookup, for the tip
        github = FakePulls([], {'merge9': [self.pr(9, 'merge9')]})
        github.parent_counts = {c['sha']: len(c['parents']) for c in compare['commits']}
        merged, direct = audit.merges_in_push(github, pushed, 'merge9', 'main')
        self.assertEqual((sorted(merged), direct, github.asked), ([9], False, ['merge9']))

    def test_the_lookups_stop_at_their_time_budget_so_the_flag_is_still_written(self):
        shas = [f'm{i}' for i in range(10)]
        github = FakePulls([], {})
        clock = iter([0, 1, 2, 100, 101, 102, 103, 104, 105, 106, 107, 108])
        with mock.patch.object(audit.time, 'monotonic', side_effect=lambda: next(clock)):
            merged, direct = audit.merges_in_push(github, shas, shas[-1], 'main')
        self.assertEqual((merged, direct), ({}, True))
        self.assertLess(len(github.asked), len(shas))  # out of budget after the first couple

    def test_lookups_are_capped_and_a_failed_lookup_is_no_match(self):
        shas = [f'c{i}' for i in range(120)]
        github = FakePulls([], {})
        audit.merges_in_push(github, shas, shas[-1], 'main')  # no compare data: every commit might be a merge
        self.assertEqual(len(github.asked), audit.MAX_COMMIT_LOOKUPS)
        broken = audit.GitHub('o/r')
        calls = []
        broken.api = lambda *a, **k: calls.append(a) or (_ for _ in ()).throw(RuntimeError('502'))
        with mock.patch.object(audit.time, 'sleep'):
            self.assertEqual(broken.pulls_for_commit('c1'), [])
        self.assertEqual(len(calls), 2)  # one retry

    def test_one_transient_failure_is_retried(self):
        answers = iter([RuntimeError('502'), '[{"number": 3}]'])

        def api(*args, **kwargs):
            answer = next(answers)
            if isinstance(answer, Exception):
                raise answer
            return answer
        github = audit.GitHub('o/r')
        github.api = api
        with mock.patch.object(audit.time, 'sleep'):
            self.assertEqual(github.pulls_for_commit('c1'), [{'number': 3}])

    def test_the_sweep_reads_pages_until_it_passes_the_window(self):
        import datetime
        newer = [self.pr(i, f'm{i}', updated='2026-11-18T19:00:00Z') for i in range(250)]
        older = [self.pr(9000 + i, f'o{i}', updated='2026-11-18T10:00:00Z') for i in range(250)]
        github = FakePulls(newer + older)
        found = github.recently_closed_into('main', datetime.datetime(2026, 11, 18, 18, 0, 0))
        self.assertEqual(github.pages_read, 3)  # 100 + 100 + a page holding the first older PR
        self.assertEqual(len(found), 300)
        self.assertTrue({p['number'] for p in newer} <= {p['number'] for p in found})

    def test_without_a_window_the_list_is_one_page(self):
        github = FakePulls(self.busy_hour(250))
        self.assertEqual(len(github.recently_closed_into('main')), 100)
        self.assertEqual(github.pages_read, 1)


class SweepTests(unittest.TestCase):
    """The sweep after each runner merge: the runner's token-made merges start no push run (decision 3)."""

    def test_it_takes_prs_into_main_merged_within_the_window(self):
        import datetime
        now = datetime.datetime(2026, 9, 29, 21, 0, 0)
        recent = [
            {'number': 1, 'merged_at': '2026-09-29T20:30:00Z', 'base': {'ref': 'main'}},
            {'number': 2, 'merged_at': '2026-09-29T18:30:00Z', 'base': {'ref': 'main'}},
            {'number': 3, 'merged_at': '2026-09-29T20:50:00Z', 'base': {'ref': 'next'}},
            {'number': 4, 'merged_at': None, 'base': {'ref': 'main'}},
        ]
        self.assertEqual([p['number'] for p in audit.recently_merged(recent, 2, now)], [1])


# Shaped like the real comments on #633 (hand merge after a lane PASS and a clean audit of f41b1de) and
# #656 (hand merge of 4fba40e, whose audits covered only earlier heads).
BOT = {'login': 'github-actions[bot]'}
OWNER = {'login': 'uncomposed'}
HAND_HEAD = 'f41b1defebde743a2f3626cc2d8c020e909b8d1d'
HAND_MERGED_AT = '2026-10-01T17:08:20Z'


def lane_report(verdict, tier='auto', commit=HAND_HEAD, created_at='2026-10-01T16:40:54Z', user=BOT):
    marker = json.dumps({'commit': commit, 'next': 'b7e312b5745378928fd252a375722ce70ec6d5f9', 'tests': [],
                         'tier': tier}, sort_keys=True)
    body = (f'Lane report pr633-r36887921056 — {verdict}\n'
            f'commit {commit[:7]} (tested merged with next at b7e312b) · tier {tier} · host only · 7m35s\n'
            f'ran: host tests (--plan fast): passed\n<!-- lane-request: {marker} -->\n')
    return {'body': body, 'created_at': created_at, 'user': user}


def codex_audit(verdict='No blocking findings.', sha=HAND_HEAD[:7], created_at='2026-10-01T16:48:21Z'):
    body = (f'**Codex audit (Astra) on `{sha}`**\n\n{verdict}\n\n---\nPosted by the mechanical audit script; '
            'Codex ran read-only; findings are Codex\'s own, not re-checked by Claude.')
    return {'body': body, 'created_at': created_at, 'user': OWNER, 'author_association': 'OWNER'}


REQUEST = {'body': 'Audit requested: lane change (owner rule 2026-10-01).', 'created_at': '2026-10-01T15:54:25Z',
           'user': OWNER, 'author_association': 'OWNER'}


class HandMergeTests(unittest.TestCase):
    """#742: a hand merge passes when the head had a lane PASS and a clean Codex audit before the merge."""

    def gap(self, comments, head=HAND_HEAD, merged_at=HAND_MERGED_AT):
        return audit.hand_merge_gap(comments, head, merged_at)

    def test_a_lane_pass_and_a_clean_audit_of_the_head_pass(self):  # #633, #637
        self.assertIsNone(self.gap([REQUEST, lane_report('PASS'), codex_audit()]))
        self.assertIsNone(self.gap([REQUEST, codex_audit(verdict='No findings.'), lane_report('PASS')]))

    def test_audits_of_earlier_heads_dont_clear_the_merged_head(self):  # #656
        comments = [codex_audit(verdict='- **[P1] Older PR heads crash on the new import**', sha='fce8210'),
                    codex_audit(sha='ef52c6c')]
        self.assertEqual(self.gap(comments), 'no lane report on `f41b1de`; no Codex or Claude audit of `f41b1de`')

    def test_a_missing_or_failing_lane_report_fails(self):
        self.assertEqual(self.gap([codex_audit()]), 'no lane report on `f41b1de`')
        self.assertEqual(self.gap([lane_report('PASS'), lane_report('FAIL', created_at='2026-10-01T16:45:00Z'),
                                   codex_audit()]), 'the newest lane report on `f41b1de` is FAIL')
        self.assertEqual(self.gap([lane_report('INCONCLUSIVE'), codex_audit()]),
                         'the newest lane report on `f41b1de` is INCONCLUSIVE')

    def test_a_t3_report_counts_neither_way(self):
        # #4572: a T3 holds no merge, so its FAIL leaves no gap and its PASS stands in for no lane report.
        comments = [lane_report('FAIL', tier='T3'), lane_report('PASS', created_at='2026-10-01T16:45:00Z'),
                    codex_audit()]
        self.assertIsNone(self.gap(comments))
        self.assertEqual(self.gap([lane_report('PASS', tier='T3'), codex_audit()]), 'no lane report on `f41b1de`')

    def test_reports_on_another_head_or_not_from_the_runner_dont_count(self):
        self.assertEqual(self.gap([lane_report('PASS', commit='5a59350' + 'b' * 33), codex_audit()]),
                         'no lane report on `f41b1de`')
        self.assertEqual(self.gap([lane_report('PASS', user=OWNER), codex_audit()]), 'no lane report on `f41b1de`')

    def test_an_audit_with_findings_fails(self):
        self.assertEqual(self.gap([lane_report('PASS'), codex_audit(verdict='- **[P2] Something real**')]),
                         'the Codex or Claude audit of `f41b1de` has blocking findings')
        # The newest audit of the head decides.
        self.assertIsNone(self.gap([lane_report('PASS'), codex_audit(verdict='- **[P2] Something real**'),
                                    codex_audit(created_at='2026-10-01T17:00:00Z')]))

    def test_evidence_posted_after_the_merge_doesnt_count(self):  # #610, #615: lane runs after the merge
        self.assertEqual(self.gap([lane_report('PASS', created_at='2026-10-01T17:41:08Z'),
                                   codex_audit(created_at=HAND_MERGED_AT)]),
                         'no lane report on `f41b1de`; no Codex or Claude audit of `f41b1de`')

    def test_the_failure_comment_says_what_was_missing(self):
        self.assertEqual(audit.failure_comment(HAND_HEAD, 'no Codex or Claude audit of `f41b1de`'),
                         'Merged into main without a triage-desk merge check on f41b1de. Hand-merge rule not met '
                         'before the merge: no Codex or Claude audit of `f41b1de`. If the owner merged this directly, remove '
                         'the label.')


QUEUE_MERGE = 'd' * 40


class QueueCheckTests(unittest.TestCase):
    def run_named(self, name='merge policy', conclusion='success', app='github-actions'):
        return {'name': name, 'conclusion': conclusion, 'app': {'slug': app}}

    def test_only_a_passing_merge_policy_run_from_github_actions_counts(self):
        self.assertTrue(audit.passed_queue_check([self.run_named()]))
        for run in (self.run_named(conclusion='failure'), self.run_named(conclusion='cancelled'),
                    self.run_named(name='hosted fast: portable'), self.run_named(app='some-other-app')):
            with self.subTest(run=run):
                self.assertFalse(audit.passed_queue_check([run]))
        self.assertFalse(audit.passed_queue_check([]))

    def test_the_reader_asks_about_the_merge_commit_and_a_failed_read_is_not_a_pass(self):
        github = audit.GitHub('o/r')
        asked = []

        def answer(*args, check=True):
            asked.append(args)
            return json.dumps({'check_runs': [{'name': 'merge policy', 'conclusion': 'success',
                                               'app': {'slug': 'github-actions'}}]})
        github.api = answer
        self.assertTrue(github.passed_merge_queue(QUEUE_MERGE))
        self.assertIn(f'commits/{QUEUE_MERGE}/check-runs?check_name=merge%20policy', asked[0][0])
        self.assertFalse(github.passed_merge_queue(None))

        def broken(*args, check=True):
            raise RuntimeError('HTTP 403')
        github.api = broken
        self.assertFalse(github.passed_merge_queue(QUEUE_MERGE))

    @staticmethod
    def status(state='success', context='merge policy', creator='github-actions[bot]'):
        return {'context': context, 'state': state, 'creator': {'login': creator}}

    def test_a_passing_merge_policy_status_from_github_actions_counts(self):
        # #5162: the check is a commit status now; the API lists them newest first.
        self.assertTrue(audit.passed_queue_status([self.status()]))
        self.assertTrue(audit.passed_queue_status([self.status(), self.status('pending')]))
        for statuses in ([self.status('pending')], [self.status('failure')], [self.status('error')],
                         [self.status('failure'), self.status()], [self.status(context='main-t3')],
                         [self.status(creator='mallory')], []):
            with self.subTest(statuses=statuses):
                self.assertFalse(audit.passed_queue_status(statuses))
        # someone else's newer success can't stand in for the Actions one
        self.assertFalse(audit.passed_queue_status([self.status(creator='mallory'), self.status('failure')]))

    def test_the_reader_falls_back_to_the_statuses_of_the_merge_commit(self):
        github = audit.GitHub('o/r')
        asked = []

        def answer(*args, check=True):
            asked.append(args[0])
            if '/check-runs' in args[0]:
                return json.dumps({'check_runs': []})
            return json.dumps([self.status()])
        github.api = answer
        self.assertTrue(github.passed_merge_queue(QUEUE_MERGE))
        self.assertIn(f'repos/o/r/commits/{QUEUE_MERGE}/statuses?per_page=100', asked)


class FakeGitHub:
    repo = 'uncomposed/spoken-margins-native'

    def __init__(self, comments, queued=False):
        self.comments, self.flagged, self.queued = comments, [], queued

    def json_lines(self, path):
        return self.comments

    def passed_merge_queue(self, merge_commit_sha):
        return self.queued and merge_commit_sha == QUEUE_MERGE

    def flag_pull(self, number, head_sha, gap=None, base=None):
        self.flagged.append((number, gap))


class AuditPullTests(unittest.TestCase):
    pull = {'number': 633, 'head': {'sha': HAND_HEAD}, 'merged_at': HAND_MERGED_AT}

    def test_a_compliant_hand_merge_is_not_flagged(self):
        github = FakeGitHub([REQUEST, lane_report('PASS'), codex_audit()])
        audit.audit_pull(github, self.pull, dry_run=False)
        self.assertEqual(github.flagged, [])

    def test_a_hand_merge_without_the_checks_is_flagged_with_the_reason(self):
        github = FakeGitHub([lane_report('PASS')])
        audit.audit_pull(github, self.pull, dry_run=False)
        self.assertEqual(github.flagged, [(633, 'no Codex or Claude audit of `f41b1de`')])

    def test_a_merge_queue_merge_is_not_flagged(self):
        # 2026-11-20: with lane.yml disabled no lane report comes, so #4747 and #4746 were flagged though the queue's
        # merge policy check, which enforces the audit and owner-tap rules, passed on the commit that reached main.
        github = FakeGitHub([], queued=True)
        audit.audit_pull(github, dict(self.pull, merge_commit_sha=QUEUE_MERGE), dry_run=False)
        self.assertEqual(github.flagged, [])

    def test_a_merge_the_queue_did_not_pass_is_still_flagged(self):
        github = FakeGitHub([], queued=True)
        audit.audit_pull(github, dict(self.pull, merge_commit_sha='e' * 40), dry_run=False)
        self.assertEqual(len(github.flagged), 1)

    def test_the_runner_merge_check_still_passes(self):
        check = {'body': CHECK.replace('92533d3', 'f41b1de'), 'created_at': '2026-10-01T17:08:00Z', 'user': BOT}
        github = FakeGitHub([check])
        audit.audit_pull(github, self.pull, dry_run=False)
        self.assertEqual(github.flagged, [])


if __name__ == '__main__':
    unittest.main()


class StrangerTests(unittest.TestCase):
    """#1822: once the repository is public, anyone can post a comment that looks like the lane's or an audit."""
    STRANGER = {'user': {'login': 'mallory'}, 'author_association': 'NONE'}
    MERGED = audit.parse_time(HAND_MERGED_AT)

    def test_a_stranger_cannot_post_the_merge_check(self):
        forged = dict(comment(CHECK), **self.STRANGER)
        self.assertFalse(audit.has_merge_check([forged], HEAD, MERGED_AT))
        self.assertTrue(audit.has_merge_check([dict(forged, **{'user': {'login': 'uncomposed'},
                                                                'author_association': 'OWNER'})], HEAD, MERGED_AT))

    def test_a_stranger_cannot_post_the_audit(self):
        forged = dict(codex_audit(), **self.STRANGER)
        self.assertIsNone(audit.audit_verdict([forged], HAND_HEAD, self.MERGED))
        claude = dict(forged, body=f'**Claude audit on `{HAND_HEAD[:7]}`**\n\nNo blocking findings.')
        self.assertIsNone(audit.audit_verdict([claude], HAND_HEAD, self.MERGED))
        self.assertEqual(audit.audit_verdict([codex_audit()], HAND_HEAD, self.MERGED), 'No blocking findings.')

    def test_a_stranger_cannot_post_the_lane_report(self):
        for user in ({'login': 'mallory'}, {'login': 'github-actions'}, {'login': 'github-actions[bot]x'}):
            with self.subTest(user=user):
                forged = lane_report('PASS', user=user)
                forged['author_association'] = 'NONE'
                self.assertEqual(audit.lane_reports([forged], HAND_HEAD, self.MERGED), [])

    def test_a_forged_pair_does_not_pass_the_hand_merge_rule(self):
        forged = [dict(lane_report('PASS', user={'login': 'mallory'}), author_association='NONE'),
                  dict(codex_audit(), **self.STRANGER)]
        gap = audit.hand_merge_gap(forged, HAND_HEAD, HAND_MERGED_AT)
        self.assertIn('no lane report', gap)
        self.assertIn('no Codex or Claude audit', gap)
