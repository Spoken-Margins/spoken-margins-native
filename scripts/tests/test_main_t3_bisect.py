"""#4574: bisecting a red scheduled main T3 to the merge that broke it (scripts/main_t3_bisect.py).

The bisection itself is tested against a table of every culprit position for several list lengths, and against probes
that fault or flake. The git range is tested on a real temporary repository.
"""
from __future__ import annotations

import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import main_t3_bisect as B  # noqa: E402

RED = 'f' * 40
GREEN = 'e' * 40
WANTED = {'SpokenMarginsAppTests/Foo/testA'}  # the test ids that failed in the red run


def shas(n):
    return [f'{i:040x}' for i in range(1, n + 1)]


def probe_for(commits, culprit, log=None, script=None):
    """A probe where commits at or after `culprit` fail. `script` {sha: [outcomes...]} overrides the first calls."""
    script = {k: list(v) for k, v in (script or {}).items()}

    def probe(sha):
        if log is not None:
            log.append(sha)
        if script.get(sha):
            return script[sha].pop(0)
        return B.FAIL if commits.index(sha) >= culprit else B.PASS

    return probe


class BisectTests(unittest.TestCase):
    def test_every_culprit_position_is_found_in_about_log2_probes(self):
        for n in (1, 2, 3, 5, 8, 17, 30, 64, 100):
            commits = shas(n)
            for culprit in range(n):
                with self.subTest(n=n, culprit=culprit):
                    log = []
                    result = B.bisect(commits, probe_for(commits, culprit, log))
                    self.assertEqual((result.kind, result.sha), ('culprit', commits[culprit]), result.reason)
                    # log2(n) probes to narrow it down, plus one more on the culprit itself.
                    self.assertLessEqual(len(log), math.ceil(math.log2(n)) + 1)
                    self.assertEqual(log.count(commits[culprit]), 1 if culprit == n - 1 else 2)
                    if culprit == n - 1:
                        self.assertEqual(log[-1], commits[-1])  # the head is checked on its own, last

    def test_a_head_culprit_is_probed_once_on_its_own_classes(self):
        commits = shas(4)
        log = []
        result = B.bisect(commits, probe_for(commits, 3, log))
        self.assertEqual(result.sha, commits[3])
        self.assertEqual(log.count(commits[3]), 1)

    def test_a_failure_that_does_not_reproduce_in_isolation_names_no_pr(self):
        # The whole run failed FooTests (another test's pollution, or a flake that outlived the retries), and every
        # commit passes with only FooTests: blaming the newest merge would be a guess.
        for n in (1, 2, 6):
            commits = shas(n)
            with self.subTest(n=n):
                result = B.bisect(commits, lambda sha: B.PASS)
                self.assertEqual((result.kind, result.sha), ('undecided', None))
                self.assertIn('depends on others', result.reason)

    def test_one_merge_since_green_is_the_culprit_after_one_probe_of_it(self):
        log = []
        result = B.bisect(['a' * 40], probe_for(['a' * 40], 0, log))
        self.assertEqual((result.kind, result.sha, log), ('culprit', 'a' * 40, ['a' * 40]))

    def test_nothing_between_green_and_red_decides_nothing(self):
        result = B.bisect([], lambda sha: self.fail('no probe needed'))
        self.assertEqual((result.kind, result.sha), ('undecided', None))

    def test_a_runner_fault_gets_one_retry_then_the_bisection_is_undecided(self):
        commits = shas(8)
        mid = commits[3]
        once = B.bisect(commits, probe_for(commits, 5, script={mid: [B.UNDECIDED]}))
        self.assertEqual((once.kind, once.sha), ('culprit', commits[5]))
        self.assertEqual([o for s, o in once.probes if s == mid], [B.UNDECIDED, B.PASS])
        twice = B.bisect(commits, probe_for(commits, 5, script={mid: [B.UNDECIDED, B.UNDECIDED]}))
        self.assertEqual((twice.kind, twice.sha), ('undecided', None))
        self.assertIn(mid[:7], twice.reason)

    def test_a_culprit_that_passes_on_the_repeat_is_a_flake_and_names_no_pr(self):
        commits = shas(8)
        # commits[5] fails on its first probe (as the bisection narrows to it) and passes when repeated.
        result = B.bisect(commits, probe_for(commits, 5, script={commits[5]: [B.FAIL, B.PASS]}))
        self.assertEqual((result.kind, result.sha), ('undecided', None))
        self.assertIn('flaky', result.reason)

    def test_a_culprit_that_cannot_be_repeated_names_no_pr(self):
        commits = shas(8)
        result = B.bisect(commits, probe_for(commits, 5, script={commits[5]: [B.FAIL, B.UNDECIDED, B.UNDECIDED]}))
        self.assertEqual(result.kind, 'undecided')

    def test_out_of_probes_or_time_is_undecided_not_a_guess(self):
        commits = shas(64)
        self.assertEqual(B.bisect(commits, probe_for(commits, 40), max_probes=2).kind, 'undecided')
        self.assertEqual(B.bisect(commits, probe_for(commits, 40), time_left=lambda: False).kind, 'undecided')
        self.assertEqual(B.bisect(commits, probe_for(commits, 40), max_probes=8).kind, 'culprit')
        big = shas(256)
        self.assertEqual(B.bisect(big, probe_for(big, 100)).kind, 'culprit')  # the default cap holds 256 merges
        self.assertEqual(B.bisect(big, probe_for(big, 100, script={big[127]: [B.UNDECIDED]})).kind, 'culprit')

    def test_probes_are_recorded_in_order_with_their_outcomes(self):
        commits = shas(4)
        result = B.bisect(commits, probe_for(commits, 1))
        self.assertEqual(result.probes[0], (commits[1], B.FAIL))
        self.assertEqual(result.runs, len(result.probes))


