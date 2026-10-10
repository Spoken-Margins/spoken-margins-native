#!/usr/bin/env python3
"""Unit tests for the pure parts of sm_codex_audit.py.

Run: /usr/bin/python3 -m unittest ops/codex/test_sm_codex_audit.py
The comment fixtures are shaped like GitHub's REST issue comments and copy the
real first lines seen on PRs #344, #366, #374 and #418 on 2026-09-30.
"""

import ast
import importlib.util
import json
import re
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_codex_audit as A  # noqa: E402

HEAD = "68fc3337b3e0e95b75bde01c7c94130e22b62226"
OLD = "1ec94f3f0000000000000000000000000000abcd"

FIXTURE = json.loads(r"""
{
  "comments_audited_old_head": [
    {"created_at": "2026-09-30T00:07:37Z", "user": {"login": "uncomposed"},
     "body": "**Codex audit (gpt-6-astra, high effort, read-only) on `1ec94f3`:** no serious problems found."},
    {"created_at": "2026-09-30T08:54:16Z", "user": {"login": "uncomposed"},
     "body": "**Codex audit (Astra) on `1ec94f3`**\n\nNo blocking findings."},
    {"created_at": "2026-09-30T12:40:00Z", "user": {"login": "github-actions[bot]"},
     "body": "Lane report pr366-r1 — PASS | commit 68fc333 (tested merged with next at 867c69c) · tier T3 · 5m | ran: OfflineStorageLedgerTests (12 passed)"}
  ],
  "comments_fixed_in_later_sha": [
    {"created_at": "2026-09-30T03:47:01Z", "user": {"login": "uncomposed"},
     "body": "**Codex audit on `b6601a5`: confirmed and fixed in `34c8906`** (committed)."}
  ],
  "comments_lane_newest_fail": [
    {"created_at": "2026-09-30T11:41:18Z", "user": {"login": "github-actions[bot]"},
     "body": "Lane report pr418-r2 — PASS | commit 68fc333 (tested merged with next at 9fb4b29) · tier T3"},
    {"created_at": "2026-09-30T11:56:12Z", "user": {"login": "github-actions[bot]"},
     "body": "Lane report pr418-r4 — FAIL | commit 68fc333 (tested merged with next at 867c69c) · tier auto"}
  ],
  "comments_lane_on_old_commit": [
    {"created_at": "2026-09-30T04:25:34Z", "user": {"login": "github-actions[bot]"},
     "body": "Lane report pr374-r5 — PASS | commit 13b6e29 (tested merged with next at 77b3426)"}
  ],
  "comments_human_lane_heading": [
    {"created_at": "2026-09-30T04:25:34Z", "user": {"login": "github-actions[bot]"},
     "body": "Lane report pr1-r1 — PASS | commit 68fc333 (tested merged with next at 77b3426)"},
    {"created_at": "2026-09-30T05:00:00Z", "user": {"login": "uncomposed"},
     "body": "**Lane report pr1-r0 (FAIL) is the lane's setup, not this PR.**\n\n- details"}
  ],
  "files_risky": [
    {"filename": "App/SpokenMarginsApp/Sources/SpokenMarginsApp/OfflineStorageLedger.swift", "additions": 14, "deletions": 1},
    {"filename": "Packages/SessionKit/Tests/SessionKitTests/OfflineLedgerReconciliationTests.swift", "additions": 34, "deletions": 4}
  ],
  "files_tests_only": [
    {"filename": "App/SpokenMarginsAppTests/SupertonicSpeechTests.swift", "additions": 39, "deletions": 4}
  ],
  "files_plain": [
    {"filename": "Packages/SessionKit/Sources/SessionKit/ListeningMapOverviewText.swift", "additions": 40, "deletions": 3},
    {"filename": "docs/workstreams/streams/D5-player.md", "additions": 2, "deletions": 0},
    {"filename": "research/C2/results/darwin/bench.json", "additions": 900, "deletions": 0},
    {"filename": "Contracts/fixtures/audio/sample.json", "additions": 300, "deletions": 0}
  ]
}
""")


def pr(**kw):
    base = {"number": 366, "headRefOid": HEAD, "isDraft": False, "baseRefName": "next",
            "title": "Take the rendered speech cache out of the ledger", "body": "Closes #313.",
            "closingIssuesReferences": []}
    base.update(kw)
    return base


