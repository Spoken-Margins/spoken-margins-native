import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import journey_promotion as jp

J1, J2, J3 = 'AppUITests/J1Tests', 'AppUITests/J2Tests', 'AppUITests/J3Tests'


class StreakTests(unittest.TestCase):
    def test_passes_accumulate_and_a_bad_run_resets_them(self):
        streaks = {}
        for status, expected in (('passed', (1, 0)), ('passed', (2, 0)), ('failed', (0, 1)), ('missing', (0, 2)),
                                 ('passed', (1, 0))):
            streaks = jp.update(streaks, {J1: status})
            self.assertEqual((streaks[J1]['passes'], streaks[J1]['bad']), expected, status)

    def test_a_skipped_or_unrun_script_keeps_what_it_had(self):
        streaks = jp.update({}, {J1: 'passed'})
        for status in ('skipped', 'not_run'):
            streaks = jp.update(streaks, {J1: status})
            self.assertEqual(streaks[J1], {'passes': 1, 'bad': 0})

    def test_a_script_no_longer_listed_is_dropped(self):
        self.assertEqual(jp.update({J1: {'passes': 5, 'bad': 0}}, {J2: 'passed'}), {J2: {'passes': 1, 'bad': 0}})


LISTING = {'version': 1,
           'gating': [{'test': J3, 'journey': 'J3'}],
           'probation': [{'test': J1, 'journey': 'J1'}, {'test': J2 + '()', 'journey': 'J2'}]}


class DueTests(unittest.TestCase):
    def test_promotion_needs_two_passes_on_probation_and_demotion_two_bad_runs_on_gating(self):
        rows = [
            ({J1: {'passes': 1, 'bad': 0}}, [], []),
            ({J1: {'passes': 2, 'bad': 0}}, [J1], []),
            ({J2: {'passes': 3, 'bad': 0}}, [J2], []),  # selectors compare without the trailing ()
            ({J3: {'passes': 9, 'bad': 0}}, [], []),  # already gating
            ({J3: {'passes': 0, 'bad': 1}}, [], []),
            ({J3: {'passes': 0, 'bad': 2}}, [], [J3]),
            ({J1: {'passes': 0, 'bad': 5}}, [], []),  # a failing probation script stays on probation
            ({}, [], []),
        ]
        for streaks, promote, demote in rows:
            with self.subTest(streaks=streaks):
                self.assertEqual(jp.due(LISTING, streaks), {'promote': promote, 'demote': demote})

    def test_apply_moves_entries_whole_and_leaves_the_rest(self):
        moved = jp.apply(LISTING, {'promote': [J1], 'demote': [J3]})
        self.assertEqual(moved['gating'], [{'test': J1, 'journey': 'J1'}])
        self.assertEqual(moved['probation'], [{'test': J2 + '()', 'journey': 'J2'}, {'test': J3, 'journey': 'J3'}])
        self.assertEqual(moved['version'], 1)
        self.assertEqual(LISTING['gating'], [{'test': J3, 'journey': 'J3'}])  # the input is untouched

    def test_the_report_line_names_each_move_and_how_to_make_it(self):
        self.assertIsNone(jp.report_line({'promote': [], 'demote': []}))
        line = jp.report_line({'promote': [J1, J2], 'demote': [J3]})
        self.assertIn('J1Tests, J2Tests passed twice running, move to gating', line)
        self.assertIn('J3Tests bad twice running, move back to probation', line)
        self.assertIn('journey_promotion.py --apply', line)
        self.assertFalse(line.startswith('scripted journeys'), 'phone-build reads the first line starting so')