class ClassifyTests(unittest.TestCase):
    def failed(self, *names):
        return {'passed': 4, 'failed': [(n, []) for n in names]}

    def test_a_pass_is_a_pass(self):
        self.assertEqual(B.classify_probe('PASS', {'passed': 9, 'failed': []}, WANTED), B.PASS)

    def test_a_failing_watched_class_is_a_fail(self):
        self.assertEqual(B.classify_probe('FAIL', self.failed('SpokenMarginsAppTests/Foo/testA'), WANTED), B.FAIL)
        # one watched among others still shows the cause is there
        both = self.failed('SpokenMarginsAppTests/Bar/testB', 'SpokenMarginsAppTests/Foo/testA')
        self.assertEqual(B.classify_probe('FAIL', both, WANTED), B.FAIL)

    def test_a_class_fixed_and_broken_again_in_another_method_does_not_blame_the_old_break(self):
        """m1 broke Foo/testA, F fixed it, m7 broke Foo/testB: the red run fails only testB, so a probe where only
        testA fails (m2) is not the red run's break."""
        wanted = {'SpokenMarginsAppTests/Foo/testB'}
        old_break = self.failed('SpokenMarginsAppTests/Foo/testA')
        self.assertEqual(B.classify_probe('FAIL', old_break, wanted), B.UNDECIDED)
        both = self.failed('SpokenMarginsAppTests/Foo/testA', 'SpokenMarginsAppTests/Foo/testB')
        self.assertEqual(B.classify_probe('FAIL', both, wanted), B.FAIL)
        self.assertEqual(B.watched_failures(both, wanted), ['SpokenMarginsAppTests/Foo/testB'])

    def test_a_different_failure_or_no_test_result_or_a_fault_decides_nothing(self):
        other = self.failed('SpokenMarginsAppTests/Bar/testB')
        self.assertEqual(B.classify_probe('FAIL', other, WANTED), B.UNDECIDED)
        self.assertEqual(B.classify_probe('FAIL', {'passed': 0, 'failed': []}, WANTED), B.UNDECIDED)  # build failure
        self.assertEqual(B.classify_probe('INCONCLUSIVE', {'passed': 0, 'failed': []}, WANTED), B.UNDECIDED)
        # a class name that merely starts like a watched one is not that class
        lookalike = self.failed('SpokenMarginsAppTests/FooExtras/testA')
        self.assertEqual(B.classify_probe('FAIL', lookalike, WANTED), B.UNDECIDED)

    def test_failing_classes_come_from_the_red_runs_manifests_by_plan(self):
        def manifest(failed):
            return {'steps': [{'tests': {t: {'status': 'failed' if t in failed else 'passed'} for t in
                                         ('T/A/test1', 'T/A/test2', 'T/B/test1', 'T/C/test1')}}]}

        chosen = {'app': (manifest({'T/A/test1', 'T/A/test2'}), None),
                  'adapters': (manifest({'T/C/test1'}), manifest({'T/B/test1'}))}
        self.assertEqual(B.failing_classes(chosen), {'app': ['T/A'], 'adapters': ['T/B', 'T/C']})
        self.assertEqual(B.failing_classes({'app': (manifest(set()), None)}), {})
        self.assertEqual(B.class_of('SpokenMarginsAppTests/FooTests/testBar'), 'SpokenMarginsAppTests/FooTests')
        self.assertEqual(B.class_of('Solo'), 'Solo')


class IssueTests(unittest.TestCase):
    result = B.Result('culprit', 'a' * 40, 'x', [('b' * 40, B.FAIL), ('a' * 40, B.FAIL)])

    def test_pr_numbers_from_merge_and_squash_subjects(self):
        for subject, number in (('Merge pull request #4790 from Spoken-Margins/ws/4639-x', 4790),
                                ('Fix the thing (#4501)', 4501), ('Fix the thing (#4501) ', 4501),
                                ('Mention #12 in passing', None), ('Merge branch main', None), ('', None)):
            with self.subTest(subject=subject):
                self.assertEqual(B.pr_number(subject), number)

    def test_one_area_label_is_carried_over_and_anything_else_is_groundwork(self):
        self.assertEqual(B.area_label(['bug', 'area: hear it well']), 'area: hear it well')
        self.assertEqual(B.area_label(['bug']), B.DEFAULT_AREA)
        self.assertEqual(B.area_label(['area: hear it well', 'area: pass it on']), B.DEFAULT_AREA)
        self.assertEqual(B.area_label(['area: hear it well', 'area: hear it well']), 'area: hear it well')

    def test_the_issue_names_the_pr_the_tests_the_run_and_the_range(self):
        tests = ['SpokenMarginsAppTests/Foo/testA', 'SpokenMarginsAppTests/Bar/testB']
        subject = 'Merge pull request #4790 from Spoken-Margins/ws/4639-x'
        self.assertEqual(B.culprit_title(subject, 4790, tests), 'Main T3 red: #4790 broke Foo/testA and 1 more')
        body = B.culprit_body('a' * 40, subject, 4790, RED, GREEN, 'https://run', tests, self.result,
                              'https://issue')
        self.assertTrue(body.startswith(B.CULPRIT_MARKER % ('a' * 40)))
        for text in ('PR #4790', 'https://run', f'{GREEN[:7]}..{RED[:7]}', '`Foo/testA`', '`Bar/testB`',
                     'https://issue', '## Outcome', '## Evidence', '## Done when', '## Must not break'):
            self.assertIn(text, body)

    def test_a_title_without_a_pr_uses_the_subject_and_stays_short(self):
        title = B.culprit_title('Some long subject ' * 20, None, ['T/A/test'])
        self.assertLessEqual(len(title), 120)
        self.assertTrue(title.startswith('Main T3 red: Some long subject'))

    def test_the_culprit_marker_dedupes_only_for_the_same_commit_from_a_trusted_author(self):
        def issue(number, sha, login='github-actions[bot]', association='NONE', pr=False):
            found = {'number': number, 'body': B.CULPRIT_MARKER % sha, 'user': {'login': login},
                     'author_association': association}
            if pr:
                found['pull_request'] = {}
            return found

        sha = 'a' * 40
        self.assertEqual(B.find_open_culprit_issue([issue(9, sha), issue(7, sha)], sha)['number'], 7)
        self.assertIsNone(B.find_open_culprit_issue([issue(7, 'c' * 40)], sha))
        self.assertIsNone(B.find_open_culprit_issue([issue(7, sha, login='stranger')], sha))  # a look-alike
        self.assertIsNotNone(B.find_open_culprit_issue([issue(7, sha, login='x', association='MEMBER')], sha))
        self.assertIsNone(B.find_open_culprit_issue([issue(7, sha, pr=True)], sha))

    def test_an_undecided_note_names_no_pr_and_says_why(self):
        note = B.undecided_note(B.Result('undecided', None, 'abc1234 could not be tested', [('b' * 40, B.UNDECIDED)]),
                                RED, GREEN, 'https://run')
        self.assertIn('names no PR', note)
        self.assertIn('abc1234 could not be tested', note)
        self.assertNotIn('#', note.replace('https://run', ''))


