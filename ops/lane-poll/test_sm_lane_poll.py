"""Host tests for the lane poll (#1057). Run: python3 -m unittest discover -s ops/lane-poll -t ops/lane-poll"""
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import sm_lane_poll as P  # noqa: E402

REPO = P.REPO
ROOT = Path(__file__).resolve().parents[2]
SHARING = 'Packages/SessionKit/Sources/SessionKitSharing/Packet.swift'
COMPAT = [P.glob_regex(pattern) for pattern in (
    'Packages/SessionKit/Sources/SessionKitSharing/**', 'Packages/SessionKit/Sources/SessionKit/*Models*.swift',
    'Packages/SessionKit/Tests/*/Build29DatabaseFixtureTests.swift', '.github/workflows/shipped-build-compat.yml')]


def pr(number, head, labels=(), repo=REPO, base='next'):
    return {'number': number, 'head': {'sha': head, 'repo': {'full_name': repo}}, 'base': {'ref': base},
            'labels': [{'name': name} for name in labels]}


def event(id, kind, number, label=None, is_pr=True):
    found = {'id': id, 'event': kind, 'issue': {'number': number}}
    if is_pr:
        found['issue']['pull_request'] = {}
    if label:
        found['label'] = {'name': label}
    return found


def state(**changes):
    base = P.empty_state()
    base.update(baselined=True, **changes)
    return base


def decide(prs, events=(), next_sha='n1', current=None, files=(), compat=None):
    asked = []

    def files_for(number):
        asked.append(number)
        return list(files)

    jobs, new = P.decide(prs, list(events), next_sha, current or state(next_sha='n1'), files_for,
                         COMPAT if compat is None else compat)
    return jobs, new, asked


def kinds(jobs):
    return [(job['kind'], job['pr'], job['reasons']) for job in jobs]


class FakeApi:
    """Answers reads from a table. It has no write method, so a run that passes never wrote."""

    def __init__(self, prs=(), events=(), next_sha='n1', files=None, runs=None, fail=None):
        self.prs, self.events, self.next_sha = list(prs), list(events), next_sha
        self.files, self.runs, self.fail, self.calls = files or {}, runs or {}, fail, []

    def get(self, path):
        self.calls.append(path)
        if self.fail and self.fail in path:
            raise OSError('boom')
        if '/pulls?' in path:
            return self.prs
        if '/issues/events' in path:
            return self.events
        if '/branches/' in path:
            return {'commit': {'sha': self.next_sha}}
        if '/files?' in path:
            number = int(re.search(r'/pulls/(\d+)/files', path).group(1))
            page = int(re.search(r'[?&]page=(\d+)', path).group(1))
            return self.files.get(number, {}).get(page, [])
        if '/actions/runs' in path:
            head = re.search(r'head_sha=(\w+)', path).group(1)
            return {'workflow_runs': self.runs.get(head, [])}
        raise AssertionError(f'unexpected read: {path}')


