import importlib.util
import io
import re
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

    def __init__(self, pulls, hosted_runs=1, active_runs=0):
        self.pulls, self.hosted_runs, self.active_runs, self.dispatched = pulls, hosted_runs, active_runs, []

    def get(self, path):
        if path.startswith('commits/'):
            return [p for p in self.pulls if p['head']['sha'] == path.split('/')[1]]
        if 'status=' in path:
            return {'total_count': self.active_runs if 'portable' in path and 'status=in_progress' in path else 0}
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


class CapAndSupersededTests(unittest.TestCase):
    def test_the_calling_run_does_not_count_toward_the_cap(self):
        # The run that brings a head to RUN_LIMIT runs `rearm` while itself in progress, and GitHub counts it. If it is
        # the final green run, the PR must still start: it is the only thing that will.
        api = FakeApi([pull(4603)], hosted_runs=rearm.RUN_LIMIT)
        self.assertEqual(rearm.rearm(api, 'main', HEAD, 'success', out=io.StringIO(), own_runs=1)[0], [4603])
        api = FakeApi([pull(4603)], hosted_runs=rearm.RUN_LIMIT + 1)
        self.assertEqual(rearm.rearm(api, 'main', HEAD, 'success', out=io.StringIO(), own_runs=1)[0], [])

    def test_a_cancelled_run_starts_nothing_while_a_newer_one_on_the_head_is_active(self):
        api = FakeApi([pull(4603)], active_runs=2)  # itself and the run that replaced it
        self.assertEqual(rearm.rearm(api, 'main', HEAD, 'cancelled', out=io.StringIO(), own_runs=1)[0], [])
        self.assertEqual(api.dispatched, [])

    def test_a_cancelled_run_that_is_the_last_one_still_starts_the_merge_run(self):
        # stop-macs-on-red cancels the run itself: no other run is active, and the PR needs its FAIL report.
        api = FakeApi([pull(4603)], active_runs=1)
        self.assertEqual(rearm.rearm(api, 'main', HEAD, 'cancelled', out=io.StringIO(), own_runs=1)[0], [4603])

    def test_a_success_starts_the_merge_run_even_with_another_run_active(self):
        api = FakeApi([pull(4603)], active_runs=2)
        self.assertEqual(rearm.rearm(api, 'main', HEAD, 'success', out=io.StringIO(), own_runs=1)[0], [4603])

    def test_main_counts_the_calling_run_when_given_results(self):
        api = FakeApi([pull(4603)], hosted_runs=rearm.RUN_LIMIT)
        self.assertEqual(rearm.main(['--repo', REPO, '--head', HEAD, '--results', 'success'], api=api, out=io.StringIO()), 0)
        self.assertEqual(api.dispatched, [('main', 4603, HEAD)])


class LaneCheckTests(unittest.TestCase):
    def test_a_pr_into_a_lane_check_base_starts_on_that_base(self):
        # lane.yml's release job runs only on the trunk or a lane-check/** ref, and the lane change under test lives on
        # that base: the merge run must be dispatched there, not on the trunk.
        api = FakeApi([pull(7, base='lane-check/rearm'), pull(8, base='release/x'), pull(9)])
        self.assertEqual(sorted(rearm.rearm(api, 'main', HEAD, 'success', out=io.StringIO())[0]), [7, 9])
        self.assertEqual(sorted(api.dispatched), [('lane-check/rearm', 7, HEAD), ('main', 9, HEAD)])