class PresentClassesTests(unittest.TestCase):
    def test_only_classes_declared_in_the_checked_out_tests_are_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            tests = Path(tmp) / B.TEST_SOURCES / 'Sub'
            tests.mkdir(parents=True)
            (tests / 'A.swift').write_text('final class FooTests: XCTestCase {}\nfinal class FooTestsExtra: XCTestCase {}')
            grouped = {'app': ['SpokenMarginsAppTests/FooTests', 'SpokenMarginsAppTests/NewTests'],
                       'adapters': ['SpokenMarginsAppTests/NewTests'], 'other': ['SpokenMarginsAppTests/Foo']}
            self.assertEqual(B.present_classes(grouped, Path(tmp)), {'app': ['SpokenMarginsAppTests/FooTests']})
            self.assertEqual(B.present_classes({}, Path(tmp)), {})
            self.assertEqual(B.present_classes(grouped, Path(tmp) / 'missing'), {})


class MakeProbeTests(unittest.TestCase):
    def test_the_real_probe_loads_the_lane_and_gives_each_probe_its_own_clock(self):
        """The audit on b0d3d2f: make_probe called a loader main_t3 doesn't have, so every real bisection crashed
        before its first probe while the CommandTests, which replace make_probe, passed."""
        loaded = []
        real = B.t3.load_lane_t3
        B.t3.load_lane_t3 = lambda: loaded.append(real()) or loaded[-1]
        try:
            with tempfile.TemporaryDirectory() as tmp:
                probe = B.make_probe({}, set(), 'a' * 40, '1', Path(tmp))
        finally:
            B.t3.load_lane_t3 = real
        self.assertTrue(callable(probe))
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0].T3_TIMEOUT, B.PROBE_TIMEOUT)
        self.assertTrue(callable(loaded[0]._run_t3_grouped))