class ShaInComment(unittest.TestCase):
    def test_audit_on_old_head_does_not_count_for_new_head(self):
        self.assertFalse(A.audited_on(FIXTURE["comments_audited_old_head"], HEAD))

    def test_astra_heading_naming_the_head_counts(self):
        self.assertTrue(A.audited_on(FIXTURE["comments_audited_old_head"], OLD))

    def test_wording_the_runner_does_not_accept_does_not_count(self):
        # The runner won't merge on a "**Codex audit (gpt-6-astra, …)" comment, so it isn't an audit here either.
        c = [FIXTURE["comments_audited_old_head"][0]]
        self.assertFalse(A.audited_on(c, OLD))

    def test_older_manual_heading_counts(self):
        c = [{"created_at": "x", "body": "## Codex audit on `68fc333`\n\nNo blocking findings."}]
        self.assertTrue(A.audited_on(c, HEAD))

    def test_longer_prefix_counts(self):
        c = [{"created_at": "x", "body": "**Codex audit (Astra) on `68fc3337b3`**"}]
        self.assertTrue(A.audited_on(c, HEAD))

    def test_sha_only_in_later_lines_does_not_count(self):
        c = [{"created_at": "x", "body": "**Codex audit (Astra) on `1ec94f3`**\n\nre-checked at 68fc333"}]
        self.assertFalse(A.audited_on(c, HEAD))

    def test_finisher_reply_naming_the_fix_is_not_an_audit_of_it(self):
        # #812: a reply to an audit that names the new head is not an audit of that head.
        self.assertFalse(A.audited_on(FIXTURE["comments_fixed_in_later_sha"],
                                      "34c8906" + "0" * 33))
        reply = {"created_at": "x", "body": "**Codex audit on `a919a79` (P2): fixed in `68fc333`** and pushed."}
        self.assertFalse(A.audited_on([reply], HEAD))
        self.assertFalse(A.is_audit_comment(reply))
        self.assertIsNone(A.head_audit([reply], HEAD))

    def test_audit_headings_match_the_lane_runner(self):
        runner = (Path(__file__).resolve().parents[2] / "scripts" / "lane-runner.py").read_text()
        m = re.search(r"^AUDITS = .*$", runner, re.M)
        self.assertIsNotNone(m, "scripts/lane-runner.py no longer defines AUDITS on one line")
        self.assertEqual(ast.literal_eval(ast.parse(m.group(0)).body[0].value), A.AUDIT_HEADINGS)

    def test_comment_not_starting_with_codex_audit_is_ignored(self):
        c = [{"created_at": "x", "body": "Thanks. **Codex audit (Astra) on `68fc333`** next"}]
        self.assertFalse(A.audited_on(c, HEAD))


class LaneGate(unittest.TestCase):
    def test_pass_on_head(self):
        ok, _ = A.lane_pass_for_head(FIXTURE["comments_audited_old_head"], HEAD)
        self.assertTrue(ok)

    def test_newest_fail_wins_over_older_pass(self):
        ok, why = A.lane_pass_for_head(FIXTURE["comments_lane_newest_fail"], HEAD)
        self.assertFalse(ok)
        self.assertIn("FAIL", why)

    def test_pass_on_older_commit_does_not_count(self):
        ok, why = A.lane_pass_for_head(FIXTURE["comments_lane_on_old_commit"], HEAD)
        self.assertFalse(ok)
        self.assertIn("13b6e29", why)

    def test_no_report(self):
        self.assertFalse(A.lane_pass_for_head([], HEAD)[0])

    def test_bold_human_comment_is_not_a_lane_report(self):
        ok, _ = A.lane_pass_for_head(FIXTURE["comments_human_lane_heading"], HEAD)
        self.assertTrue(ok)