class ConclusionTests(unittest.TestCase):
    def test_a_run_s_jobs_make_one_conclusion(self):
        for results, expected in (('success success skipped', 'success'), ('success failure skipped', 'failure'),
                                  ('success cancelled', 'cancelled'), ('failure cancelled', 'failure'),
                                  ('skipped skipped', 'skipped'), ('', 'skipped')):
            self.assertEqual(rearm.conclusion_of(results), expected, results)

    def test_a_bot_dispatched_run_that_finishes_leads_to_the_prs_merge_run(self):
        # The case of #4603: the lane dispatched hosted-portable (actor github-actions[bot]), every job passed or was
        # skipped, and nothing started the merge run again. The rearm job passes `needs.*.result`; the PR's run starts.
        api = FakeApi([pull(4603)])
        code = rearm.main(['--repo', REPO, '--head', HEAD, '--results', 'success success skipped success'],
                          api=api, out=io.StringIO())
        self.assertEqual((code, api.dispatched), (0, [('main', 4603, HEAD)]))

    def test_a_run_whose_jobs_all_skipped_starts_nothing(self):
        api = FakeApi([pull(4603)])
        self.assertEqual(rearm.main(['--repo', REPO, '--head', HEAD, '--results', 'skipped skipped'], api=api,
                                    out=io.StringIO()), 0)
        self.assertEqual(api.dispatched, [])


class WorkflowTests(unittest.TestCase):
    names = ('hosted-portable', 'hosted-web')

    def text(self, name):
        return (ROOT / f'.github/workflows/{name}.yml').read_text()

    def job_names(self, text):
        jobs = text.split('\njobs:\n')[1]
        return [m for m in re.findall(r'(?m)^  ([a-z][a-z-]*):$', jobs)]

    def rearm_block(self, text):
        return text.split('\n  rearm:\n')[1]

    def test_no_workflow_run_trigger_is_left_to_double_start_a_pr(self):
        # workflow_run does not fire for runs GITHUB_TOKEN caused, so it is not how the merge run starts; with the job
        # below it would also start each finished PR run twice.
        self.assertFalse((ROOT / '.github/workflows/lane-rearm.yml').exists())
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            text = re.sub(r'(?m)^\s*#.*$', '', path.read_text())
            if 'lane_rearm' in text:
                self.assertNotIn('workflow_run', text, path.name)

    def test_each_hosted_workflow_ends_with_one_rearm_job_after_every_other_job(self):
        for name in self.names:
            text = self.text(name)
            jobs = self.job_names(text)
            self.assertEqual(jobs[-1], 'rearm', name)
            self.assertEqual(jobs.count('rearm'), 1, name)
            block = self.rearm_block(text)
            needs = re.search(r'needs: \[([^\]]*)\]', block).group(1).replace(' ', '').split(',')
            self.assertEqual(sorted(needs), sorted(j for j in jobs if j != 'rearm'), name)
            # The outcome is read from the check jobs only: an `always()` job that is not one (owner-tap-alert,
            # linux-retry-tally) ends `success` even when every check skipped, which would start a pointless run.
            results = re.findall(r'needs\.([a-z-]+)\.result', block.split('RESULTS:')[1].split('\n')[0])
            self.assertEqual(sorted(results), sorted(j for j in needs if j in (
                'portable', 'scope', 'sessionkit', 'mac-rest', 'web')), name)
            self.assertIn('if: always()', block, name)

    def test_the_rearm_job_takes_the_script_from_the_trunk_and_reads_the_head_as_data(self):
        for name in self.names:
            block = self.rearm_block(self.text(name))
            self.assertIn("ref: ${{ github.event.pull_request.base.ref || ", block)
            self.assertNotIn('github.head_ref', block)
            self.assertNotIn('pull_request.head.ref', block)
            self.assertIn('actions: write', block)
            self.assertIn('github.event.pull_request.head.repo.full_name == github.repository', block)
            self.assertIn('HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}', block)
            self.assertNotIn('${{', block.split('run: |')[1])

    def test_the_merge_runs_it_starts_are_ones_lane_yml_already_takes(self):
        lane_yml = (ROOT / '.github/workflows/lane.yml').read_text()
        for field in ('pr', 'head', 'auto'):
            self.assertRegex(lane_yml, rf'(?m)^      {field}:$')
        script = (ROOT / 'scripts/lane_rearm.py').read_text()
        for field in ('inputs[pr]', 'inputs[head]', 'inputs[auto]=true'):
            self.assertIn(field, script)


if __name__ == '__main__':
    unittest.main()