class GlobTests(unittest.TestCase):
    def test_neighbouring_inputs(self):
        sharing = 'Packages/SessionKit/Sources/SessionKitSharing/**'
        build29 = 'Packages/SessionKit/Tests/*/Build29DatabaseFixtureTests.swift'
        table = [
            (sharing, 'Packages/SessionKit/Sources/SessionKitSharing/Packet.swift', True),
            (sharing, 'Packages/SessionKit/Sources/SessionKitSharing/a/b/c.swift', True),
            (sharing, 'Packages/SessionKit/Sources/SessionKitSharing/My File.swift', True),
            (sharing, 'Packages/SessionKit/Sources/SessionKitSharingExtras/Packet.swift', False),  # lookalike folder
            (sharing, 'Packages/SessionKit/Sources/SessionKitSharing', False),  # the folder itself is no file
            (sharing, 'packages/sessionkit/sources/sessionkitsharing/Packet.swift', False),  # case matters
            (build29, 'Packages/SessionKit/Tests/SharingTests/Build29DatabaseFixtureTests.swift', True),
            (build29, 'Packages/SessionKit/Tests/A/B/Build29DatabaseFixtureTests.swift', False),  # * stays in a folder
            (build29, 'Packages/SessionKit/Tests/Build29DatabaseFixtureTests.swift', False),
            ('.github/workflows/shipped-build-compat.yml', '.github/workflows/shipped-build-compat.yml', True),
            ('.github/workflows/shipped-build-compat.yml', '.github/workflows/shipped-build-compatXyml', False),  # dot is literal
            ('scripts/build29-db-reader/**', 'scripts/build29-db-reader-old/x.swift', False),
            ('**/x.md', 'x.md', True),
            ('**/x.md', 'a/b/x.md', True),
            ('a?c', 'abc', True),
            ('a?c', 'a/c', False),
        ]
        for pattern, path, expected in table:
            with self.subTest(pattern=pattern, path=path):
                self.assertEqual(bool(P.glob_regex(pattern).match(path)), expected)

    def test_touches_compat(self):
        self.assertTrue(P.touches_compat(['README.md', SHARING], COMPAT))
        self.assertTrue(P.touches_compat(['Packages/SessionKit/Sources/SessionKit/MarginModels.swift'], COMPAT))  # * inside a name
        self.assertFalse(P.touches_compat(['Packages/SessionKit/Sources/SessionKit/Models/Deep.swift'], COMPAT))
        self.assertFalse(P.touches_compat(['README.md', 'App/SpokenMarginsApp/Gate1AppModel.swift'], COMPAT))
        self.assertFalse(P.touches_compat([], COMPAT))
        self.assertFalse(P.touches_compat([SHARING], []))  # no filter loaded: nothing matches

    def test_workflow_paths_reads_the_list_and_stops_at_the_next_key(self):
        text = ("on:\n  pull_request:\n    branches: [next]\n    paths-ignore:\n      - 'docs/**'\n    paths:\n"
                "      - 'a/**'\n      # a note between entries\n\n      - \"b/*.swift\"\n      - c/plain.sh  # trailing\n"
                "\npermissions:\n  contents: read\n  - 'not/a/path'\n")
        self.assertEqual(P.workflow_paths(text), ['a/**', 'b/*.swift', 'c/plain.sh'])
        self.assertEqual(P.workflow_paths('on:\n  push:\n    branches: [next]\n'), [])

    def test_a_negated_filter_is_refused_not_guessed(self):
        with self.assertRaises(ValueError):
            P.workflow_paths("paths:\n  - 'a/**'\n  - '!a/skip/**'\n")

    def test_a_missing_workflow_file_means_no_compat_jobs(self):
        self.assertEqual(P.load_compat_patterns(Path('/nonexistent/shipped-build-compat.yml')), [])