class CandidateFilter(unittest.TestCase):
    def test_risky_ready_unaudited_pr_is_candidate(self):
        ok, why = A.evaluate_pr(pr(), FIXTURE["comments_audited_old_head"], FIXTURE["files_risky"])
        self.assertTrue(ok, why)
        self.assertIn("persistence", why)

    def test_draft_skipped(self):
        self.assertEqual(A.evaluate_pr(pr(isDraft=True), [], [])[1], "draft")

    def test_already_audited_skipped(self):
        comments = FIXTURE["comments_audited_old_head"]
        self.assertFalse(A.evaluate_pr(pr(headRefOid=OLD), comments, FIXTURE["files_risky"])[0])

    def test_lane_gate_runs_before_files_are_needed(self):
        ok, why = A.evaluate_pr(pr(), FIXTURE["comments_lane_newest_fail"], None)
        self.assertFalse(ok)
        self.assertNotEqual(why, "need files")

    def test_tests_only_diff_is_not_risky(self):
        ok, why = A.evaluate_pr(pr(), FIXTURE["comments_audited_old_head"], FIXTURE["files_tests_only"])
        self.assertFalse(ok)
        self.assertEqual(why, "not risky, no request")

    def test_docs_and_research_are_not_risky(self):
        self.assertEqual(A.risky_areas([f["filename"] for f in FIXTURE["files_plain"][:3]]), [])

    def test_audio_fixture_is_risky(self):
        self.assertEqual(A.risky_areas(["Contracts/fixtures/audio/sample.json"]), ["audio"])

    def test_risky_areas_cover_the_skill_list(self):
        paths = {
            "Packages/SessionKit/Sources/SessionKitSharing/PacketImporter.swift": "sharing",
            "Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift": "persistence",
            "Packages/SessionKit/Sources/SessionKit/SessionEngine.swift": "persistence",
            "Packages/SessionKit/Sources/SessionKit/StructuredDocumentMigration.swift": "persistence",
            "Contracts/fixtures/persistence/build-29.json": "persistence",
            "Packages/SessionKit/Sources/SessionKitAudio/PlaybackStallDetector.swift": "audio",
            "App/SpokenMarginsApp/Sources/SpokenMarginsApp/SupertonicSpeechPlaybackClient.swift": "audio",
        }
        for p, area in paths.items():
            self.assertIn(area, A.risky_areas([p]), p)
        self.assertEqual(A.risky_areas(["App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackScreen.swift"]), [])

    LANE_PATHS = [
        ".github/workflows/lane.yml", ".github/workflows/linux-t1.yml", "scripts/lane-runner.py",
        "scripts/lane_sim.py", "scripts/lane_slots.py", "scripts/lane_guard.py", "scripts/lane-sim-boot",
        "scripts/xcodebuild-lane", "scripts/host-test-lane", "scripts/install-lane-guard.py",
        "scripts/test-scope.py", "scripts/hot_file_ratchet.py", "scripts/merge_audit.py",
        "scripts/verify-tests.py", "TestPlans/AppBehavior.xctestplan", "TestPlans/AudioAdapters.xctestplan",
    ]

    def test_lane_paths_are_risky(self):
        # Owner rule 2026-10-01: lane PRs get the same audit as sharing, persistence and audio PRs.
        for p in self.LANE_PATHS:
            self.assertEqual(A.risky_areas([p]), ["lane"], p)
        lane_pr = [{"filename": "scripts/lane-runner.py", "additions": 40, "deletions": 3}]
        ok, why = A.evaluate_pr(pr(), FIXTURE["comments_audited_old_head"], lane_pr)
        self.assertEqual((ok, why), (True, "risky: lane"))

    def test_the_audit_s_lane_patterns_follow_the_runner_s_lane_policy(self):
        # sm_codex_audit.py keeps its own copy of scripts/test-scope.py's LANE_PREFIXES and LANE_FILES. A path the
        # runner holds "for a Codex audit" that the audit does not call risky would wait for an audit that is never
        # scheduled, so the policy itself is the source of truth here, not the hand-written LANE_PATHS above.
        spec = importlib.util.spec_from_file_location(
            "scope_for_audit_test", Path(__file__).resolve().parents[2] / "scripts" / "test-scope.py")
        scope = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scope)
        held = sorted(scope.LANE_FILES) + [prefix + "example" for prefix in scope.LANE_PREFIXES]
        self.assertGreaterEqual(len(held), 10)
        for p in held:
            self.assertTrue(scope.is_lane_path(p), p)
            self.assertEqual(A.risky_areas([p]), ["lane"], f"{p} is held for an audit by the runner but not risky here")
        # and the other way round, on the paths named in these tests: the audit adds no lane path of its own
        for p in self.LANE_PATHS + ["scripts/tests/test_lane_runner.py", "TestPlans/scripted-journeys.json",
                                    "scripts/phone-build", "ops/codex/sm_codex_worker.py"]:
            self.assertEqual("lane" in A.risky_areas([p]), scope.is_lane_path(p), p)

    def test_ordinary_paths_stay_off_the_lane(self):
        # The audit count for ordinary PRs must not rise: the lane's tests, the Test Desk's journey list,
        # other scripts, the ops tools and the lane docs don't make a PR risky.
        for p in ["scripts/tests/test_lane_runner.py", "TestPlans/scripted-journeys.json",
                  "TestPlans/Release.xctestplan", "scripts/phone-build", "scripts/validate-contracts.py",
                  "scripts/setup-worktree.sh", "docs/workstreams/test-lane.md", ".claude/skills/lane-request/SKILL.md",
                  ".github/ISSUE_TEMPLATE/bug.yml", "ops/codex/sm_codex_worker.py",
                  "App/SpokenMarginsApp/Sources/SpokenMarginsApp/LaneView.swift"]:
            self.assertEqual(A.risky_areas([p]), [], p)

    def test_request_in_issue_comment_makes_plain_pr_a_candidate(self):
        issue_comments = [{"created_at": "2026-09-30T13:00:00Z", "body": "Please run a Codex audit on this one."}]
        ok, why = A.evaluate_pr(pr(), FIXTURE["comments_audited_old_head"], FIXTURE["files_plain"][:3], issue_comments)
        self.assertTrue(ok)
        self.assertEqual(why, "audit requested")

    def test_request_older_than_last_audit_is_spent(self):
        comments = [{"created_at": "2026-09-29T00:00:00Z", "body": "/codex-audit"}] + FIXTURE["comments_audited_old_head"]
        self.assertFalse(A.evaluate_pr(pr(), comments, FIXTURE["files_plain"][:3])[0])

    def test_request_wording(self):
        self.assertTrue(A.asks_for_audit("/codex-audit"))
        self.assertTrue(A.asks_for_audit("This needs a Codex audit before merge."))
        self.assertTrue(A.asks_for_audit("Requesting a Codex audit."))
        self.assertFalse(A.asks_for_audit("The net diff is test-only, so no Codex audit is due."))
        self.assertFalse(A.asks_for_audit("This doesn't need a Codex audit."))
        self.assertFalse(A.asks_for_audit("Codex audit confirmed and fixed."))

    def test_counted_lines_leave_out_research_and_fixtures(self):
        self.assertEqual(A.counted_lines(FIXTURE["files_plain"]), 45)

    def test_linked_issues(self):
        p = pr(title="Move X (#318, slice 1)", body="Closes #313. Fixes #20",
               closingIssuesReferences=[{"number": 313}])
        self.assertEqual(A.linked_issue_numbers(p), [313, 20, 318])


