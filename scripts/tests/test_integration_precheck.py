import datetime as dt
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / 'integration-precheck.py'
spec = importlib.util.spec_from_file_location('integration_precheck', PATH)
precheck = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = precheck
spec.loader.exec_module(precheck)

TIP = 'f5f8c83b0333d62a42a5000b377aecc20837e453'
REPORT = {'id': 6004410624, 'created_at': '2026-10-05T22:26:02Z', 'issue': 184,
          'user': {'login': 'uncomposed'}, 'html_url': 'https://github.com/uncomposed/spoken-margins-native/issues/184#issuecomment-6004410624',
          'body': '```text\nLane report integration-f5f8c83 — INCONCLUSIVE\ncommit f5f8c83b\n'
                  'run by: SM integration run\nThe log shows the simulator\'s audio output failing to start '
                  '("AddRunningClient failed"). The run hit the plan\'s 600 s cap.\n'
                  'Next step: the Test Desk should check the Mac\'s audio output before a retry.\n```'}
# Recorded 2026-10-05/06 skip comments, #337. Excerpts retain the varied causes
# and timestamps; the original report is the stable identity across all five.
SKIPS = [
    (6005638644, '2026-10-05T23:42:04Z', "integration run skipped: next's tip (f5f8c83) is the commit the 18:30 run already covered (INCONCLUSIVE, simulator audio fault), no merges since, and under three hours have passed. The next run retries once three hours are up."),
    (6007598899, '2026-10-06T01:42:57Z', "integration run skipped: next's tip (f5f8c83) is the same commit the last integration run already tried (INCONCLUSIVE, --plan app hit its 600 s cap; see #184). Re-running the same commit on the same plan would likely repeat it, so a person or a plan-cap fix should come first. No simulator touched."),
    (6008871406, '2026-10-06T03:42:00Z', "integration run skipped: next's tip (f5f8c83) is unchanged since the last integration run, which ended INCONCLUSIVE (--plan app hit its cap, see #184). No new merges, so a re-run would repeat it. No simulator touched."),
    (6010147550, '2026-10-06T05:41:56Z', "integration run skipped: next's tip f5f8c83 is the commit the last integration run already tested (INCONCLUSIVE, plan cap hit). No new merges since, so nothing new to test."),
    (6011718659, '2026-10-06T07:42:05Z', "integration run skipped (03:41 EDT): next's tip f5f8c83 is unchanged and was already tried (INCONCLUSIVE, simulator audio fault); no new merges to test. Needs an owner or desk look at the Mac's simulator audio before a retry is useful."),
]


def comment(body, created='2026-10-06T08:00:00Z', identifier=7000000000, issue=337, login='uncomposed'):
    return {'body': body, 'created_at': created, 'id': identifier, 'issue': issue, 'user': {'login': login}}


class FakeOps:
    def __init__(self, root, tip=TIP, comments=None):
        self.path = root / 'state.json'
        self.tip, self.comments = tip, comments or [REPORT]
        self.posts = []
    def snapshot(self):
        return self.tip, self.comments
    def post(self, body):
        self.posts.append(body)
        return 'https://github.com/note'


class PrecheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ops = FakeOps(Path(self.tmp.name))

    def run_at(self, timestamp='2026-10-06T09:00:00Z', dry=False):
        return precheck.execute(self.ops, precheck.parse_time(timestamp), dry_run=dry)

    def test_five_recorded_skips_become_one_note_and_zero_model_launches(self):
        for identifier, timestamp, body in SKIPS:
            self.ops.comments.append(comment(body, timestamp, identifier))
            self.assertFalse(self.run_at(timestamp).go)
        self.assertEqual(len(self.ops.posts), 1)
        self.assertIn('simulator audio', self.ops.posts[0])
        self.assertIn('unblock', self.ops.posts[0].lower())

    def test_new_tip_goes_once_then_waits_for_report_or_new_context(self):
        self.ops.tip = 'a' * 40
        self.assertTrue(self.run_at().go)
        self.assertFalse(self.run_at().go)
        self.assertFalse(self.ops.posts)
        self.ops.comments.append(comment('/integration-retry', identifier=7000000001))
        self.assertTrue(self.run_at().go)
        self.assertFalse(self.run_at().go)

    def test_new_owner_or_desk_context_wakes_but_same_account_automation_does_not(self):
        cases = [('The Mac audio output is fixed; try again.', True),
                 ('Test Desk hand-off: audio now works.', True),
                 ('**13:17 CDT (Mac tick)** · next `f5f8c83`\nMemory warn.', False),
                 ('integration run f5f8c83 — PASS (retry completed).', False),
                 ('Thread "Codex worker 1" stopping: none.', False),
                 ('**Codex audit (Astra) on `f5f8c83`**\nNo blocking findings.', False)]
        for body, go in cases:
            with self.subTest(body=body):
                decision = precheck.decide(TIP, [REPORT, comment(body)], {}, precheck.parse_time('2026-10-06T09:00:00Z'))
                self.assertEqual(decision.go, go)
        stranger = comment('/integration-retry', login='someone-else')
        self.assertFalse(precheck.decide(TIP, [REPORT, stranger], {}, precheck.parse_time('2026-10-06T09:00:00Z')).go)

    def test_three_hour_desk_rule_holds_new_tip_and_retry_without_consuming_them(self):
        self.ops.tip = 'a' * 40
        self.ops.comments.append(comment('Test Desk hand-off: working here.', issue=184))
        self.ops.comments.append(comment('/integration-retry', identifier=7000000001))
        self.assertFalse(self.run_at('2026-10-06T10:59:59Z').go)
        self.assertTrue(self.run_at('2026-10-06T11:00:00Z').go)

    def test_existing_note_survives_lost_local_state_and_varied_skip_words(self):
        self.run_at()
        note = comment(self.ops.posts[0], identifier=7000000002)
        self.ops.path.unlink()
        self.ops.comments.append(note)
        self.assertFalse(self.run_at().go)
        self.assertEqual(len(self.ops.posts), 1)

    def test_new_report_resets_blocker_note_but_pass_never_posts_one(self):
        self.run_at()
        newer = dict(REPORT, id=6004410625, created_at='2026-10-06T08:00:00Z')
        self.ops.comments.append(newer)
        self.assertFalse(self.run_at().go)
        self.assertEqual(len(self.ops.posts), 2)
        newest = dict(newer, id=6004410626, created_at='2026-10-06T08:01:00Z', body=newer['body'].replace('INCONCLUSIVE', 'PASS'))
        self.ops.comments.append(newest)
        self.assertFalse(self.run_at().go)
        self.assertEqual(len(self.ops.posts), 2)

    def test_dry_run_writes_no_state_or_note(self):
        self.assertFalse(self.run_at(dry=True).go)
        self.assertFalse(self.ops.path.exists())
        self.assertFalse(self.ops.posts)

    def test_git_github_and_post_errors_fail_open(self):
        for stage in ('snapshot', 'post'):
            with self.subTest(stage=stage):
                original = getattr(self.ops, stage)
                def fail(*args):
                    raise RuntimeError('GitHub or git unavailable')
                setattr(self.ops, stage, fail)
                self.assertTrue(self.run_at().go)
                setattr(self.ops, stage, original)

    def test_report_and_skip_sha_extraction_do_not_use_old_control_commit(self):
        parsed = precheck.integration_report(dict(REPORT, body=REPORT['body'] + '\nControl ad5d048 passed earlier.'))
        self.assertEqual(parsed['sha'], 'f5f8c83b')
        self.assertEqual(parsed['outcome'], 'INCONCLUSIVE')
        for _, timestamp, body in SKIPS:
            self.assertEqual(precheck.skip_head(comment(body, timestamp)), 'f5f8c83')

    def test_untrusted_actor_cannot_supply_reports_or_hide_a_blocker_note(self):
        fake = dict(REPORT, id=7000000001, created_at='2026-10-06T08:00:00Z',
                    user={'login': 'someone-else'}, body=REPORT['body'].replace('INCONCLUSIVE', 'PASS'))
        self.assertIsNone(precheck.integration_report(fake))
        self.run_at()
        forged = comment(self.ops.posts[0], login='someone-else')
        decision = precheck.decide(TIP, [REPORT, fake, forged], {}, precheck.parse_time('2026-10-06T09:00:00Z'))
        self.assertFalse(decision.go)
        self.assertIsNotNone(decision.note)

    def test_person_blocker_is_noted_once_even_during_the_desk_hold(self):
        report = dict(REPORT, created_at='2026-10-06T08:00:00Z',
                      body=REPORT['body'].replace('SM integration run', 'Test Desk'))
        self.ops.comments = [report]
        self.assertFalse(self.run_at().go)
        self.assertEqual(len(self.ops.posts), 1)
        self.assertFalse(self.run_at().go)
        self.assertEqual(len(self.ops.posts), 1)

    def test_report_formats_and_neighboring_whitespace_case_and_unicode(self):
        for body, sha, outcome in [
            (REPORT['body'], 'f5f8c83b', 'INCONCLUSIVE'),
            (REPORT['body'].replace('```text\n', '```text\n\n'), 'f5f8c83b', 'INCONCLUSIVE'),
            (REPORT['body'].replace('f5f8c83', 'F5F8C83'), 'f5f8c83b', 'INCONCLUSIVE'),
            ('Codex Test Desk: f5f8c83\n\nPASS — 659 passed', 'f5f8c83', 'PASS'),
            ('integration run f5f8c83 — PASS (retry completed).', 'f5f8c83', 'PASS')]:
            with self.subTest(body=body[:70]):
                result = precheck.integration_report(dict(REPORT, body=body))
                self.assertEqual((result['sha'], result['outcome']), (sha, outcome))
        for body in ('', 'Other job integration-f5f8c83 — PASS', 'integration run skipped: next’s tip (f5f8c83) is unchanged.'):
            self.assertIsNone(precheck.integration_report(comment(body)))
        self.assertEqual(precheck.skip_head(comment('integration run skipped: next’s tip (f5f8c83) is unchanged.')), 'f5f8c83')

    def test_editing_an_old_report_does_not_replace_a_newer_run(self):
        older = dict(REPORT, updated_at='2026-10-06T08:59:00Z')
        newer = dict(REPORT, id=6004410625, created_at='2026-10-06T08:00:00Z',
                     body=REPORT['body'].replace('INCONCLUSIVE', 'PASS'))
        decision = precheck.decide(TIP, [older, newer], {}, precheck.parse_time('2026-10-06T09:00:00Z'))
        self.assertFalse(decision.go)
        self.assertIsNone(decision.note)

    def test_editing_a_retry_request_is_new_context_once(self):
        self.ops.comments.append(comment('Audio still broken.', identifier=7000000001))
        self.assertTrue(self.run_at().go)
        self.ops.comments[-1].update(body='/integration-retry', updated_at='2026-10-06T08:30:00Z')
        self.assertTrue(self.run_at().go)
        self.assertFalse(self.run_at().go)

    def test_corrupted_saved_trigger_fails_open_instead_of_silencing_retries(self):
        self.ops.path.write_text(json.dumps({'last_go': {'tip': TIP, 'wake_key': ['zzzz', 0]}}))
        self.ops.comments.append(comment('/integration-retry'))
        self.assertTrue(self.run_at().go)
        self.assertFalse(self.ops.posts)

    def test_cli_prints_one_stop_line_and_dry_run_saves_nothing(self):
        out = io.StringIO()
        with patch.object(precheck, 'Ops', return_value=self.ops), contextlib.redirect_stdout(out):
            self.assertEqual(precheck.main(['--dry-run']), 0)
        self.assertEqual(len(out.getvalue().splitlines()), 1)
        self.assertTrue(out.getvalue().startswith('STOP: '))
        self.assertFalse(self.ops.path.exists())
        self.assertFalse(self.ops.posts)

    def test_hook_only_targets_initial_integration_prompts(self):
        cases = [(precheck.PROMPT_MARKER + '\nRun the integration procedure.', True),
                 ('\ufeff  ' + precheck.PROMPT_MARKER, True),
                 (precheck.LEGACY_TASK_PREFIXES[0] + " on the owner's Mac.", True),
                 (precheck.LEGACY_TASK_PREFIXES[1] + " on the owner's Mac.", True),
                 ('Explain ' + precheck.PROMPT_MARKER, False),
                 ('Please retry the failed test from this session.', False),
                 ('SM Mac tick', False), ('', False)]
        for prompt, expected in cases:
            with self.subTest(prompt=prompt):
                self.assertEqual(precheck.hook_target({'hook_event_name': 'UserPromptSubmit', 'prompt': prompt}), expected)
        self.assertFalse(precheck.hook_target({'hook_event_name': 'PreToolUse', 'prompt': precheck.PROMPT_MARKER}))

    def test_hook_stop_is_a_real_block_and_go_cannot_double_precheck(self):
        stopped = precheck.decide(TIP, [REPORT], {}, precheck.parse_time('2026-10-06T09:00:00Z'))
        self.assertEqual(precheck.hook_output(stopped)['decision'], 'block')
        self.ops.tip = 'a' * 40
        allowed = self.run_at()
        output = precheck.hook_output(allowed)
        self.assertNotIn('decision', output)
        self.assertIn('Do not run the precheck again', output['hookSpecificOutput']['additionalContext'])
        self.assertFalse(self.run_at().go)  # A model-side second precheck would wrongly stop the launch.

    def test_hook_cli_emits_valid_json_and_unrelated_prompt_has_no_side_effects(self):
        for prompt, block in ((precheck.PROMPT_MARKER, True), ('Help with the PDF reader', False)):
            with self.subTest(prompt=prompt):
                out = io.StringIO()
                payload = json.dumps({'hook_event_name': 'UserPromptSubmit', 'prompt': prompt})
                with patch.object(precheck, 'Ops', return_value=self.ops), \
                     patch.object(sys, 'stdin', io.StringIO(payload)), contextlib.redirect_stdout(out):
                    self.assertEqual(precheck.main(['--claude-hook', '--dry-run']), 0)
                if block:
                    self.assertEqual(json.loads(out.getvalue())['decision'], 'block')
                else:
                    self.assertEqual(out.getvalue(), '')
        self.assertFalse(self.ops.path.exists())
        self.assertFalse(self.ops.posts)


if __name__ == '__main__':
    unittest.main()