class DecideTests(unittest.TestCase):
    def test_push_to_an_armed_pr_starts_its_job(self):
        jobs, new, _ = decide([pr(7, 'new', ['automerge'])], current=state(next_sha='n1', dispatched={'7:automerge': 'old'}))
        self.assertEqual(kinds(jobs), [('automerge', 7, ['push'])])
        self.assertEqual(new['dispatched']['7:automerge'], 'new')

    def test_same_head_and_no_event_starts_nothing(self):
        jobs, _, _ = decide([pr(7, 'h', ['automerge'])], current=state(next_sha='n1', dispatched={'7:automerge': 'h'},
                                                                         compat={'7': 'h'}))
        self.assertEqual(jobs, [])

    def test_a_pr_without_the_label_starts_nothing(self):
        jobs, new, _ = decide([pr(7, 'new', ['lane:done'])], current=state(next_sha='n1', dispatched={'7:automerge': 'old'}))
        self.assertEqual(jobs, [])
        self.assertEqual(new['dispatched'], {})  # the stale entry goes with the label

    def test_the_label_added_again_on_the_same_head_starts_one_job(self):
        # Remove and re-add automerge is how the dispatcher retries a PR; the head does not change.
        before = state(next_sha='n1', event_cursor=10, dispatched={'7:automerge': 'h'}, compat={'7': 'h'})
        jobs, after, _ = decide([pr(7, 'h', ['automerge'])], [event(11, 'labeled', 7, 'automerge')], current=before)
        self.assertEqual(kinds(jobs), [('automerge', 7, ['labeled'])])
        self.assertEqual(after['event_cursor'], 11)
        again, _, _ = decide([pr(7, 'h', ['automerge'])], [event(11, 'labeled', 7, 'automerge')], current=after)
        self.assertEqual(again, [])

    def test_other_labels_do_not_start_a_job(self):
        before = state(next_sha='n1', event_cursor=10, dispatched={'7:automerge': 'h'}, compat={'7': 'h'})
        jobs, _, _ = decide([pr(7, 'h', ['automerge', 'lane:done'])], [event(11, 'labeled', 7, 'lane:done')], current=before)
        self.assertEqual(jobs, [])

    def test_a_label_event_starts_only_its_own_kind(self):
        before = state(next_sha='n1', event_cursor=10, dispatched={'7:automerge': 'h', '7:lane': 'h'}, compat={'7': 'h'})
        jobs, _, _ = decide([pr(7, 'h', ['automerge', 'lane:queued'])], [event(11, 'labeled', 7, 'lane:queued')], current=before)
        self.assertEqual(kinds(jobs), [('lane', 7, ['labeled'])])

    def test_events_already_seen_or_on_issues_or_other_prs_are_ignored(self):
        before = state(next_sha='n1', event_cursor=10, dispatched={'7:automerge': 'h'}, compat={'7': 'h'})
        events = [event(10, 'labeled', 7, 'automerge'),                       # at the cursor: seen
                  event(12, 'labeled', 7, 'automerge', is_pr=False),          # an issue that shares the number space
                  event(13, 'labeled', 8, 'automerge')]                       # another PR
        jobs, _, _ = decide([pr(7, 'h', ['automerge'])], events, current=before)
        self.assertEqual(jobs, [])

    def test_reopening_an_armed_pr_starts_its_job(self):
        before = state(next_sha='n1', event_cursor=10, dispatched={'7:automerge': 'h'}, compat={'7': 'h'})
        jobs, _, _ = decide([pr(7, 'h', ['automerge'])], [event(11, 'reopened', 7)], current=before)
        self.assertEqual(kinds(jobs), [('automerge', 7, ['reopened'])])

    def test_both_labels_on_a_new_head_start_two_jobs(self):
        jobs, _, _ = decide([pr(7, 'new', ['automerge', 'lane:queued'])],
                            current=state(next_sha='n1', dispatched={'7:automerge': 'old', '7:lane': 'old'}))
        self.assertEqual(sorted(kind for kind, _, _ in kinds(jobs)), ['automerge', 'lane'])

    def test_a_label_with_no_earlier_record_is_first_seen(self):
        jobs, _, _ = decide([pr(7, 'h', ['automerge'])], current=state(next_sha='n1', compat={'7': 'h'}))
        self.assertEqual(kinds(jobs), [('automerge', 7, ['first-seen'])])

    def test_fork_and_other_base_prs_are_skipped(self):
        prs = [pr(7, 'h', ['automerge'], repo='someone/else'), pr(8, 'h', ['automerge'], base='main')]
        jobs, new, asked = decide(prs, current=state(next_sha='n1'))
        self.assertEqual(jobs, [])
        self.assertEqual((new['dispatched'], asked), ({}, []))

    def test_a_pr_with_no_head_repo_is_skipped(self):
        broken = pr(7, 'h', ['automerge'])
        broken['head']['repo'] = None  # GitHub sends null when the fork was deleted
        jobs, _, _ = decide([broken], current=state(next_sha='n1'))
        self.assertEqual(jobs, [])

    def test_compat_runs_once_per_head_and_only_for_matching_paths(self):
        prs = [pr(7, 'h1')]
        jobs, after, asked = decide(prs, current=state(next_sha='n1'), files=[SHARING])
        self.assertEqual(kinds(jobs), [('compat', 7, ['push'])])
        again, _, asked_again = decide(prs, current=after, files=[SHARING])
        self.assertEqual((again, asked, asked_again), ([], [7], []))  # the second poll asks GitHub nothing
        quiet, quiet_state, asked_quiet = decide([pr(8, 'h2')], current=state(next_sha='n1'), files=['docs/x.md'])
        self.assertEqual((quiet, asked_quiet, quiet_state['compat']), ([], [8], {'8': 'h2'}))

    def test_next_moving_starts_a_merge_audit(self):
        jobs, new, _ = decide([], next_sha='n2', current=state(next_sha='n1'))
        self.assertEqual(jobs, [{'kind': 'merge-audit', 'pr': None, 'head': 'n2', 'reasons': ['next-moved'], 'before': 'n1'}])
        self.assertEqual(new['next_sha'], 'n2')
        self.assertEqual(decide([], next_sha='n2', current=new)[0], [])

    def test_closed_prs_are_forgotten(self):
        before = state(next_sha='n1', dispatched={'7:automerge': 'h', '9:lane': 'h'}, compat={'7': 'h', '9': 'h'})
        _, new, _ = decide([pr(7, 'h', ['automerge'])], current=before)
        self.assertEqual((set(new['dispatched']), set(new['compat'])), ({'7:automerge'}, {'7'}))


class RunOnceTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.state = Path(self.folder.name) / 'sub' / 'state.json'

    def run_once(self, api, **options):
        return P.run_once(api, self.state, REPO, **options)

    def test_the_first_run_records_a_baseline_and_starts_nothing(self):
        api = FakeApi(prs=[pr(7, 'h', ['automerge'])], events=[event(5, 'labeled', 7, 'automerge')], next_sha='n1abcdef')
        lines = self.run_once(api)
        self.assertEqual(len(lines), 1)
        self.assertEqual({k: v for k, v in lines[0]['baseline'].items() if k != 'compat_paths'},
                         {'open_prs': 1, 'armed_pairs': 1, 'event_cursor': 5, 'next': 'n1abcde'})
        self.assertEqual(json.loads(self.state.read_text())['dispatched'], {'7:automerge': 'h'})
        self.assertEqual(self.run_once(api), [])  # nothing changed since

    def test_a_push_after_the_baseline_is_reported_with_the_actions_run_for_that_head(self):
        self.run_once(FakeApi(prs=[pr(7, 'old', ['automerge'])]))
        runs = {'new': [{'id': 1, 'path': '.github/workflows/linux-t1.yml', 'status': 'completed', 'conclusion': 'success'},
                        {'id': 2, 'path': '.github/workflows/lane.yml', 'status': 'queued', 'conclusion': None},
                        {'id': 3, 'path': '.github/workflows/lane.yml', 'status': 'in_progress', 'conclusion': None}]}
        lines = self.run_once(FakeApi(prs=[pr(7, 'new', ['automerge'])], runs=runs))
        self.assertEqual([(line['would_start'], line['pr'], line['reasons']) for line in lines], [('automerge', 7, ['push'])])
        self.assertEqual(lines[0]['actions'], '2 run(s) on this head, newest 3 in_progress/-')

    def test_no_matching_actions_run_reads_none(self):
        self.run_once(FakeApi(prs=[pr(7, 'old', ['automerge'])]))
        runs = {'new': [{'id': 1, 'path': '.github/workflows/linux-t1.yml', 'status': 'completed', 'conclusion': 'success'}]}
        lines = self.run_once(FakeApi(prs=[pr(7, 'new', ['automerge'])], runs=runs))
        self.assertEqual(lines[0]['actions'], 'none')
        self.assertNotIn('actions', self.run_once(FakeApi(prs=[pr(7, 'newer', ['automerge'])]), compare=False)[0])

    def test_a_read_that_fails_leaves_the_state_as_it_was(self):
        self.run_once(FakeApi(prs=[pr(7, 'old', ['automerge'])]))
        before = self.state.read_text()
        with self.assertRaises(OSError):
            self.run_once(FakeApi(prs=[pr(7, 'new', ['automerge'])], fail='/issues/events'))
        self.assertEqual(self.state.read_text(), before)

    def test_main_reports_an_unreadable_github_with_exit_code_2(self):
        class Broken:
            def get(self, path):
                raise OSError('offline')
        with mock.patch.object(P, 'GhApi', Broken), mock.patch('sys.stderr'):
            self.assertEqual(P.main(['--state', str(self.state)]), 2)
        self.assertFalse(self.state.exists())

    def test_an_event_gap_is_a_warning(self):
        self.run_once(FakeApi(prs=[pr(7, 'h', ['automerge'])], events=[event(5, 'labeled', 7, 'automerge')]))
        lines = self.run_once(FakeApi(prs=[pr(7, 'h', ['automerge'])], events=[event(900, 'closed', 3)]))
        self.assertIn('event feed gap', lines[0]['warning'])

    def test_reset_starts_a_new_baseline(self):
        self.run_once(FakeApi(prs=[pr(7, 'old', ['automerge'])]))
        with mock.patch.object(P, 'GhApi', lambda: FakeApi(prs=[pr(7, 'new', ['automerge'])])), \
                mock.patch('builtins.print') as printed:
            self.assertEqual(P.main(['--state', str(self.state), '--reset']), 0)
        self.assertIn('baseline', printed.call_args_list[0][0][0])

    def test_changed_paths_reads_every_page_and_both_sides_of_a_rename(self):
        first = [{'filename': f'f{i}.txt'} for i in range(100)]
        second = [{'filename': 'new.swift', 'previous_filename': SHARING}]
        paths = P.changed_paths(FakeApi(files={7: {1: first, 2: second}}), REPO, 7)
        self.assertEqual(len(paths), 102)
        self.assertTrue(P.touches_compat(paths, COMPAT))  # a rename out of a watched folder still counts

    def test_the_api_class_can_only_read(self):
        public = {name for name in dir(P.GhApi) if not name.startswith('_')}
        self.assertEqual(public, {'get'})