class RunnerWaitsOnAudit(unittest.TestCase):
    # #439's real automerge report, 2026-09-30 15:18: the runner's test-scope called it audio, this
    # script's list didn't, so nothing ever audited it.
    HELD = ("Lane report pr439-r2 — PASS\ncommit 68fc333 (tested merged with next at 828597e) · tier auto · "
            "no simulator (compile only) · 9m15s\nran: host tests (--plan fast): passed\n"
            "test-scope: T3 (app orchestration; audio session, players or playback state (escalated one tier))\n"
            "not merged by the runner: it touches the audio session and has no \"Codex audit (Astra)\" comment "
            "yet. The desk merges it.\ncrashes: none")
    # #495's wording for an audit of an older commit.
    HELD_495 = ("Lane report pr1-r3 — PASS\ncommit 68fc333 (tested merged with next at 828597e) · tier auto\n"
                "not merged by the runner: it touches persistence and has no Codex audit of its head: the audit "
                "is on `1234567`, the head is `68fc333`. The desk merges it.")
    DESK = ("Lane report pr1-r4 — PASS\ncommit 68fc333 (tested merged with next at 828597e) · tier auto\n"
            "not merged by the runner: it changes the lane or its workflows (scripts/lane-runner.py), and a PR "
            "can change what tests it. The desk merges it.")

    def comments(self, body, at="2026-09-30T15:18:47Z"):
        return [{"created_at": at, "body": body}]

    def test_held_pr_outside_the_risky_list_is_candidate(self):
        ok, why = A.evaluate_pr(pr(), self.comments(self.HELD), FIXTURE["files_plain"][:3])
        self.assertTrue(ok, why)
        self.assertEqual(why, "runner waits on an audit")

    def test_495_wording_counts(self):
        self.assertTrue(A.runner_waits_on_audit(self.comments(self.HELD_495)))

    def test_desk_only_hold_is_not_an_audit_wait(self):
        self.assertFalse(A.runner_waits_on_audit(self.comments(self.DESK)))

    def test_only_the_newest_report_counts(self):
        newer = {"created_at": "2026-09-30T16:00:00Z",
                 "body": "Lane report pr439-r3 — PASS | commit 68fc333 (tested merged with next at 9fb4b29)"}
        self.assertFalse(A.runner_waits_on_audit(self.comments(self.HELD) + [newer]))


class Rearm(unittest.TestCase):
    LANE = {"created_at": "2026-09-30T15:18:47Z", "body": RunnerWaitsOnAudit.HELD}
    CLEAN = {"created_at": "2026-09-30T15:40:00Z",
             "body": "**Codex audit (Astra) on `68fc333`**\n\nNo blocking findings.\n\n---\nPosted by the script."}
    FINDINGS = {"created_at": "2026-09-30T15:40:00Z",
                "body": "**Codex audit (Astra) on `68fc333`**\n\n1. **High:** `Foo.swift:12` loses the Margin.\n\n"
                        "No findings elsewhere."}
    ARMED = {"labels": [{"name": "automerge"}]}

    def decide(self, comments, events=(), **kw):
        return A.rearm_decision(pr(**{**self.ARMED, **kw}), comments, list(events))

    def test_clean_audit_after_held_pass_rearms(self):
        ok, why = self.decide([self.LANE, self.CLEAN])
        self.assertTrue(ok, why)

    def test_events_are_fetched_last(self):
        self.assertEqual(A.rearm_decision(pr(**self.ARMED), [self.LANE, self.CLEAN], None), (False, "need events"))
        self.assertEqual(A.rearm_decision(pr(**self.ARMED), [self.LANE, self.FINDINGS], None)[1],
                         "audit of the head has findings")

    def test_findings_hold_even_with_a_later_no_findings_line(self):
        self.assertEqual(self.decide([self.LANE, self.FINDINGS])[1], "audit of the head has findings")

    def test_no_automerge_label(self):
        self.assertEqual(self.decide([self.LANE, self.CLEAN], labels=[{"name": "lane:done"}])[1],
                         "no automerge label")

    def test_audit_of_an_older_head_does_not_rearm(self):
        self.assertEqual(self.decide([self.LANE, self.CLEAN], headRefOid=OLD)[1], "no audit of the head")

    def test_lane_ran_after_the_audit(self):
        later = {"created_at": "2026-09-30T15:55:00Z",
                 "body": "Lane report pr439-r3 — PASS\ncommit 68fc333 (tested merged with next at 9fb4b29)"}
        self.assertEqual(self.decide([self.LANE, self.CLEAN, later])[1], "the lane ran after the audit")

    def test_newest_lane_fail_does_not_rearm(self):
        self.assertFalse(self.decide(FIXTURE["comments_lane_newest_fail"] + [self.CLEAN])[0])

    def test_rearms_once_per_audit(self):
        before = {"event": "labeled", "label": {"name": "automerge"}, "created_at": "2026-09-30T15:00:00Z"}
        other = {"event": "labeled", "label": {"name": "lane:done"}, "created_at": "2026-09-30T15:45:00Z"}
        self.assertTrue(self.decide([self.LANE, self.CLEAN], [before, other])[0])
        again = {"event": "labeled", "label": {"name": "automerge"}, "created_at": "2026-09-30T15:41:00Z"}
        self.assertEqual(self.decide([self.LANE, self.CLEAN], [before, again])[1],
                         "automerge re-added after the audit already")

    def test_newest_audit_of_the_head_decides(self):
        newer = {**self.FINDINGS, "created_at": "2026-09-30T15:50:00Z"}
        self.assertFalse(self.decide([self.LANE, self.CLEAN, newer])[0])

    def test_posted_comment_reads_as_clean(self):
        body = A.build_comment(366, HEAD, "No blocking findings.", [366])
        self.assertTrue(self.decide([self.LANE, {"created_at": "2026-09-30T15:40:00Z", "body": body}])[0])


