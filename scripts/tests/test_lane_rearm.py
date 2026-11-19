import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('lane_rearm', ROOT / 'scripts/lane_rearm.py')
rearm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rearm)

HEAD = 'a' * 40
OTHER = 'b' * 40
REPO = 'Spoken-Margins/spoken-margins-native'


def pull(number, head=HEAD, base='main', repo=REPO, labels=('automerge',), state='open'):
    return {'number': number, 'state': state, 'head': {'sha': head, 'repo': {'full_name': repo}}, 'base': {'ref': base},
            'labels': [{'name': name} for name in labels]}


class FakeApi:
    repo = REPO

    def __init__(self, pulls, hosted_runs=1):
        self.pulls, self.hosted_runs, self.dispatched = pulls, hosted_runs, []

    def get(self, path):
        if path.startswith('commits/'):
            return [p for p in self.pulls if p['head']['sha'] == path.split('/')[1]]
        return {'total_count': self.hosted_runs if 'portable' in path else 0}

    def dispatch_lane(self, trunk, pr, head):
        self.dispatched.append((trunk, pr, head))


class RearmTests(unittest.TestCase):
    def go(self, api, conclusion='success'):
        return rearm.rearm(api, 'main', HEAD, conclusion, out=io.StringIO())[0]

    def test_a_finished_check_starts_the_merge_run_of_the_armed_pr_on_that_head(self):
        # The stranded-PR case: its automerge job left after 8 minutes with the check still running.
        api = FakeApi([pull(7)])
        self.assertEqual(self.go(api), [7])
        self.assertEqual(api.dispatched, [('main', 7, HEAD)])

    def test_a_failed_check_starts_it_too_so_the_pr_gets_its_fail_report(self):
        for conclusion in ('failure', 'timed_out'):
            api = FakeApi([pull(7)])
            self.assertEqual(self.go(api, conclusion), [7])

    def test_only_armed_open_same_repo_prs_into_the_trunk_on_that_head(self):
        api = FakeApi([pull(1), pull(2, head=OTHER), pull(3, base='release'), pull(4, repo='someone/fork'),
                       pull(5, labels=('lane:queued',)), pull(6, labels=()), pull(8, state='closed')])
        self.assertEqual(self.go(api), [1])

    def test_two_armed_prs_on_one_head_both_start(self):
        self.assertEqual(self.go(FakeApi([pull(1), pull(2)])), [1, 2])

    def test_a_skipped_run_or_no_conclusion_starts_nothing(self):
        for conclusion in ('skipped', '', 'neutral'):
            api = FakeApi([pull(1)])
            self.assertEqual(self.go(api, conclusion), [])
            self.assertEqual(api.dispatched, [])

    def test_the_head_s_hosted_runs_are_capped_whatever_they_ended_with(self):
        # The merge run's own 3-redispatch cap resets with every new job, so a check that never records its result
        # would otherwise loop: dispatch, 8 minutes, WAITING, check ends, dispatch.
        for conclusion in ('success', 'failure', 'cancelled'):
            self.assertEqual(self.go(FakeApi([pull(1)], hosted_runs=rearm.RUN_LIMIT - 1), conclusion), [1])
            api = FakeApi([pull(1)], hosted_runs=rearm.RUN_LIMIT)
            self.assertEqual(self.go(api, conclusion), [])
            self.assertEqual(api.dispatched, [])

    def test_a_failed_dispatch_is_reported_so_the_workflow_run_is_red(self):
        class Refused(FakeApi):
            def dispatch_lane(self, trunk, pr, head):
                raise OSError('HTTP 403')
        started, failed = rearm.rearm(Refused([pull(1), pull(2)]), 'main', HEAD, 'success', out=io.StringIO())
        self.assertEqual((started, failed), ([], [1, 2]))

    def test_the_prs_are_read_from_the_commit_not_a_first_page_of_open_prs(self):
        paths = []
        class Spy(FakeApi):
            def get(self, path):
                paths.append(path)
                return super().get(path)
        self.go(Spy([pull(1)]))
        self.assertTrue(any(p.startswith(f'commits/{HEAD}/pulls') for p in paths), paths)
        self.assertFalse(any(p.startswith('pulls?') for p in paths), paths)

    def test_a_failed_read_starts_nothing_and_does_not_fail_the_workflow(self):
        class Broken(FakeApi):
            def get(self, path):
                raise OSError('rate limited')
        with self.assertRaises(OSError):
            self.go(Broken([]))  # main() catches this; rearm() itself does not hide it


class WorkflowTests(unittest.TestCase):
    text = (ROOT / '.github/workflows/lane-rearm.yml').read_text()

    def test_it_runs_when_either_hosted_workflow_completes(self):
        self.assertRegex(self.text, r'workflows: \[hosted-portable, hosted-web\]')
        self.assertIn('types: [completed]', self.text)
        for name in ('hosted-portable', 'hosted-web'):
            workflow = (ROOT / f'.github/workflows/{name}.yml').read_text()
            self.assertRegex(workflow, rf'(?m)^name: {name}$')

    def test_it_takes_the_script_from_the_trunk_and_skips_fork_runs(self):
        self.assertIn("ref: ${{ vars.SM_TRUNK || 'main' }}", self.text)
        self.assertIn('head_repository.full_name == github.repository', self.text)
        self.assertNotIn('pull_request', self.text.split('\non:')[1].split('\npermissions:')[0])

    def test_the_head_reaches_the_shell_only_through_an_env_variable(self):
        run = self.text.split('run: |')[1]
        self.assertNotIn('${{', run)

    def test_the_merge_runs_it_starts_are_ones_lane_yml_already_takes(self):
        lane_yml = (ROOT / '.github/workflows/lane.yml').read_text()
        for field in ('pr', 'head', 'auto'):
            self.assertRegex(lane_yml, rf'(?m)^      {field}:$')
        script = (ROOT / 'scripts/lane_rearm.py').read_text()
        for field in ('inputs[pr]', 'inputs[head]', 'inputs[auto]=true'):
            self.assertIn(field, script)


if __name__ == '__main__':
    unittest.main()
