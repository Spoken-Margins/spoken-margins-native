import datetime as dt
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import report
import usage

START = dt.datetime(2026, 10, 5, tzinfo=dt.timezone.utc)
HEAD = 'cbbbff8' + '0' * 33
FILE = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackStartCue.swift'
# Exact relevant excerpts from #580, audit and fix reply 5997695487. The
# unaccepted chime fix is distinct from the unchanged, accepted late-chime bug.
AUDIT = ('1. **[P2] The chime continues over newly started speech.** '
         f'`{FILE}:72–76` — The chime continues over narration.')
FIX = {'created_at': '2026-10-06T01:00:00Z', 'body':
       '**Findings fixed in `5bd3adf`**. These are the findings from the Codex audit of `cbbbff8`:\n'
       '1. **Slow synchronous startup still misses the one-second cue: not changed here.** '
       'This is the late-chime finding the owner accepted. It is tracked in #842.\n'
       '2. **The chime continues over newly started speech: fixed.** PlaybackStartCue stops the chime.'}


def row(run_id, job='audit', prs=(580,), outcome=None, time='2026-10-05T12:00:00Z'):
    return {'run_id': run_id, 'job': job, 'time': time,
            'input_tokens': 100, 'cached_input_tokens': 90, 'output_tokens': 10, 'usage_complete': True,
            'targets': [{'pr': pr, 'issues': [], 'head_sha': HEAD,
                         'outcome': outcome or usage.audit_outcome(AUDIT), 'comment_url': 'https://audit'} for pr in prs]}


class GitHub:
    def pull(self, number):
        return {'merged_at': '2026-10-06T02:00:00Z'}
    def comments(self, number):
        return [FIX]
    def compare(self, head, sha):
        return {'status': 'ahead', 'files': [{'filename': FILE}]}
    def bug(self, number):
        return {'labels': [{'name': 'bug'}]}


class StrangerTests(unittest.TestCase):
    """#1822: a stranger's "fixed in" comment is not evidence of a fix."""

    def test_only_trusted_authors_comments_are_read(self):
        comments = [dict(FIX, user={'login': 'mallory'}, author_association='NONE'),
                    dict(FIX, user={'login': 'uncomposed'}, author_association='OWNER')]
        github = report.GitHub('owner/repo')
        github.cache['issues/5/comments?per_page=100'] = comments
        self.assertEqual(github.comments(5), comments[1:])


class ReportTests(unittest.TestCase):
    def test_recorded_finding_is_counted_only_with_a_later_commit(self):
        run = row('a')
        self.assertEqual(len(report.confirmed_fixes(run, run['targets'][0], [FIX], GitHub().compare)), 1)
        for diff in ({'status': 'identical', 'files': [{'filename': FILE}]},
                     {'status': 'ahead', 'files': [{'filename': 'different.swift'}]}):
            self.assertFalse(report.confirmed_fixes(run, run['targets'][0], [FIX], lambda *args: diff))
        early = dict(FIX, created_at='2026-10-01T00:00:00Z')
        self.assertFalse(report.confirmed_fixes(run, run['targets'][0], [early], GitHub().compare))

    def test_batch_counted_once_and_cache_never_added_twice(self):
        result = report.summarize([row('a', prs=(580, 567))], START, GitHub())
        self.assertEqual(result['total']['tokens'], 110)
        self.assertEqual(result['tokens_per_merged_pr'], 55)

    def test_repeated_outcomes_not_equal_finding_counts(self):
        first = row('a')
        second = row('b', time='2026-10-05T13:00:00Z')
        new = row('c', time='2026-10-05T14:00:00Z', outcome=usage.audit_outcome(AUDIT.replace('chime', 'speech')))
        self.assertEqual(report.repeated_runs([first, second, new]), {'b'})
        result = report.summarize([first, second, new], START, GitHub())
        self.assertEqual(result['fixed_audit_findings'], 1)  # Same fixed bug counted once.
        self.assertIsNone(result['repeated_token_share'])  # Less than a week of evidence.

    def test_partial_usage_never_becomes_zero_or_a_complete_ratio(self):
        partial = row('a')
        partial.update(input_tokens=None, usage_complete=False)
        result = report.summarize([partial], START, GitHub())
        self.assertEqual(result['total']['missing_fields'], 1)
        self.assertIsNone(result['tokens_per_merged_pr'])
        self.assertIsNone(result['tokens_per_fixed_audit_finding'])

    def test_bugs_count_new_issues_once_and_not_comments_on_existing_bugs(self):
        run = row('a', job='testdesk-diagnosis', prs=())
        run['posted'] = [{'issue': 900, 'created': True}, {'issue': 901, 'created': False}]
        result = report.summarize([run], START, GitHub())
        self.assertEqual(result['testdesk_bugs_filed'], [900])
        self.assertEqual(result['tokens_per_testdesk_bug'], 110)

    def test_claude_turns_are_summarized_apart_from_wrapper_totals(self):
        def turn(run_id, job, time, links=(), complete=True):
            return {'kind': 'turn', 'run_id': run_id, 'session_id': run_id[:1], 'job': job, 'time': time,
                    'input_tokens': 1000, 'cached_input_tokens': 900, 'output_tokens': 50,
                    'usage_complete': complete, 'outcome_links': list(links)}
        link = 'https://github.com/o/r/issues/337#issuecomment-1'
        claude = [turn('a1', 'scheduled:sm-mac-tick', '2026-10-05T12:00:00Z', [link]),
                  turn('a2', 'scheduled:sm-mac-tick', '2026-10-06T12:00:00Z', [link], complete=False),
                  turn('b1', 'finisher', '2026-10-06T12:00:00Z'),
                  turn('c1', 'finisher', '2026-10-13T00:00:00Z'),  # the next week
                  {'kind': 'session-check', 'run_id': 's', 'session_id': 'a', 'job': 'scheduled:sm-mac-tick',
                   'time': '2026-10-06T12:00:00Z', 'transcript_models': ['claude-opus-5-5'],
                   'transcript': {'input_tokens': 1, 'cache_creation_input_tokens': 0,
                                  'cache_read_input_tokens': 0, 'output_tokens': 1},
                   'client_reported': {'input_tokens': 3, 'cache_creation_input_tokens': 0,
                                       'cache_read_input_tokens': 0, 'output_tokens': 1,
                                       'models': ['claude-opus-5-5[1m]']},
                   'client_total_is_final': True}]
        result = report.summarize([row('a')], START, GitHub(), claude)
        self.assertEqual(result['total']['tokens'], 110)  # wrapper totals unchanged
        tick = result['claude']['by_job']['scheduled:sm-mac-tick']
        self.assertEqual((tick['runs'], tick['tokens'], tick['incomplete_runs'], tick['outcome_links']), (2, 2100, 1, 1))
        self.assertEqual(result['claude']['total']['runs'], 3)
        self.assertEqual(result['claude']['outcome_links'], [link])
        self.assertEqual(result['claude']['coverage']['transcript_share'], 0.5)
        self.assertIsNone(report.summarize([row('a')], START, GitHub())['claude'])


if __name__ == '__main__':
    unittest.main()