class WorkflowDriftTests(unittest.TestCase):
    """The poller copies decisions the workflows make. These fail when the workflows move on, so the
    shadow comparison is never run against a stale copy. The compat filter is read from the file itself.
    Delete these with the workflows at cutover."""

    def workflow(self, name):
        path = ROOT / '.github/workflows' / name
        if not path.exists():
            self.skipTest(f'{name} is gone (cutover)')
        return path.read_text()

    def test_the_poller_reads_the_real_compat_filter(self):
        text = self.workflow('shipped-build-compat.yml')
        listed = P.workflow_paths(text)
        self.assertIn('Packages/SessionKit/Sources/SessionKitSharing/**', listed)
        self.assertEqual(len(P.load_compat_patterns()), len(listed))
        self.assertTrue(P.touches_compat([SHARING], P.load_compat_patterns()))
        self.assertFalse(P.touches_compat(['docs/x.md', 'App/SpokenMarginsApp/Gate1AppModel.swift'], P.load_compat_patterns()))

    def test_lane_yml_still_starts_on_the_events_and_labels_the_poller_models(self):
        text = self.workflow('lane.yml')
        self.assertIn("branches: [next, 'lane-check/**']", text)
        self.assertIn('types: [labeled, synchronize, reopened]', text)
        for label in P.LABEL_FOR.values():
            self.assertIn(f"'{label}'", text)

    def test_merge_audit_still_starts_on_a_push_to_next(self):
        text = self.workflow('merge-audit.yml')
        self.assertRegex(text, r'push:\s+branches: \[next\]')


if __name__ == '__main__':
    unittest.main()
