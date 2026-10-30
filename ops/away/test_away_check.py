"""Host tests for the away check. Run: python3 -m unittest discover -s ops/away"""
import datetime as dt
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import away_check as a  # noqa: E402

UTC = dt.timezone.utc


def issue(n, *labels, title='An issue'):
    return {'number': n, 'title': title, 'labels': [{'name': x} for x in labels]}


class QueueTests(unittest.TestCase):
    def test_in_progress_and_duplicates_do_not_count(self):
        ready = [issue(1, 'ready'), issue(2, 'ready', 'in-progress'), issue(3, 'ready', 'found-by-audit')]
        audits = [issue(3, 'ready', 'found-by-audit'), issue(4, 'review-finding'),
                  issue(5, 'found-by-audit', 'in-progress')]
        q = a.queue_verdict(ready, audits, threads=2, hours=2, rate=1.0)
        self.assertEqual((q['ready'], q['audits'], q['have']), (2, 1, 3))
        self.assertEqual(q['need'], 4)
        self.assertFalse(q['enough'])
        self.assertEqual(q['short'], 1)

    def test_enough_when_queue_covers_the_time_away(self):
        q = a.queue_verdict([issue(n, 'ready') for n in range(10)], [], threads=3, hours=3, rate=1.0)
        self.assertTrue(q['enough'])
        self.assertEqual(q['short'], 0)

    def test_rate_scales_the_need(self):
        q = a.queue_verdict([], [], threads=5, hours=12, rate=0.5)
        self.assertEqual(q['need'], 30)


AGENTS = '''# Agent guide

## Current focus

- **Owner's standing calls (2026-10-16).** Don't ask again:
  - **Later work stays off the lane.** He picked "Yes, pause it".
    - A `Later` issue that needs simulator tests waits until Solid Ground ships.
  - **Open Source goes ahead of Co-op.** He said "I am giving you the go." The Co-op work meanwhile is planning only.
- **Co-op is next.** No `ready` labels on Co-op issues until then.
- **Voice downloads (owner, 2026-10-14):** that work waits for Solid Ground.
- `main` holds Build 30. Kitten holds the voice until the phone cools.
- It is an order, not a hold: Co-op code runs alongside it.

## How to work

Scripted journeys are different (owner, 2026-09-30).

- A new script can't block work until the Test Desk has seen it pass twice.
- Never stop mid-PR: work until the PR is open.

```zsh
until false; do wait; done
```
'''


class HoldTests(unittest.TestCase):
    def setUp(self):
        self.holds = {h['line']: h for h in a.scan_holds(AGENTS)}

    def test_hold_under_his_quoted_wait_is_the_owners(self):
        self.assertEqual(self.holds[6]['backing'], 'owner')
        self.assertEqual(self.holds[7]['backing'], 'owner')

    def test_the_10_16_hold_under_a_go_is_not_backed(self):
        # His words were "I am giving you the go"; the hold beside them was the agent's.
        self.assertEqual(self.holds[8]['backing'], 'unbacked')
        self.assertIn('planning only', self.holds[8]['text'])

    def test_agent_written_hold_with_no_owner_call_is_suspect(self):
        self.assertEqual(self.holds[9]['backing'], 'suspect')

    def test_owner_tag_without_his_words_is_unbacked(self):
        self.assertEqual(self.holds[10]['backing'], 'unbacked')

    def test_lead_in_paragraph_covers_its_bullets(self):
        self.assertNotEqual(self.holds[18]['backing'], 'suspect')

    def test_non_holds_are_skipped(self):
        # "holds Build 30" / a player rule, "not a hold", "work until", the code fence
        for line in (11, 12, 19, 22):
            self.assertNotIn(line, self.holds)

    def test_owner_quote_needs_a_date(self):
        self.assertFalse(a.is_owner_quoted('He said "upload it now" today.'))
        self.assertTrue(a.is_owner_quoted('He said "upload it now" on 2026-10-17.'))
        self.assertTrue(a.is_owner_quoted('**Planning (owner, 2026-10-08):** milestones'))
        self.assertFalse(a.is_owner_quoted('Keep bulk out of your context (2026-10-14).'))

    def test_report_lists_the_strongest_holds_first(self):
        now = dt.datetime(2026, 10, 17, 13, 0, tzinfo=UTC)
        dial = {'mode': 'paced', 'threads': 5, 'stop': 97, 'hours_early': 0, 'problems': []}
        text = a.report(now, 12, dial, a.queue_verdict([], [], 5, 12), list(self.holds.values()),
                        [], [], [], a.pace(now, {'usage': None, 'halted_by': []}, dial))
        listed = [x for x in text.splitlines() if x.startswith('   - line')]
        self.assertIn('planning only', listed[0])
        self.assertIn('No `ready`', listed[1])