class RearmWhileLaneFinishes(unittest.TestCase):
    def api_response(self, cmd, **kwargs):
        path = cmd[-1]
        if 'actions/workflows/lane.yml/runs?' in path:
            if self.api_error:
                raise self.api_error
            runs = [self.active_run] if 'status=in_progress&' in path else []
            return json.dumps({'total_count': len(runs), 'workflow_runs': runs})
        if '/actions/runs/100/jobs?' in path:
            return json.dumps(self.jobs)
        self.fail(f'unexpected API request: {cmd}')

    def setUp(self):
        self.armed = pr(**Rearm.ARMED)
        self.active_run = {'id': 100, 'status': 'in_progress',
                           'display_title': f'lane pr=366 head={HEAD} lane=false auto=true'}
        self.jobs = {'total_count': 1, 'jobs': [{'name': 'automerge', 'status': 'in_progress'}]}
        self.api_error = None

    def test_rearm_waits_without_consuming_it_then_retries_after_completion(self):
        # A posted PASS but still has labels/cleanup to finish. B would be deduped away.
        with patch.object(A, 'fetch_open_prs', return_value=[self.armed]), \
                patch.object(A, 'fetch_comments', return_value=[Rearm.LANE, Rearm.CLEAN]), \
                patch.object(A, 'fetch_label_events', return_value=[]), \
                patch.object(A, 'REARMED', set()), patch.object(A, 'log'), \
                patch.object(A, 'run', return_value=SimpleNamespace(returncode=0)) as edit, \
                patch('subprocess.check_output', side_effect=self.api_response):
            for status in ('in_progress', 'queued', None):
                with self.subTest(status=status):
                    self.jobs['jobs'] = [{'name': 'automerge', 'status': status}] if status else []
                    self.jobs['total_count'] = len(self.jobs['jobs'])
                    A.rearm_pass([self.armed], False)
                    edit.assert_not_called()
                    self.assertNotIn(366, A.REARMED)
            self.jobs = {'total_count': 1, 'jobs': [
                {'name': 'automerge', 'status': 'completed', 'conclusion': 'success'}]}
            A.rearm_pass([self.armed], False)
            self.assertEqual(edit.call_count, 2)
            self.assertIn('--remove-label', edit.call_args_list[0].args[0])
            self.assertIn('--add-label', edit.call_args_list[1].args[0])
            self.assertIn(366, A.REARMED)

    def test_api_doubt_defers_rearm_without_consuming_it(self):
        with patch.object(A, 'fetch_open_prs', return_value=[self.armed]), \
                patch.object(A, 'fetch_comments', return_value=[Rearm.LANE, Rearm.CLEAN]), \
                patch.object(A, 'fetch_label_events', return_value=[]), \
                patch.object(A, 'REARMED', set()), patch.object(A, 'log'), \
                patch.object(A, 'run', return_value=SimpleNamespace(returncode=0)) as edit, \
                patch('subprocess.check_output', side_effect=self.api_response):
            self.api_error = OSError('offline')
            A.rearm_pass([self.armed], False)
            edit.assert_not_called()
            self.assertNotIn(366, A.REARMED)
            self.api_error = None
            self.jobs = {'total_count': 2, 'jobs': []}
            A.rearm_pass([self.armed], False)
            edit.assert_not_called()
            self.assertNotIn(366, A.REARMED)

    def test_unrelated_or_skipped_jobs_do_not_delay_rearm(self):
        names = [f'lane pr=367 head={HEAD} lane=false auto=true',
                 f'lane pr=366 head={OLD} lane=false auto=true',
                 f'lane pr=366 head={HEAD} lane=true auto=false',
                 self.active_run['display_title']]
        for name in names:
            with self.subTest(name=name), \
                    patch.object(A, 'fetch_open_prs', return_value=[self.armed]), \
                    patch.object(A, 'fetch_comments', return_value=[Rearm.LANE, Rearm.CLEAN]), \
                    patch.object(A, 'fetch_label_events', return_value=[]), \
                    patch.object(A, 'REARMED', set()), patch.object(A, 'log'), \
                    patch.object(A, 'run', return_value=SimpleNamespace(returncode=0)) as edit, \
                    patch('subprocess.check_output', side_effect=self.api_response):
                self.active_run['display_title'] = name
                self.jobs = {'total_count': 1, 'jobs': [
                    {'name': 'automerge', 'status': 'completed', 'conclusion': 'skipped'}
                    if name == names[-1] else {'name': 'automerge', 'status': 'in_progress'}]}
                A.rearm_pass([self.armed], False)
                self.assertEqual(edit.call_count, 2)


class Batching(unittest.TestCase):
    def test_large_pr_goes_alone(self):
        self.assertEqual(A.make_batches([(1, 100), (2, 401), (3, 100)]), [[2], [1, 3]])

    def test_exactly_400_is_small(self):
        self.assertEqual(A.make_batches([(1, 400), (2, 150)]), [[1, 2]])

    def test_line_cap(self):
        self.assertEqual(A.make_batches([(1, 350), (2, 300), (3, 200)]), [[1], [2, 3]])

    def test_pr_cap(self):
        self.assertEqual(A.make_batches([(n, 10) for n in range(1, 8)]), [[1, 2, 3, 4, 5], [6, 7]])

    def test_empty(self):
        self.assertEqual(A.make_batches([]), [])