class ReportTests(unittest.TestCase):
    """The hosted run keeps no state file, so it counts streaks from the journey lines of #184's earlier reports (#2894)."""

    def body(self, line):
        return ('```text\nLane report integration-abc1234 — PASS\nran:\n  1. --plan app: 3 passed\n'
                + (f'  scripted journeys (only those on gating are verdict input): {line}\n' if line else '')
                + 'outcome: ok\n```\n')

    def test_a_report_line_is_matched_back_to_the_listing_by_last_path_part(self):
        listing = {'gating': [{'test': 'AppUITests/Gate1FlowUITests/testEditor', 'journey': 'x'}],
                   'probation': [{'test': J1, 'journey': 'J1'}, {'test': J2 + '()', 'journey': 'J2'}]}
        body = self.body('testEditor passed, J1Tests failed, J2Tests not_run, GoneTests passed')
        self.assertEqual(jp.results_from_report(body, listing),
                         {'AppUITests/Gate1FlowUITests/testEditor': 'passed', J1: 'failed', J2: 'not_run'})

    def test_two_scripts_that_share_a_last_path_part_are_not_credited(self):
        listing = {'gating': [], 'probation': [{'test': 'A/AClass/testFoo', 'journey': 'a'},
                                               {'test': 'A/BClass/testFoo', 'journey': 'b'}, {'test': J1, 'journey': 'J1'}]}
        self.assertEqual(jp.results_from_report(self.body('testFoo passed, J1Tests passed'), listing), {J1: 'passed'})

    def test_a_report_with_no_journey_line_says_nothing(self):
        self.assertEqual(jp.results_from_report(self.body(''), LISTING), {})
        self.assertEqual(jp.results_from_report('', LISTING), {})

    def test_two_passing_reports_in_a_row_are_due_and_a_failure_in_between_is_not(self):
        passing, failing = self.body('J1Tests passed, J2Tests passed'), self.body('J1Tests failed, J2Tests passed')
        streaks = jp.streaks_from_reports([passing, passing], LISTING)
        self.assertEqual(jp.due(LISTING, streaks)['promote'], [J1, J2])
        streaks = jp.streaks_from_reports([passing, failing, passing], LISTING)
        self.assertEqual((streaks[J1], streaks[J2]), ({'passes': 1, 'bad': 0}, {'passes': 3, 'bad': 0}))
        self.assertEqual(jp.due(LISTING, streaks)['promote'], [J2])

    def test_a_report_the_script_cannot_read_is_skipped_not_fatal(self):
        streaks = jp.streaks_from_reports(['Lane report journeys-1', None, self.body('J1Tests passed')], LISTING)
        self.assertEqual(streaks[J1], {'passes': 1, 'bad': 0})


class CommandTests(unittest.TestCase):
    def test_apply_rewrites_the_listing_from_the_saved_streaks(self):
        with tempfile.TemporaryDirectory() as tmp:
            listing, state = Path(tmp) / 'scripted-journeys.json', Path(tmp) / 'state.json'
            listing.write_text(json.dumps(LISTING, indent=2) + '\n')
            state.write_text(json.dumps({'journeys': {J1: {'passes': 2, 'bad': 0}}}))
            self.assertEqual(jp.main(['--state', str(state), '--listing', str(listing)]), 0)
            self.assertEqual(json.loads(listing.read_text()), LISTING)  # listing only, no --apply
            self.assertEqual(jp.main(['--state', str(state), '--listing', str(listing), '--apply']), 0)
            self.assertEqual([e['test'] for e in json.loads(listing.read_text())['gating']], [J3, J1])

    def test_a_promoted_script_sheds_its_probation_batch(self):
        listing = {'version': 1, 'gating': [], 'probation': [{'test': J1, 'journey': 'J1', 'batch': 2},
                                                              {'test': J3, 'journey': 'J3', 'batch': 2}]}
        moved = jp.apply(listing, {'promote': [J1], 'demote': []})
        self.assertEqual(moved['gating'], [{'test': J1, 'journey': 'J1'}])
        self.assertEqual(moved['probation'], [{'test': J3, 'journey': 'J3', 'batch': 2}])
        back = jp.apply(moved, {'promote': [], 'demote': [J1]})
        self.assertEqual(back['probation'][-1], {'test': J1, 'journey': 'J1'})  # batch 1 again

    def test_the_real_listing_has_the_shape_the_command_edits(self):
        listing = json.loads(jp.LISTING.read_text())
        self.assertEqual(jp.apply(listing, {'promote': [], 'demote': []}), listing)


if __name__ == '__main__':
    unittest.main()


def cut_body(results):
    """A scripted-journeys report on #184 with this journeys line."""
    line = ', '.join(f"{t.rsplit('/', 1)[-1]} {status}" for t, status in results.items())
    return f'```text\nLane report scripted-journeys-abc1234 \u2014 PASS\n  scripted journeys (only those on gating are verdict input): {line}\n```\n'


