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

    def test_the_real_listing_has_the_shape_the_command_edits(self):
        listing = json.loads(jp.LISTING.read_text())
        self.assertEqual(jp.apply(listing, {'promote': [], 'demote': []}), listing)


if __name__ == '__main__':
    unittest.main()