class CommandTests(unittest.TestCase):
    """command_bisect end to end with git, gh and the lane replaced by recorders."""

    def run_command(self, result_for, failure_issue=True, git_fails=False, red_failed=None, probe_failed=None,
                    closed=None, revert_hooks=None, env=None, open_extra=None, then_revert=False, between=None):
        import argparse
        import json
        import os
        calls = []
        commits = [(sha, f'Merge pull request #{i}00 from x/y') for i, sha in enumerate(shas(4), 1)]
        failed = {'steps': [{'tests': {t: {'status': 'failed'}
                                       for t in red_failed or ['SpokenMarginsAppTests/Foo/testA']}}]}
        if probe_failed is not None:
            result_for.failed = probe_failed
        issue = {'number': 5, 'html_url': 'https://github.com/o/r/issues/5', 'body': B.t3.MARKER,
                 'user': {'login': 'github-actions[bot]'}}

        def gh(*args, stdin=None):
            calls.append((args, stdin))
            if args[:2] == ('api', 'repos/o/r/issues/100'):
                return json.dumps({'labels': [{'name': 'area: hear it well'}]})
            if args[:2] == ('api', '--paginate') and 'state=closed' in args[-1]:
                return ''.join(json.dumps(i) + '\n' for i in closed or [])
            return 'https://github.com/o/r/issues/9'

        def merges(green, red):
            if git_fails:
                raise RuntimeError('git log: bad object')
            return commits

        patches = [(B.t3, 'gh', gh), (B.t3, 'repo', lambda: 'o/r'), (B.t3, 'open_issues',
                                                                       lambda: ([issue] if failure_issue else []) + list(open_extra or [])),
                   (B.t3, 'find_last_green', lambda sha: GREEN), (B.t3, 'read_manifests',
                                                                    lambda ev: {'verify-app': failed}),
                   (B, 'merges_in_range', merges), (B, 'make_probe', lambda *a: result_for),
                   (B, 'git', lambda *a: ''), (os, 'chdir', lambda p: None)] + [
                   (B, name, hook) for name, hook in (revert_hooks or {}).items()]
        saved_env = {k: os.environ.get(k) for k in (env or {})}
        os.environ.update(env or {})
        saved = [(o, n, getattr(o, n)) for o, n, _ in patches]
        for o, n, v in patches:
            setattr(o, n, v)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                args = argparse.Namespace(sha=RED, run_url='https://run', run_id='1', evidence=tmp, budget=10**6)
                bisect_env = {k: os.environ.pop(k, None) for k in (B.REVERT_TOKEN_ENV,)}
                try:
                    self.assertEqual(B.command_bisect(args), 0)
                finally:
                    os.environ.update({k: v for k, v in bisect_env.items() if v is not None})
                saved_json = json.loads((Path(tmp) / 'main-t3-bisect.json').read_text())
                request = Path(tmp) / B.REVERT_REQUEST
                saved_json['revert_request'] = json.loads(request.read_text()) if request.exists() else None
                if then_revert:
                    if between:
                        between()
                    self.assertEqual(B.command_revert(argparse.Namespace(evidence=tmp)), 0)
        finally:
            for o, n, v in saved:
                setattr(o, n, v)
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        return calls, saved_json

    def safe_revert_hooks(self, opened):
        """A culprit whose revert is safe: a merged PR that changed one app file, nothing reverted or open yet."""
        def open_revert(commit, red, run_url, tests, probes, issue, token, area):
            opened.append((commit['sha'], issue, token, area, tests))
            return 'https://github.com/o/r/pull/77', 'https://github.com/o/r/issues/78', ''
        return {'fetch_main': lambda: None,
                'culprit_commit': lambda sha: {'sha': sha, 'parents': ['a' * 40, 'b' * 40],
                                               'subject': 'Merge pull request #100 from x/y', 'body': 'Fix it'},
                'changed_paths': lambda sha: ['App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift'],
                'open_revert_prs': lambda: [], 'reverted_on_main': lambda sha: None, 'open_revert': open_revert,
                'changed_on_main_since': lambda red: ['docs/other.md']}

    def test_a_safe_culprit_with_the_revert_token_is_reverted_and_both_issues_say_so(self):
        opened = []
        calls, record = self.run_command(lambda sha: B.FAIL, revert_hooks=self.safe_revert_hooks(opened),
                                         env={B.REVERT_TOKEN_ENV: 'app-token'}, then_revert=True)
        self.assertEqual(len(opened), 1)
        sha, issue, token, area, tests = opened[0]
        self.assertEqual((sha, issue, token, area), (record['culprit'], 9, 'app-token', 'area: hear it well'))
        create = [c for c in calls if c[0][:2] == ('issue', 'create')][0]
        self.assertNotIn('Not reverted automatically', create[1])
        comments = {c[0][2]: c[1] for c in calls if c[0][:2] == ('issue', 'comment')}
        self.assertEqual(sorted(comments), ['5', '9'])
        for text in comments.values():
            self.assertIn('https://github.com/o/r/pull/77', text)
        self.assertIn('https://github.com/o/r/issues/78', comments['9'])

    def test_without_the_revert_token_nothing_is_reverted_and_the_culprit_issue_says_why(self):
        opened = []
        calls, _ = self.run_command(lambda sha: B.FAIL, revert_hooks=self.safe_revert_hooks(opened),
                                    env={B.REVERT_TOKEN_ENV: ''}, then_revert=True)
        self.assertEqual(opened, [])
        comments = [(c[0][2], c[1]) for c in calls if c[0][:2] == ('issue', 'comment')]
        self.assertEqual([n for n, _ in comments], ['5', '9', '5'])  # the failure issue hears how the revert ended
        for _, text in comments[1:]:
            self.assertIn('Not reverted automatically', text)
            self.assertIn(B.REVERT_TOKEN_ENV, text)
            self.assertIn('will not retry', text)

    def test_bisect_never_reads_the_revert_token_and_leaves_a_request_for_revert(self):
        """The probes run older commits' code for hours: the write token must not be in their environment, and an App
        token minted before them would have expired (one hour) by the time the revert runs."""
        opened, seen = [], []
        hooks = self.safe_revert_hooks(opened)
        hooks['make_probe'] = lambda *a: (lambda sha: seen.append(os.environ.get(B.REVERT_TOKEN_ENV)) or B.FAIL)
        calls, record = self.run_command(None, revert_hooks=hooks, env={B.REVERT_TOKEN_ENV: 'app-token'})
        self.assertEqual(opened, [])
        self.assertTrue(seen)
        self.assertEqual(set(seen), {None})
        request = record['revert_request']
        self.assertEqual((request['sha'], request['culprit_issue'], request['failure_issue'], request['area']),
                         (record['culprit'], 9, 5, 'area: hear it well'))
        body = [c for c in calls if c[0][:2] == ('issue', 'create')][0][1]
        self.assertNotIn('Not reverted automatically', body)

    def test_revert_without_a_request_does_nothing(self):
        import argparse
        with tempfile.TemporaryDirectory() as tmp:
            saved = B.t3.gh
            B.t3.gh = lambda *a, **k: self.fail('no gh call without a request')
            try:
                self.assertEqual(B.command_revert(argparse.Namespace(evidence=tmp)), 0)
            finally:
                B.t3.gh = saved

    def test_an_unreadable_request_or_one_with_no_failure_issue_is_handled(self):
        import argparse
        import json
        posted = []
        saved = (B.t3.gh, B.t3.repo, B.revert_safety)
        B.t3.gh = lambda *a, **k: posted.append(a) or ''
        B.t3.repo = lambda: 'o/r'
        B.revert_safety = lambda *a, **k: (None, ['main moved'])
        try:
            with tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / B.REVERT_REQUEST).write_text('{"sha": ')
                self.assertEqual(B.command_revert(argparse.Namespace(evidence=tmp)), 0)
                self.assertEqual(posted, [])
                (Path(tmp) / B.REVERT_REQUEST).write_text(json.dumps(
                    {'sha': 'c' * 40, 'red': 'd' * 40, 'culprit_issue': 9, 'failure_issue': None}))
                os.environ[B.REVERT_TOKEN_ENV] = 'app-token'
                try:
                    self.assertEqual(B.command_revert(argparse.Namespace(evidence=tmp)), 0)
                finally:
                    os.environ.pop(B.REVERT_TOKEN_ENV, None)
                self.assertEqual([a[2] for a in posted], ['9'])
        finally:
            B.t3.gh, B.t3.repo, B.revert_safety = saved

    def test_revert_checks_the_rules_again_on_the_newest_main(self):
        """Main can move between the two steps: a fix forward that lands then stops the revert."""
        opened = []
        hooks = self.safe_revert_hooks(opened)
        moved = []
        hooks['changed_on_main_since'] = lambda red: list(moved)
        gate = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift'
        calls, record = self.run_command(lambda sha: B.FAIL, revert_hooks=hooks, env={B.REVERT_TOKEN_ENV: 'app-token'},
                                         then_revert=True, between=lambda: moved.append(gate))
        self.assertIsNotNone(record['revert_request'])
        self.assertEqual(opened, [])
        comment = [c[1] for c in calls if c[0][:3] == ('issue', 'comment', '9')][0]
        self.assertIn('fix forward may already be in', comment)

    def test_a_revert_that_fails_to_apply_is_said_on_the_culprit_issue(self):
        hooks = self.safe_revert_hooks([])
        hooks['open_revert'] = lambda *a: (None, '', '`git revert -m 1` does not apply cleanly on the newest main (f)')
        calls, _ = self.run_command(lambda sha: B.FAIL, revert_hooks=hooks, env={B.REVERT_TOKEN_ENV: 'app-token'},
                                    then_revert=True)
        comments = {c[0][2]: c[1] for c in calls if c[0][:2] == ('issue', 'comment')}
        self.assertIn('does not apply cleanly', comments['9'])
        self.assertNotIn('Revert opened', comments['5'])

    def test_a_culprit_file_changed_on_main_since_the_red_run_is_not_reverted(self):
        opened = []
        hooks = self.safe_revert_hooks(opened)
        hooks['changed_on_main_since'] = lambda red: ['App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift']
        calls, _ = self.run_command(lambda sha: B.FAIL, revert_hooks=hooks, env={B.REVERT_TOKEN_ENV: 'app-token'})
        self.assertEqual(opened, [])
        body = [c for c in calls if c[0][:2] == ('issue', 'create')][0][1]
        self.assertIn('fix forward may already be in', body)

    def test_a_crash_in_the_safety_check_still_files_the_culprit_issue(self):
        opened = []
        hooks = self.safe_revert_hooks(opened)

        def broken(sha):
            raise AttributeError("module 'test_scope' has no attribute 'build_scripts'")
        hooks['changed_paths'] = broken
        calls, _ = self.run_command(lambda sha: B.FAIL, revert_hooks=hooks, env={B.REVERT_TOKEN_ENV: 'app-token'})
        self.assertEqual(opened, [])
        body = [c for c in calls if c[0][:2] == ('issue', 'create')][0][1]
        self.assertIn('could not check whether the revert is safe', body)

    def test_two_breaks_are_never_reverted(self):
        foo, bar = 'SpokenMarginsAppTests/Foo/testA', 'SpokenMarginsAppTests/Bar/testB'
        opened = []
        calls, record = self.run_command(lambda sha: B.FAIL, red_failed=[foo, bar],
                                         probe_failed={shas(4)[0]: {foo}},
                                         revert_hooks=self.safe_revert_hooks(opened),
                                         env={B.REVERT_TOKEN_ENV: 'app-token'})
        self.assertEqual(opened, [])
        body = [c for c in calls if c[0][:2] == ('issue', 'create')][0][1]
        self.assertIn('this merge did not cause', body)

    def test_a_culprit_whose_issue_is_already_open_is_not_reverted_again(self):
        """A re-run on the same red commit finds the culprit issue open: no second issue, no second revert."""
        opened = []
        culprit = shas(4)[0]
        existing = {'number': 9, 'body': B.CULPRIT_MARKER % culprit, 'user': {'login': 'github-actions[bot]'}}
        calls, record = self.run_command(lambda sha: B.FAIL, open_extra=[existing],
                                         revert_hooks=self.safe_revert_hooks(opened),
                                         env={B.REVERT_TOKEN_ENV: 'app-token'})
        self.assertEqual(record['culprit'], culprit)
        self.assertEqual(opened, [])
        self.assertEqual([c for c in calls if c[0][:2] == ('issue', 'create')], [])

    def test_a_culprit_opens_one_ready_regression_issue_with_the_prs_area_and_comments_on_the_failure_issue(self):
        calls, record = self.run_command(lambda sha: B.FAIL)
        creates = [c for c in calls if c[0][:2] == ('issue', 'create')]
        self.assertEqual(len(creates), 1)
        args, body = creates[0]
        labels = [args[i + 1] for i, a in enumerate(args) if a == '--label']
        self.assertEqual(sorted(labels), ['area: hear it well', 'ready', 'regression'])
        self.assertIn('PR #100', body)
        self.assertEqual(record['kind'], 'culprit')
        self.assertEqual(record['classes'], {'app': ['SpokenMarginsAppTests/Foo']})
        comments = [c for c in calls if c[0][:2] == ('issue', 'comment')]
        self.assertEqual([c[0][2] for c in comments], ['5'])
        self.assertIn('https://github.com/o/r/issues/9', comments[0][1])

    def test_two_separate_breaks_name_only_the_tests_the_culprit_failed(self):
        """m1 broke Foo and a later merge broke Bar: the bisection stops at m1, so the issue may not blame m1 for Bar."""
        foo, bar = 'SpokenMarginsAppTests/Foo/testA', 'SpokenMarginsAppTests/Bar/testB'
        probe = lambda sha: B.FAIL  # noqa: E731
        culprit = shas(4)[0]
        calls, _ = self.run_command(probe, red_failed=[foo, bar], probe_failed={culprit: {foo}})
        args, body = [c for c in calls if c[0][:2] == ('issue', 'create')][0]
        title = args[args.index('--title') + 1]
        self.assertEqual(title, 'Main T3 red: #100 broke Foo/testA')
        failing = [line for line in body.splitlines() if line.startswith('- Failing tests')][0]
        self.assertIn('`Foo/testA`', failing)
        self.assertNotIn('Bar/testB', failing)
        other = [line for line in body.splitlines() if line.startswith('- Also failing')][0]
        self.assertIn('`Bar/testB`', other)
        note = [c for c in calls if c[0][:2] == ('issue', 'comment')][0][1]
        self.assertIn('1 other failing test', note)

    def test_a_culprit_with_a_closed_culprit_issue_is_undecided_not_blamed_again(self):
        """The same merge cannot break the suite twice: its issue was closed, so this red run is another break."""
        culprit = shas(4)[0]
        closed = [{'number': 77, 'body': B.CULPRIT_MARKER % culprit, 'user': {'login': 'github-actions[bot]'}}]
        calls, record = self.run_command(lambda sha: B.FAIL, closed=closed)
        self.assertEqual(record['kind'], 'undecided')
        self.assertIn('#77', record['reason'])
        self.assertEqual([c for c in calls if c[0][:2] == ('issue', 'create')], [])
        comments = [c for c in calls if c[0][:2] == ('issue', 'comment')]
        self.assertIn('names no PR', comments[0][1])

    def test_a_closed_issue_for_another_commit_or_from_a_stranger_does_not_block_the_culprit(self):
        culprit = shas(4)[0]
        closed = [{'number': 77, 'body': B.CULPRIT_MARKER % ('c' * 40), 'user': {'login': 'github-actions[bot]'}},
                  {'number': 78, 'body': B.CULPRIT_MARKER % culprit, 'user': {'login': 'stranger'}}]
        _, record = self.run_command(lambda sha: B.FAIL, closed=closed)
        self.assertEqual(record['kind'], 'culprit')

    def test_it_refuses_to_run_over_uncommitted_changes_to_tracked_files(self):
        import argparse
        import os
        calls = []
        patches = [(B, 'git', lambda *a, **k: calls.append(a) or ' M App/Foo.swift\n'), (os, 'chdir', lambda p: None)]
        saved = [(o, n, getattr(o, n)) for o, n, _ in patches]
        for o, n, v in patches:
            setattr(o, n, v)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                args = argparse.Namespace(sha=RED, run_url='https://run', run_id='1', evidence=tmp, budget=10)
                self.assertEqual(B.command_bisect(args), 2)
        finally:
            for o, n, v in saved:
                setattr(o, n, v)
        self.assertEqual(calls, [('status', '--porcelain', '--untracked-files=no')])  # nothing was checked out

    def test_an_undecided_run_opens_no_issue_and_names_no_pr_on_the_failure_issue(self):
        calls, record = self.run_command(lambda sha: B.UNDECIDED)
        self.assertEqual([c for c in calls if c[0][:2] == ('issue', 'create')], [])
        comments = [c for c in calls if c[0][:2] == ('issue', 'comment')]
        self.assertEqual(len(comments), 1)
        self.assertIn('names no PR', comments[0][1])
        self.assertEqual(record['kind'], 'undecided')

    def test_a_failed_git_log_is_an_undecided_note_not_a_crash(self):
        calls, record = self.run_command(lambda sha: B.FAIL, git_fails=True)
        self.assertEqual(record['kind'], 'undecided')
        self.assertIn('could not be listed', record['reason'])
        self.assertEqual([c for c in calls if c[0][:2] == ('issue', 'create')], [])

    def test_the_two_issue_kinds_are_never_mistaken_for_each_other(self):
        failure = {'number': 1, 'body': B.t3.MARKER, 'user': {'login': 'github-actions[bot]'}}
        culprit = {'number': 2, 'body': B.CULPRIT_MARKER % ('a' * 40), 'user': {'login': 'github-actions[bot]'}}
        self.assertEqual(B.t3.find_open_issue([failure, culprit])['number'], 1)
        self.assertIsNone(B.t3.find_open_issue([culprit]))
        self.assertIsNone(B.find_open_culprit_issue([failure], 'a' * 40))


