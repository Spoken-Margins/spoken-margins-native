"""scripts/journey_runs.py (#3903): the Test Desk's run records are read from desk reports and counted."""
import contextlib
import datetime as dt
import importlib.util
import io
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('journey_runs', SCRIPTS / 'journey_runs.py')
jr = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = jr
spec.loader.exec_module(jr)

NOW = dt.datetime(2026, 11, 10, 12, 0, tzinfo=dt.timezone.utc)

DESK_REPORT = '''Lane report t4-3925 — FAIL
commit bb00725 · tier T4 · simulator iPhone 17, iOS 26.1 · 31 min
ran: J1 (pass), J7 (fail at step 1)
record: J1 · build bb00725 · steps 9/9 · bugs none
record: J7 · build bb00725 · steps 0/3 · bugs #3931, #3932
crashes: none
'''
OLD_REPORT = '''Lane report t4-3800 — PASS
commit 3997dbb · tier T4 · 20 min
ran: J2 (pass)
'''
RUNNER_REPORT = '''Lane report pr3900-r1 — PASS
record: J1 · build abc1234 · steps 1/1 · bugs none
'''


def comment(body, login='uncomposed'):
    return {'body': body, 'user': {'login': login}, 'author_association': 'MEMBER'}


class FakeApi:
    def __init__(self, comments):
        self.comments = comments

    def get(self, path):
        assert path.startswith('issues/comments?since='), path
        return self.comments


class ParseTests(unittest.TestCase):
    def test_records_are_read_with_bugs(self):
        runs = jr.parse_records(DESK_REPORT)
        self.assertEqual([r['journey'] for r in runs], ['J1', 'J7'])
        self.assertEqual(runs[1], {'journey': 'J7', 'build': 'bb00725', 'steps_passed': 0, 'steps_total': 3,
                                   'bugs': [3931, 3932]})
        self.assertEqual(runs[0]['bugs'], [])

    def test_a_scenario_and_pipe_separators(self):
        runs = jr.parse_records('record: scenario | build 3997dbb | steps 2/3 | bugs #3940\n')
        self.assertEqual((runs[0]['journey'], runs[0]['steps_passed'], runs[0]['bugs']), ('scenario', 2, [3940]))

    def test_lookalikes_are_not_records(self):
        for line in ('ran: J7 · build x · steps 1/1 · bugs none', 'record: J7 build x steps 1/1 bugs none',
                     'record: J7 · build x · steps one/3 · bugs none', 'note record: J7 · build x · steps 1/1 · bugs none',
                     'record: J7 · build x · steps 1/1 · bugs #12 and more'):
            self.assertEqual(jr.parse_records(line), [], line)


class DocTests(unittest.TestCase):
    def test_the_example_in_the_report_format_parses(self):
        text = (SCRIPTS.parent / 'docs/workstreams/test-lane.md').read_text()
        block = text.split('## Report format')[1].split('```')[1]
        self.assertEqual([r['journey'] for r in jr.parse_records(block)], ['J1', 'J7'])

    def test_the_journey_skill_names_the_record_line(self):
        self.assertIn('record:', (SCRIPTS.parent / '.claude/skills/journey/SKILL.md').read_text())


class SummaryTests(unittest.TestCase):
    def test_counts_cover_only_desk_reports_and_flag_the_unrecorded(self):
        summary = jr.summarize([comment(DESK_REPORT), comment(OLD_REPORT), comment(RUNNER_REPORT),
                                comment('Looks good, no lane report here')])
        self.assertEqual((summary['desk_reports'], summary['unrecorded_reports']), (2, 1))
        self.assertEqual((summary['runs'], summary['runs_with_bugs']), (2, 1))
        self.assertEqual((summary['steps_passed'], summary['steps_total']), (9, 12))
        self.assertEqual(summary['bugs'], [3931, 3932])
        self.assertEqual(summary['per_journey']['J7']['bugs'], [3931, 3932])

    def test_main_reads_through_the_api_and_prints_counts(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = jr.main(['--window-days', '7'], api=FakeApi([comment(DESK_REPORT)]), now=NOW)
        self.assertEqual(code, 0)
        self.assertIn('runs: 2, 1 found at least one bug', out.getvalue())
        self.assertIn('bugs filed: #3931, #3932', out.getvalue())

    def test_a_stranger_report_is_ignored(self):
        stranger = comment(DESK_REPORT, login='mallory')
        stranger['author_association'] = 'NONE'
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jr.main([], api=FakeApi([stranger]), now=NOW)
        self.assertIn('desk reports: 0', out.getvalue())


if __name__ == '__main__':
    unittest.main()