class OwnerItemTests(unittest.TestCase):
    def test_run_ask_needs_a_command_and_words_to_the_owner(self):
        self.assertTrue(a.asks_owner_to_run('Next owner step: run `ops/power/install.sh` then Allow.'))
        self.assertTrue(a.asks_owner_to_run('Cole, please paste this:\n\n```zsh\nlaunchctl list\n```\n'))
        self.assertTrue(a.asks_owner_to_run('Could you run\n```\nscripts/phone-build\n```'))

    def test_narrative_and_empty_are_not_asks(self):
        self.assertFalse(a.asks_owner_to_run(''))
        self.assertFalse(a.asks_owner_to_run('The same command run from the Terminal panel built fine.'))
        self.assertFalse(a.asks_owner_to_run('Please run the lane again when it frees up.'))
        self.assertFalse(a.asks_owner_to_run('`xcodebuild` failed in actool; owner step is none.\n```\n```'))

    def test_owner_merge_paths(self):
        self.assertTrue(a.touches_owner_paths([{'path': 'scripts/lane-runner.py'}]))
        self.assertTrue(a.touches_owner_paths([{'path': '.github/workflows/ci.yml'}]))
        self.assertFalse(a.touches_owner_paths([{'path': 'scripts/lane-runner-tests.py'}]))
        self.assertFalse(a.touches_owner_paths([{'path': 'docs/.github-notes.md'}]))


class PaceTests(unittest.TestCase):
    DIAL = {'mode': 'paced', 'threads': 5, 'stop': 97, 'hours_early': 0, 'problems': []}

    def test_behind_the_line_says_allowance_is_unused(self):
        now = dt.datetime(2026, 10, 21, 11, 0, tzinfo=UTC)   # Wednesday, 4 of 7 days gone
        usage = {'usage': {'percent': 20, 'at': now - dt.timedelta(hours=1)}, 'halted_by': []}
        p = a.pace(now, usage, self.DIAL)
        self.assertAlmostEqual(p['line'], 97 * 4 / 7, places=3)
        self.assertLess(p['gap'], -3)
        text = a.report(now, 12, self.DIAL, a.queue_verdict([], [], 5, 12), [], [], [], [], p)
        self.assertIn('behind the line', text)
        self.assertIn('Breaker clear', text)

    def test_missing_usage_and_stale_tick(self):
        now = dt.datetime(2026, 10, 21, 11, 0, tzinfo=UTC)
        p = a.pace(now, {'usage': None, 'halted_by': []}, self.DIAL)
        self.assertIsNone(p['percent'])
        old = {'usage': {'percent': 55, 'at': now - dt.timedelta(hours=5)}, 'halted_by': ['claude']}
        text = a.report(now, 8, self.DIAL, a.queue_verdict([], [], 5, 8), [], [], [], [],
                        a.pace(now, old, self.DIAL))
        self.assertIn('5 hours old', text)
        self.assertIn('HALT for claude', text)


class ReportTests(unittest.TestCase):
    def test_short_numbered_report(self):
        now = dt.datetime(2026, 10, 17, 13, 0, tzinfo=UTC)
        dial = {'mode': 'paced', 'threads': 5, 'stop': 97, 'hours_early': 0, 'problems': []}
        many = [issue(n, 'needs-owner', title='x' * 200) for n in range(10)]
        holds = [{'line': n, 'text': 'work waits for something ' * 10, 'backing': ('owner', 'unbacked', 'suspect')[n % 3]}
                 for n in range(20)]
        q = a.queue_verdict([issue(1, 'ready')], [], 5, 12)
        p = a.pace(now, {'usage': {'percent': 1, 'at': now}, 'halted_by': []}, dial)
        text = a.report(now, 12, dial, q, holds, many, many, many, p)
        lines = text.splitlines()
        self.assertLessEqual(len(lines), 25)
        self.assertTrue(all(len(x) < 260 for x in lines))
        for n in '1234':
            self.assertTrue(any(x.startswith(f'{n}. ') for x in lines))
        self.assertIn('thin', lines[1])
        self.assertIn('Short by 59', lines[1])

    def test_dial_off_says_nothing_starts(self):
        now = dt.datetime(2026, 10, 17, 13, 0, tzinfo=UTC)
        dial = {'mode': 'off', 'threads': 5, 'stop': 97, 'hours_early': 0, 'problems': []}
        q = a.queue_verdict([], [], 0, 12)
        p = a.pace(now, {'usage': None, 'halted_by': []}, dial)
        text = a.report(now, 12, dial, q, [], [], [], [], p)
        self.assertIn('the Dial is Off', text)
        self.assertIn('3. Only you: nothing', text)


class OverlayTests(unittest.TestCase):
    """The standing calls moved to the owner overlay (#1854): the scan must still see holds written there."""

    def read(self, overlay_text):
        with tempfile.TemporaryDirectory() as home:
            if overlay_text is not None:
                (Path(home) / 'ops').mkdir()
                (Path(home) / 'ops' / 'OWNER.md').write_text(overlay_text)
            run = mock.Mock(return_value=mock.Mock(stdout='# Public guide\n'))
            with mock.patch.object(a.subprocess, 'run', run), mock.patch.object(a, 'ops_home', return_value=Path(home)):
                return a.agents_md('main')

    def test_overlay_text_is_appended_when_present(self):
        text = self.read('## Current focus\n- Held: Co-op waits for the LLC.\n')
        self.assertIn('# Public guide', text)
        self.assertEqual([h['line'] for h in a.scan_holds(text)], [4])

    def test_missing_overlay_leaves_the_public_guide_alone(self):
        self.assertEqual(self.read(None).strip(), '# Public guide')


if __name__ == '__main__':
    unittest.main()