class CredentialTests(unittest.TestCase):
    """A probe's LFS pull carries the job token; it must reach neither argv, an error, nor an unmasked log line."""
    TOKEN = 'ghs_exampletoken123'

    def test_check_out_hands_the_token_to_git_by_environment_and_masks_it(self):
        import contextlib
        import io
        import os
        calls = []
        auth, _ = B.lfs_credential(self.TOKEN)
        original, os_token = B.git, os.environ.get('GH_TOKEN')
        B.git = lambda *args, env=None: calls.append((args, env)) or ''
        os.environ['GH_TOKEN'] = self.TOKEN
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                B.check_out('a' * 40, RED)
        finally:
            B.git = original
            if os_token is None:
                os.environ.pop('GH_TOKEN')
            else:
                os.environ['GH_TOKEN'] = os_token
        lfs = [c for c in calls if c[0][:2] == ('lfs', 'pull')]
        self.assertEqual(len(lfs), 1)
        args, env = lfs[0]
        self.assertFalse(any(auth in a or self.TOKEN in a for a in args), args)
        self.assertEqual(env['GIT_CONFIG_KEY_0'], 'http.https://github.com/.extraheader')
        self.assertEqual(env['GIT_CONFIG_VALUE_0'], f'AUTHORIZATION: basic {auth}')
        self.assertIn(f'::add-mask::{auth}', out.getvalue())

    def test_a_failed_git_command_never_prints_a_value_given_after_dash_c(self):
        with self.assertRaises(RuntimeError) as caught:
            B.git('-c', 'http.extraheader=AUTHORIZATION: basic SECRETVALUE', 'no-such-subcommand')
        self.assertNotIn('SECRETVALUE', str(caught.exception))
        self.assertNotIn('AUTHORIZATION', str(caught.exception))
        self.assertEqual(B.describe(('-c', 'k=v', 'lfs', 'pull', 'x')), 'lfs pull x')
        self.assertEqual(B.describe(('log', '--first-parent')), 'log --first-parent')

    def test_the_environment_credential_reaches_git_but_not_the_error_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            original = B.ROOT
            B.ROOT = Path(tmp)
            try:
                subprocess.run(['git', 'init', '-q', tmp], check=True)
                auth, env = B.lfs_credential(self.TOKEN)
                # `git config` reads the injected key, so the environment really is passed down.
                self.assertEqual(B.git('config', '--get', 'http.https://github.com/.extraheader', env=env).strip(),
                                 f'AUTHORIZATION: basic {auth}')
                with self.assertRaises(RuntimeError) as caught:
                    B.git('bogus-subcommand', env=env)
                self.assertNotIn(auth, str(caught.exception))
            finally:
                B.ROOT = original