class OutputAndComment(unittest.TestCase):
    def test_matching_and_sanitizing_findings_include_suspected_siblings(self):
        self.assertIn('matching, sanitizing or page/title parsing', A.INSTRUCTION)
        self.assertIn('sibling cases', A.INSTRUCTION)
        self.assertIn('suspected', A.INSTRUCTION)
        self.assertIn('not blocking', A.INSTRUCTION)
        self.assertIn('concrete failure scenario', A.INSTRUCTION)
        self.assertIn('No style notes', A.INSTRUCTION)

    def test_instruction_blocks_a_pipeline_pr_without_cost_and_catch(self):
        # Owner, 2026-10-09: the per-PR app builds ran 140 times in a week and caught nothing (#1196); a PR adding
        # recurring cost must say what it costs and catches, and the audit blocks one that doesn't (#1202).
        self.assertIn('"Cost and catch"', A.INSTRUCTION)
        self.assertIn('recurring cost', A.INSTRUCTION)
        self.assertIn('report that as blocking', A.INSTRUCTION)

    ANSWER = (
        "### PR #366\n\n1. **Plausible:** `Foo.swift:12` scenario.\n\n"
        "### PR #372: Speak leftover URL fragments\nNo blocking findings.\n"
    )

    def test_split_sections(self):
        s = A.split_sections(self.ANSWER, [366, 372, 380])
        self.assertEqual(set(s), {366, 372})
        self.assertTrue(s[366].startswith("1. **Plausible:**"))
        self.assertEqual(s[372], "No blocking findings.")

    def test_unknown_or_empty_section_dropped(self):
        s = A.split_sections("### PR #999\nx\n### PR #1\n\n", [1])
        self.assertEqual(s, {})

    def test_comment_first_line_and_batch_footer(self):
        body = A.build_comment(366, HEAD, "No blocking findings.", [366, 372, 380])
        self.assertEqual(body.splitlines()[0], "**Claude audit on `68fc333`**")
        self.assertIn("Claude ran read-only", body)
        legacy = A.build_comment(366, HEAD, "No blocking findings.", [366], reviewer="Codex")
        self.assertEqual(legacy.splitlines()[0], "**Codex audit (Astra) on `68fc333`**")
        self.assertIn("Batched with #372, #380.", body)
        # The posted comment must count as an audit on this head next run.
        self.assertTrue(A.audited_on([{"created_at": "z", "body": body}], HEAD))

    def test_single_has_no_batch_line(self):
        self.assertNotIn("Batched", A.build_comment(366, HEAD, "x", [366]))

    def test_issue_sections(self):
        body = ("**Outcome.** x\n\n**Done when**\n1. One.\n2. Two.\n\n"
                "**Must not break:** #287's toggle; owner data.\n**Tier:** T1.\n")
        s = A.issue_sections(body)
        self.assertEqual(s["Done when"], "1. One.\n2. Two.")
        self.assertEqual(s["Must not break"], "#287's toggle; owner data.")

    def test_issue_sections_markdown_headings(self):
        s = A.issue_sections("## Done when\n- a\n\n## Must not break\n- b\n## Notes\nz")
        self.assertEqual(s, {"Done when": "- a", "Must not break": "- b"})


class ClaudeReadiness(unittest.TestCase):
    def test_needs_the_cli_and_the_keychain_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            cli = Path(tmp) / "claude"
            with patch.object(A, "CLAUDE", cli):
                ok, why = A.check_claude()
                self.assertFalse(ok)
                self.assertIn("missing", why)
                cli.write_text("#!/bin/sh\n")
                with patch.object(A, "claude_token", return_value=None):
                    ok, why = A.check_claude()
                self.assertFalse(ok)
                self.assertIn("Keychain", why)
                with patch.object(A, "claude_token", return_value="tok"):
                    self.assertEqual(A.check_claude()[0], True)

    def test_token_comes_from_the_keychain_service(self):
        seen = []
        def run(cmd, **kwargs):
            seen.append(cmd)
            return SimpleNamespace(stdout="  secret\n", stderr="", returncode=0)
        with patch.object(A, "run", run):
            self.assertEqual(A.claude_token(), "secret")
        self.assertEqual(seen[0][-3:], ["-s", A.KEYCHAIN_SERVICE, "-w"])
        with patch.object(A, "run", lambda *a, **k: SimpleNamespace(stdout="", stderr="x", returncode=44)):
            self.assertIsNone(A.claude_token())

    def test_paused_run_posts_nothing_and_says_why(self):
        cand = dict(pr(number=1), lines=1, issues=[], reason="new head", ready_at="")
        with patch.object(A, "find_candidates", return_value=([cand], {}, [])), \
             patch.object(A, "check_claude", return_value=(False, "no Claude token in the Keychain")), \
             patch.object(A, "audit_batch") as audit, patch.object(A, "log") as log:
            self.assertEqual(A.audit_prs([pr(number=1)], False, "", 0.0), 0)
        audit.assert_not_called()
        self.assertIn("paused: no Claude token", log.call_args_list[-1].args[0])


class Paths(unittest.TestCase):
    # The script moved from artifacts/tools/ to ops/codex/; git and gh run in REPO_ROOT.
    def test_repo_root_is_the_checkout(self):
        self.assertTrue((A.REPO_ROOT / "AGENTS.md").is_file())
        self.assertEqual(A.OPS_DIR, A.REPO_ROOT / "artifacts" / "ops")

    def test_the_audit_no_longer_depends_on_codex(self):
        source = Path(A.__file__).read_text()
        self.assertNotIn("codex_limits", source)
        self.assertNotIn("codex exec", source)


CLAUDE_RESULT = {"type": "result", "subtype": "success", "is_error": False, "result": "### PR #1\nNo blocking findings.",
                 "total_cost_usd": 0.27,
                 "usage": {"input_tokens": 10, "cache_creation_input_tokens": 80, "cache_read_input_tokens": 10,
                           "output_tokens": 10}}