class RedReportTests(unittest.TestCase):
    """#3881: four scripts sat red for days under a PASS. New red and the scripts that must end lead the report."""

    def red(self, history, now):
        return jp.red_report(LISTING, [cut_body(h) for h in history], now)

    def test_red_now_and_not_red_at_the_last_cut_is_new(self):
        self.assertEqual(self.red([{J1: 'passed'}], {J1: 'failed'}), {'new': [J1], 'must_end': []})
        self.assertEqual(self.red([], {J1: 'missing'}), {'new': [J1], 'must_end': []})

    def test_a_probation_script_red_at_two_cuts_running_must_end_and_is_no_longer_new(self):
        self.assertEqual(self.red([{J1: 'failed'}], {J1: 'failed'}), {'new': [], 'must_end': [(J1, 2)]})
        self.assertEqual(self.red([{J1: 'failed'}, {J1: 'missing'}], {J1: 'failed'}), {'new': [], 'must_end': [(J1, 3)]})

    def test_a_pass_between_reds_starts_the_count_again(self):
        self.assertEqual(self.red([{J1: 'failed'}, {J1: 'passed'}], {J1: 'failed'}), {'new': [J1], 'must_end': []})

    def test_a_cut_that_did_not_run_the_script_keeps_its_streak(self):
        self.assertEqual(self.red([{J1: 'failed'}, {J1: 'not_run'}, {J1: 'skipped'}], {J1: 'failed'}),
                         {'new': [], 'must_end': [(J1, 2)]})

    def test_a_script_that_did_not_run_this_cut_is_never_named(self):
        # Review of #3881: skipped or not_run keeps the old streak, which must not read as red now.
        for status in ('skipped', 'not_run'):
            self.assertEqual(self.red([{J1: 'failed'}], {J1: status}), {'new': [], 'must_end': []}, status)
            self.assertEqual(self.red([{J1: 'failed'}, {J1: 'failed'}], {J1: status}), {'new': [], 'must_end': []}, status)

    def test_a_gating_script_is_new_red_but_never_must_end_because_demotion_covers_it(self):
        self.assertEqual(self.red([{J3: 'failed'}], {J3: 'failed'}), {'new': [], 'must_end': []})
        self.assertEqual(self.red([{J3: 'passed'}], {J3: 'failed'}), {'new': [J3], 'must_end': []})

    def test_a_green_script_and_a_script_with_trailing_parens_in_the_listing_are_judged_like_the_rest(self):
        self.assertEqual(self.red([{J2: 'failed'}], {J2: 'failed', J1: 'passed'}), {'new': [], 'must_end': [(J2, 2)]})

    def test_comments_that_are_not_reports_change_nothing(self):
        found = jp.red_report(LISTING, ['looks fine', '', cut_body({J1: 'failed'}), 'scripted journeys (only those'],
                              {J1: 'failed'})
        self.assertEqual(found, {'new': [], 'must_end': [(J1, 2)]})


class RedLinesTests(unittest.TestCase):
    def test_the_lines_name_scripts_by_their_last_part_and_the_merges_by_number(self):
        lines = jp.red_lines({'new': [J1], 'must_end': [(J2, 3)]}, 'abc1234', ['#12 Add a thing', '#11 Fix it'])
        self.assertEqual(lines[0], 'new red since the last cut (abc1234; merges since #12, #11): J1Tests')
        self.assertTrue(lines[1].startswith('must end (probation scripts red at 2 or more cuts running'))
        self.assertTrue(lines[1].endswith(': J2Tests (3 cuts)'))

    def test_nothing_red_says_none_and_a_long_range_is_cut_short(self):
        quiet = jp.red_lines({'new': [], 'must_end': []}, 'abc1234', [])
        self.assertEqual((quiet[0], quiet[1][-6:]), ('new red since the last cut (abc1234): none', ': none'))
        long = jp.red_lines({'new': [J1], 'must_end': []}, 'abc1234', [f'#{n} x' for n in range(30)], shown=3)
        self.assertIn('merges since #0, #1, #2 and 27 more)', long[0])

    def test_no_earlier_cut_and_unreadable_merges_are_said_not_guessed(self):
        self.assertIn('(no earlier cut on #184)', jp.red_lines({'new': [J1], 'must_end': []}, None, [])[0])
        self.assertIn('abc1234; no merge commits found since', jp.red_lines({'new': [J1], 'must_end': []}, 'abc1234', [])[0])