class RevertRefusalTests(unittest.TestCase):
    """The hosted revert refuses what the Mac's integration run refuses (integration_revert.revert_blockers), plus two
    breaks in one red run and a missing revert token."""
    APP = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift'

    def refusals(self, paths, subject='Merge pull request #100 from x/y', body='Fix the thing', parents=2,
                 open_reverts=(), already=None, unexplained=(), token='app-token'):
        commit = {'sha': 'c' * 40, 'parents': ['p' * 40] * parents, 'subject': subject, 'body': body}
        return B.revert_refusals(commit, list(paths), B.revert.load_test_scope(B.ROOT), list(open_reverts), already,
                                 list(unexplained), token)

    def test_a_merged_pr_that_changed_app_code_is_safe_to_revert(self):
        self.assertEqual(self.refusals([self.APP]), [])
        self.assertEqual(self.refusals([self.APP, 'App/SpokenMarginsAppTests/FooTests.swift', 'docs/x.md']), [])

    def test_each_refusal_row(self):
        rows = {
            'persistence': dict(paths=['Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift']),
            'a packet format': dict(paths=['Packages/SessionKit/Sources/SessionKitSharing/PacketWriter.swift']),
            'the lane': dict(paths=[self.APP, '.github/workflows/main-t3.yml']),
            'the lane ': dict(paths=[self.APP, 'scripts/lane-runner.py']),
            'a migration': dict(paths=['App/SpokenMarginsApp/Sources/SpokenMarginsApp/StoreMigration.swift']),
            'only docs': dict(paths=['docs/journeys.md', 'scripts/main_t3.py']),
            'not a merged pull request': dict(paths=[self.APP], parents=1, subject='Fix the thing'),
            'itself a revert': dict(paths=[self.APP], body='Revert #90: something'),
            'already reverts it': dict(paths=[self.APP], already='d' * 40),
            'another revert PR is open': dict(paths=[self.APP], open_reverts=['#55']),
            'did not cause': dict(paths=[self.APP], unexplained=['SpokenMarginsAppTests/Bar/testB']),
            B.REVERT_TOKEN_ENV: dict(paths=[self.APP], token=None),
        }
        for words, row in rows.items():
            with self.subTest(words.strip()):
                reasons = self.refusals(**row)
                self.assertTrue(any(words.strip() in r for r in reasons), reasons)