class RunClaude(unittest.TestCase):
    def call(self, result, returncode=0, token="tok"):
        seen = {}
        class Process:
            pid = 1
            def __init__(self, command, **kwargs):
                seen.update(command=command, **kwargs)
                self.stdout = kwargs["stdout"]
                self.returncode = returncode
            def communicate(self, prompt, timeout):
                seen["prompt"] = prompt
                self.stdout.write(json.dumps(result).encode())
                return None, "stderr text"
        with tempfile.TemporaryDirectory() as tmp, patch.object(A.subprocess, "Popen", Process), \
             patch.object(A, "claude_token", return_value=token), patch.object(A, "CLAUDE", Path(tmp) / "claude"):
            (Path(tmp) / "claude").write_text("")
            out = Path(tmp) / "answer.md"
            ok, why = A.run_claude(Path(tmp), out, "the prompt", Path(tmp) / "transcript.jsonl")
            answer = out.read_text() if out.exists() else None
        return ok, why, answer, seen

    def test_call_is_headless_read_only_and_keeps_the_prompt_off_the_command_line(self):
        ok, why, answer, seen = self.call(CLAUDE_RESULT)
        self.assertTrue(ok, why)
        self.assertEqual(answer, CLAUDE_RESULT["result"])
        command = seen["command"]
        self.assertEqual(command[1:3], ["-p", "-"])
        self.assertEqual(command[command.index("--tools") + 1], "Read,Grep,Glob")
        self.assertEqual(command[command.index("--permission-mode") + 1], "dontAsk")
        self.assertIn("--max-budget-usd", command)
        self.assertNotIn("the prompt", command)
        self.assertEqual(seen["prompt"], "the prompt")
        self.assertEqual(seen["env"]["CLAUDE_CODE_OAUTH_TOKEN"], "tok")
        self.assertNotIn("ANTHROPIC_API_KEY", seen["env"])

    def test_failures_are_reported_and_leave_no_answer(self):
        failed = dict(CLAUDE_RESULT, is_error=True, subtype="error_max_budget_usd", result="over budget")
        ok, why, answer, _ = self.call(failed, returncode=1)
        self.assertFalse(ok)
        self.assertIn("error_max_budget_usd", why)
        self.assertIsNone(answer)
        ok, why, answer, _ = self.call(dict(CLAUDE_RESULT, result="  "))
        self.assertEqual((ok, answer), (False, None))
        ok, why, _, _ = self.call(CLAUDE_RESULT, token=None)
        self.assertEqual((ok, why), (False, "no Claude token in the Keychain"))


class FailureMemory(unittest.TestCase):
    def test_a_head_whose_audit_failed_twice_is_left_alone_until_it_changes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(A, "FAILURES_PATH", Path(tmp) / "f.json"):
            self.assertEqual(A.load_failures(), {})
            A.record_failure(5, HEAD)
            self.assertEqual(A.failed_count(A.load_failures(), 5, HEAD), 1)
            A.record_failure(5, HEAD)
            failures = A.load_failures()
            self.assertEqual(A.failed_count(failures, 5, HEAD), 2)
            self.assertEqual(A.failed_count(failures, 5, OLD), 0)  # a new head starts again
            A.record_failure(5, OLD)
            self.assertEqual(A.failed_count(A.load_failures(), 5, OLD), 1)
            A.clear_failure(5)
            self.assertEqual(A.load_failures(), {})
            (Path(tmp) / "f.json").write_text("not json")
            self.assertEqual(A.load_failures(), {})

    def test_find_candidates_skips_it_and_says_why(self):
        risky = [{"filename": "Packages/SessionKit/Sources/SessionKitAudio/X.swift", "additions": 1, "deletions": 0}]
        lane = {"created_at": "2026-10-09T10:00:00Z", "body": f"Lane report pr366-r1 — PASS\ncommit {HEAD[:7]} tested"}
        def find(fails):
            with patch.object(A, "fetch_comments", return_value=[lane]), patch.object(A, "fetch_files", return_value=risky), \
                 patch.object(A, "FAILURES", {"366": {"head": HEAD, "fails": fails}}):
                return A.find_candidates([pr()])
        cands, skips, _ = find(1)
        self.assertEqual([c["number"] for c in cands], [366])
        cands, skips, decisions = find(2)
        self.assertEqual((cands, skips), ([], {"audit failed twice": 1}))
        self.assertEqual(decisions[0][1], "audit failed twice on this head")

    def test_a_bold_clean_verdict_is_posted_as_clean(self):
        for text in ("**No blocking findings.**", "_No blocking findings._", "## No blocking findings", "No blocking findings."):
            with self.subTest(text=text):
                section = A.split_sections(f"### PR #366\n{text}\n\nNotes.", [366])[366]
                body = A.build_comment(366, HEAD, section, [366])
                self.assertTrue(A.head_audit([{"created_at": "z", "body": body}], HEAD)[1].lower().startswith("no blocking"))
        findings = A.split_sections("### PR #366\n**1. High:** it loses data", [366])[366]
        self.assertTrue(findings.startswith("**1."))

    def test_claude_audit_requests_count(self):
        self.assertTrue(A.asks_for_audit("Please run a Claude audit on this one."))
        self.assertTrue(A.asks_for_audit("/claude audit"))
        self.assertFalse(A.asks_for_audit("This doesn't need a Claude audit."))