class OpenRevertTests(unittest.TestCase):
    """open_revert on a real temporary repository with a bare origin; gh replaced by a recorder."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.origin, self.work = base / 'origin.git', base / 'work'
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(self.origin)], check=True)
        subprocess.run(['git', 'clone', '-q', str(self.origin), str(self.work)], check=True, capture_output=True)
        self.git('checkout', '-q', '-b', 'main')
        self.app = self.work / 'App' / 'a.swift'
        self.app.parent.mkdir(parents=True)
        self.app.write_text('let a = 1\n')
        self.git('add', '.')
        self.git('commit', '-q', '-m', 'green')
        self.git('checkout', '-q', '-b', 'topic')
        self.app.write_text('let a = 2\n')
        self.git('commit', '-q', '-am', 'break it')
        self.git('checkout', '-q', 'main')
        self.git('merge', '-q', '--no-ff', '-m', 'Merge pull request #100 from x/topic\n\nBreak the thing', 'topic')
        self.culprit = self.git('rev-parse', 'HEAD')
        self.git('push', '-q', 'origin', 'main')
        self.saved = (B.ROOT, B.gh_as, B.t3.repo)
        B.ROOT = self.work
        self.calls = []

        def gh_as(token, *args, stdin=None):
            self.calls.append((token, args, stdin))
            if args[:2] == ('pr', 'create'):
                return 'https://github.com/o/r/pull/77\n'
            if args[:2] == ('issue', 'create'):
                return 'https://github.com/o/r/issues/78\n'
            return ''

        B.gh_as = gh_as
        B.t3.repo = lambda: 'o/r'

    def tearDown(self):
        B.ROOT, B.gh_as, B.t3.repo = self.saved
        self.tmp.cleanup()

    def git(self, *args, cwd=None):
        return subprocess.run(['git', '-C', str(cwd or self.work), '-c', 'user.name=t', '-c', 'user.email=t@example.com',
                               *args], check=True, capture_output=True, text=True).stdout.strip()

    def run_revert(self):
        B.fetch_main()
        commit = B.culprit_commit(self.culprit)
        return commit, B.open_revert(commit, self.culprit, 'https://run', ['SpokenMarginsAppTests/Foo/testA'],
                                     [(self.culprit, B.FAIL)], 9, 'app-token', 'area: hear it well')

    def test_the_merge_is_reverted_on_main_pushed_and_opened_with_automerge_and_a_reland_issue(self):
        commit, (pr_url, reland, why) = self.run_revert()
        self.assertEqual((pr_url, reland, why), ('https://github.com/o/r/pull/77', 'https://github.com/o/r/issues/78', ''))
        self.assertEqual(commit['parents'][1:] != [], True)
        self.assertEqual(B.revert.pr_title(commit['subject'], commit['body']), 'Break the thing')
        pushed = self.git('log', '-1', '--format=%B', 'refs/heads/revert/pr100', cwd=self.origin)
        self.assertIn(f'This reverts commit {self.culprit}.', pushed)
        self.assertEqual(self.git('show', 'refs/heads/revert/pr100:App/a.swift', cwd=self.origin), 'let a = 1')
        self.assertEqual({token for token, _, _ in self.calls}, {'app-token'})
        create = next(c for c in self.calls if c[1][:2] == ('pr', 'create'))
        self.assertIn('automerge', create[1][create[1].index('--label') + 1])
        self.assertIn('Part of #9', create[2])
        issue = next(c for c in self.calls if c[1][:2] == ('issue', 'create'))
        labels = [issue[1][i + 1] for i, a in enumerate(issue[1]) if a == '--label']
        self.assertEqual(sorted(labels), ['area: hear it well', 'ready', 'regression'])
        self.assertIn('https://github.com/o/r/pull/77', issue[2])
        edit = next(c for c in self.calls if c[1][:2] == ('pr', 'edit'))
        self.assertIn('Re-land: https://github.com/o/r/issues/78', edit[2])
        # The checkout is back on the red commit and the local branch is gone.
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.culprit)
        self.assertEqual(self.git('branch', '--list', 'revert/pr100'), '')

    def test_a_revert_that_conflicts_with_newer_main_pushes_nothing(self):
        other = Path(self.tmp.name) / 'other'
        subprocess.run(['git', 'clone', '-q', str(self.origin), str(other)], check=True, capture_output=True)
        (other / 'App' / 'a.swift').write_text('let a = 3\n')
        self.git('commit', '-q', '-am', 'newer main edits the same line', cwd=other)
        self.git('push', '-q', 'origin', 'main', cwd=other)
        _, (pr_url, _, why) = self.run_revert()
        self.assertIsNone(pr_url)
        self.assertIn('does not apply cleanly', why)
        self.assertIn('App/a.swift', why)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.git('branch', '--list', 'revert/pr100', cwd=self.origin), '')
        self.assertEqual(self.git('status', '--porcelain', '--untracked-files=no'), '')

    def test_a_failed_pr_create_takes_the_pushed_branch_back_down(self):
        def failing(token, *args, stdin=None):
            self.calls.append((token, args, stdin))
            raise RuntimeError('gh pr create: HTTP 422')
        B.gh_as = failing
        _, (pr_url, _, why) = self.run_revert()
        self.assertIsNone(pr_url)
        self.assertIn('422', why)
        self.assertEqual(self.git('branch', '--list', 'revert/pr100', cwd=self.origin), '')

    def test_a_merge_main_already_undid_is_not_reverted_twice(self):
        self.git('revert', '--no-edit', '-m', '1', self.culprit)
        self.git('push', '-q', 'origin', 'main')
        B.fetch_main()
        self.assertTrue(B.reverted_on_main(self.culprit))


class GitRangeTests(unittest.TestCase):
    def test_first_parent_commits_oldest_first_with_subjects(self):
        with tempfile.TemporaryDirectory() as tmp:
            def git(*args):
                return subprocess.run(['git', '-C', tmp, '-c', 'user.name=t', '-c', 'user.email=t@example.com',
                                       *args], check=True, capture_output=True, text=True).stdout.strip()

            git('init', '-q', '-b', 'main')
            (Path(tmp) / 'f').write_text('0')
            git('add', 'f')
            git('commit', '-q', '-m', 'green')
            green = git('rev-parse', 'HEAD')
            for i in (1, 2):
                git('checkout', '-q', '-b', f'topic{i}')
                (Path(tmp) / 'f').write_text(str(i))
                git('commit', '-q', '-am', f'work {i}')
                git('commit', '-q', '--allow-empty', '-m', f'more work {i}')  # a side commit, not first-parent
                git('checkout', '-q', 'main')
                git('merge', '-q', '--no-ff', '-m', f'Merge pull request #{i}00 from x/topic{i}', f'topic{i}')
            red = git('rev-parse', 'HEAD')
            original = B.ROOT
            B.ROOT = Path(tmp)
            try:
                found = B.merges_in_range(green, red)
            finally:
                B.ROOT = original
        self.assertEqual([subject for _, subject in found],
                         ['Merge pull request #100 from x/topic1', 'Merge pull request #200 from x/topic2'])
        self.assertEqual(found[-1][0], red)
        self.assertEqual([B.pr_number(s) for _, s in found], [100, 200])


if __name__ == '__main__':
    unittest.main()