class HeadFiles(unittest.TestCase):
    def export(self, files, blobs):
        """blobs: path -> (mode, size, text or an Exception for show)."""
        def run(cmd, **kwargs):
            if cmd[1] == "ls-tree":
                path = cmd[-1]
                if path not in blobs:
                    return SimpleNamespace(stdout="", stderr="", returncode=128)
                mode, size, _ = blobs[path]
                return SimpleNamespace(stdout=f"{mode} blob abc123 {size if size is not None else '-':>7}\t{path}\n",
                                       stderr="", returncode=0)
            text = blobs[cmd[-1].split(":", 1)[1]][2]
            if isinstance(text, Exception):
                raise text
            return SimpleNamespace(stdout=text, stderr="", returncode=0)
        with tempfile.TemporaryDirectory() as tmp, patch.object(A, "run", run):
            rel = A.export_head_files(Path(tmp), 7, HEAD, files)
            root = Path(tmp) / rel
            copied = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
            return rel, copied, (root / A.INDEX_NAME).read_text()

    def test_changed_files_are_copied_and_odd_ones_listed(self):
        names = ["App/Foo.swift", "gone.txt", "../escape.txt", "/abs.txt", "research/B4/notes.md", "logo.png",
                 "big.txt", "link", "sub", "missing.txt", "INDEX.txt", "x" * 300]
        files = [{"filename": n, "status": "removed" if n == "gone.txt" else "added"} for n in names]
        blobs = {"App/Foo.swift": ("100644", 10, "let a = 1\n"),
                 "logo.png": ("100644", 10, UnicodeDecodeError("utf-8", b"\x89", 0, 1, "bad")),
                 "big.txt": ("100644", A.HEAD_FILE_CAP + 1, "x"),
                 "link": ("120000", 6, "target"), "sub": ("160000", None, ""),
                 "INDEX.txt": ("100644", 3, "own"), "x" * 300: ("100644", 3, "long")}
        rel, copied, index = self.export(files, blobs)
        self.assertEqual(rel, ".sm-audit/pr-7-head")
        self.assertEqual(copied, ["App/Foo.swift", "INDEX.txt", A.INDEX_NAME])
        for line in ("gone.txt: deleted", "../escape.txt: skipped", "/abs.txt: skipped",
                     "research/B4/notes.md: research/", "logo.png: not copied (UnicodeDecodeError)",
                     "big.txt: too large", "link: symlink", "sub: submodule", "missing.txt: not readable"):
            self.assertIn(line, index)
        self.assertNotIn("INDEX.txt: ", index.replace(A.INDEX_NAME, ""))  # the changed INDEX.txt was copied, not clobbered

    def test_total_cap_and_clean_index(self):
        with patch.object(A, "HEAD_TOTAL_CAP", 25):
            names = [f"f{i}.txt" for i in range(3)]
            files = [{"filename": n, "status": "added"} for n in names]
            _, copied, index = self.export(files, {n: ("100644", 10, "0123456789") for n in names})
        self.assertEqual(copied, [A.INDEX_NAME, "f0.txt", "f1.txt"])
        self.assertIn("f2.txt: too large", index)
        _, _, index = self.export([], {})
        self.assertEqual(index, "Every changed file was copied.\n")

    def test_prompt_points_at_the_copies(self):
        block = A.pr_context_block(dict(pr(number=7), lines=3, issues=[]), {}, ".sm-audit/pr-7.diff", OLD, OLD)
        self.assertIn(".sm-audit/pr-7-head/<path>", block)
        self.assertNotIn("git show", block)
        self.assertIn("cannot run commands", A.build_prompt([dict(pr(number=7), lines=3)], [block], OLD))


class UsageRecording(unittest.TestCase):
    def test_batch_retains_transcript_and_records_once_even_on_timeout(self):
        for ok in (True, False):
            with self.subTest(ok=ok), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scratch = root / 'scratch'
                scratch.mkdir()
                kept = root / 'kept'
                ledger = root / 'ledger'
                def run(command, **kwargs):
                    if command[:3] == ['git', 'worktree', 'add']:
                        Path(command[-2]).mkdir()
                    output = HEAD if command[-1] == 'FETCH_HEAD' else OLD
                    if command[:3] == ['gh', 'pr', 'comment']:
                        output = 'https://github.com/uncomposed/spoken-margins-native/pull/1#issuecomment-42'
                    return SimpleNamespace(stdout=output, stderr='', returncode=0)
                def claude(wt, answer, prompt, transcript):
                    transcript.write_text(json.dumps(CLAUDE_RESULT) + '\n')
                    if ok:
                        answer.write_text('### PR #1\nNo blocking findings.\n### PR #2\nNo blocking findings.')
                    return ok, 'ok' if ok else 'timed out'
                batch = [dict(pr(number=n), lines=1, issues=[], reason='new head') for n in (1, 2)]
                with patch.object(A, 'run', run), patch.object(A, 'run_claude', claude), \
                     patch.object(A, 'fetch_comments', return_value=[]), patch.object(A, 'log'), \
                     patch.object(A, 'OUTPUT_KEEP_DIR', kept), patch.object(A.usage, 'DEFAULT_DIR', ledger), \
                     patch.object(A.tempfile, 'mkdtemp', return_value=str(scratch)), \
                     patch.object(A.subprocess, 'run'), patch.object(A, 'FAILURES_PATH', root / 'failures.json'):
                    A.audit_batch(batch)
                rows = [json.loads(line) for line in (ledger / 'usage.jsonl').read_text().splitlines()]
                self.assertEqual(len(rows), 1)
                self.assertEqual(len(rows[0]['targets']), 2)
                self.assertEqual(rows[0]['input_tokens'], 100)
                self.assertEqual(rows[0]['model'], A.CLAUDE_MODEL)
                self.assertEqual(len(list(kept.glob('*.jsonl'))), 1)
                self.assertFalse(scratch.exists())
                self.assertEqual(rows[0]['outcome']['kind'], 'audit completed' if ok else 'failed')
                failures = json.loads((root / 'failures.json').read_text()) if (root / 'failures.json').exists() else {}
                self.assertEqual(A.failed_count(failures, 1, HEAD), 0 if ok else 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
