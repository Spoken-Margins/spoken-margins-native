import importlib.util
from pathlib import Path
import re
import subprocess
import unittest
import unittest.mock as mock

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lane_dedupe', SCRIPTS / 'lane_dedupe.py')
dedupe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dedupe)

OLD, NEW = 'a' * 40, 'b' * 40


def title(pr, head, lane=False, auto=True):
    return f'lane pr={pr} head={head} lane={str(lane).lower()} auto={str(auto).lower()}'


def run(run_id, pr, head, status='queued', lane=False, auto=True):
    return {'id': run_id, 'status': status, 'display_title': title(pr, head, lane, auto)}


def job(name, status, conclusion=None, labels=None):
    found = {'name': name, 'status': status, 'conclusion': conclusion}
    if labels is not None:
        found['labels'] = labels
    return found


BUILD = ['self-hosted', 'macOS', 'sm-lane-build']
MAIN = ['self-hosted', 'macOS', 'sm-lane']
PRIORITY = ['self-hosted', 'sm-lane-priority']


class FakeApi:
    """Recorded-shape Actions responses: pulls/N, the lane.yml run lists by status, and each run's jobs."""

    def __init__(self, runs=(), jobs=None, pull_state='open', head=NEW, merged=False, fail=None):
        self.runs, self.jobs = list(runs), jobs or {}
        self.pull = {'state': pull_state, 'merged': merged, 'head': {'sha': head}}
        self.fail, self.cancelled, self.run_status = fail, [], {}

    def get(self, path):
        if self.fail:
            raise self.fail
        if path.startswith('pulls/'):
            return self.pull
        if path.startswith('actions/workflows/lane.yml/runs?'):
            status = path.split('status=')[1].split('&')[0]
            found = [r for r in self.runs if r['status'] == status]
            return {'total_count': len(found), 'workflow_runs': found}
        if re.fullmatch(r'actions/runs/\d+', path):
            return {'status': self.run_status.get(int(path.split('/')[2]), 'queued')}
        if path.startswith('actions/runs/'):
            jobs = self.jobs.get(int(path.split('/')[2]), [])
            return {'total_count': len(jobs), 'jobs': jobs}
        raise AssertionError(path)

    def post(self, path):
        self.cancelled.append(int(path.split('/')[2]))


WANTS_AUTO = {'lane': False, 'automerge': True}


class DedupeTests(unittest.TestCase):
    def route(self, api, wants=WANTS_AUTO, run_id=200, head=NEW):
        return dedupe.route(api, 580, head, run_id, wants)

    def test_an_older_commits_run_still_waiting_for_a_mac_is_cancelled(self):
        # #580: the run for cbbbff8 sat queued while the run for the current head waited behind it.
        api = FakeApi([run(100, 580, OLD)], {100: [job('route', 'completed', 'success'),
                                                    job('automerge', 'queued')]})
        self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [100])

    def test_a_skipped_mac_job_does_not_protect_the_other_queued_job(self):
        skipped = dict(job('lane', 'completed', 'skipped'), started_at='2026-10-07T10:00:00Z')
        api = FakeApi([run(100, 580, OLD)], {100: [skipped, job('automerge', 'queued')]})
        self.route(api)
        self.assertEqual(api.cancelled, [100])

    def test_a_queued_mac_job_that_already_carries_started_at_is_still_cancelled(self):
        # GitHub fills in started_at when it queues a job (Octokit's workflow_job "queued" example does),
        # so the status decides whether the job has started, never the timestamp.
        for status in ('queued', 'waiting', 'pending'):
            for kind in dedupe.KINDS:
                with self.subTest(status=status, kind=kind):
                    queued = dict(job(kind, status), started_at='2026-10-07T10:00:00Z')
                    api = FakeApi([run(100, 580, OLD)], {100: [queued]})
                    self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
                    self.assertEqual(api.cancelled, [100])

    def test_the_refresh_before_cancelling_also_ignores_a_queued_jobs_started_at(self):
        api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]})
        real_get = api.get
        pull_reads = 0

        def get(path):
            nonlocal pull_reads
            if path.startswith('pulls/'):
                pull_reads += 1
                if pull_reads == 2:
                    api.jobs[100] = [dict(job('automerge', 'queued'), started_at='2026-10-07T10:00:00Z')]
            return real_get(path)

        api.get = get
        self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [100])

    def test_an_older_commits_run_whose_mac_job_started_is_left_alone(self):
        api = FakeApi([run(100, 580, OLD, 'in_progress')], {100: [job('automerge', 'in_progress')]})
        self.route(api)
        self.assertEqual(api.cancelled, [])

    def test_jobs_are_refreshed_after_the_pr_recheck_before_cancelling(self):
        for kind in dedupe.KINDS:
            with self.subTest(kind=kind):
                api = FakeApi([run(100, 580, OLD)], {100: [job(kind, 'queued')]})
                real_get = api.get
                pull_reads = 0

                def get(path):
                    nonlocal pull_reads
                    if path.startswith('pulls/'):
                        pull_reads += 1
                        if pull_reads == 2:
                            api.jobs[100] = [job(kind, 'in_progress')]
                    return real_get(path)

                api.get = get
                self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
                self.assertEqual(api.cancelled, [])

    def test_an_unavailable_job_refresh_falls_back_without_cancelling(self):
        for response in (OSError('offline'), {'total_count': 2, 'jobs': []}):
            with self.subTest(response=response):
                api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]})
                real_get = api.get
                job_reads = 0

                def get(path):
                    nonlocal job_reads
                    if path.startswith('actions/runs/'):
                        job_reads += 1
                        if job_reads == 2:
                            if isinstance(response, Exception):
                                raise response
                            return response
                    return real_get(path)

                api.get = get
                self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
                self.assertEqual(api.cancelled, [])

    def test_a_job_that_finished_during_listing_is_left_alone(self):
        api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]})
        real_get = api.get

        def get(path):
            if path.startswith('pulls/') and api.jobs[100][0]['status'] == 'queued':
                # Only change the snapshot after decide has listed this run's jobs.
                if api.jobs_read:
                    api.jobs[100] = [job('automerge', 'completed', 'success')]
            if path.startswith('actions/runs/'):
                api.jobs_read = True
            return real_get(path)

        api.jobs_read = False
        api.get = get
        self.route(api)
        self.assertEqual(api.cancelled, [])

    def test_a_newer_run_for_a_different_head_is_never_cancelled(self):
        api = FakeApi([run(300, 580, OLD)], {300: [job('automerge', 'queued')]})
        self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [])

    def test_a_push_during_listing_stops_this_run_without_cancelling_anything(self):
        api = FakeApi([run(100, 580, OLD), run(300, 580, 'c' * 40)],
                      {100: [job('automerge', 'queued')], 300: [job('automerge', 'queued')]})
        real_get = api.get

        def get(path):
            if path.startswith('actions/workflows/'):
                api.pull = dict(api.pull, head={'sha': 'c' * 40})
            return real_get(path)

        api.get = get
        self.assertEqual(self.route(api), {'lane': True, 'automerge': True})
        self.assertEqual(api.cancelled, [])

    def test_a_pr_closed_during_listing_cancels_nothing(self):
        for merged in (True, False):
            with self.subTest(merged=merged):
                api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]})
                real_get = api.get

                def get(path):
                    if path.startswith('actions/workflows/'):
                        api.pull = dict(api.pull, state='closed', merged=merged)
                    return real_get(path)

                api.get = get
                self.assertEqual(self.route(api), {'lane': True, 'automerge': True})
                self.assertEqual(api.cancelled, [])

    def test_the_head_is_rechecked_before_each_cancellation(self):
        api = FakeApi([run(100, 580, OLD), run(150, 580, OLD)],
                      {100: [job('automerge', 'queued')], 150: [job('automerge', 'queued')]})
        real_post = api.post

        def post(path):
            real_post(path)
            api.pull = dict(api.pull, head={'sha': 'c' * 40})

        api.post = post
        self.assertEqual(self.route(api), {'lane': True, 'automerge': True})
        self.assertEqual(api.cancelled, [100])

    def test_a_failed_head_recheck_falls_back_without_cancelling(self):
        api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]})
        real_get = api.get
        pull_reads = 0

        def get(path):
            nonlocal pull_reads
            if path.startswith('pulls/'):
                pull_reads += 1
                if pull_reads > 1:
                    raise subprocess.TimeoutExpired('gh', 30)
            return real_get(path)

        api.get = get
        self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [])

    def test_another_prs_runs_are_never_cancelled(self):
        api = FakeApi([run(100, 581, OLD)], {100: [job('automerge', 'queued')]})
        self.route(api)
        self.assertEqual(api.cancelled, [])

    def test_a_second_run_of_the_same_head_and_kind_stops_at_route(self):
        # #573: two automerge runs for f39dbfb, 14 seconds apart.
        api = FakeApi([run(100, 573, NEW)], {100: [job('automerge', 'queued')]})
        self.assertEqual(dedupe.route(api, 573, NEW, 200, WANTS_AUTO), {'lane': False, 'automerge': True})
        self.assertEqual(api.cancelled, [])

    def test_the_older_run_of_a_pair_is_never_stopped_by_the_newer_one(self):
        api = FakeApi([run(200, 573, NEW)], {200: [job('automerge', 'queued')]})
        self.assertEqual(dedupe.route(api, 573, NEW, 100, WANTS_AUTO), {'lane': False, 'automerge': False})

    def test_the_duplicate_check_is_per_kind(self):
        api = FakeApi([run(100, 573, NEW, lane=False, auto=True)], {100: [job('automerge', 'in_progress')]})
        both = {'lane': True, 'automerge': True}
        self.assertEqual(dedupe.route(api, 573, NEW, 200, both), {'lane': False, 'automerge': True})

    def test_an_earlier_run_that_finished_or_skipped_the_kind_does_not_block(self):
        # The #734 path: re-adding automerge after a clean audit must still produce a run that can merge.
        for earlier in ([job('automerge', 'completed', 'success')], [job('automerge', 'completed', 'skipped')]):
            api = FakeApi([run(100, 573, NEW, 'in_progress')], {100: earlier})
            self.assertEqual(dedupe.route(api, 573, NEW, 200, WANTS_AUTO), {'lane': False, 'automerge': False})

    def test_a_closed_or_merged_pr_stops_both_jobs(self):
        # #327: merged but still carrying automerge, with a run queued for hours.
        for merged in (True, False):
            api = FakeApi(pull_state='closed', merged=merged)
            self.assertEqual(self.route(api), {'lane': True, 'automerge': True})

    def test_a_run_for_a_commit_the_pr_moved_past_stops_both_jobs(self):
        api = FakeApi(head=NEW)
        self.assertEqual(dedupe.route(api, 580, OLD, 100, WANTS_AUTO), {'lane': True, 'automerge': True})

    def test_any_api_error_runs_as_before(self):
        for error in (subprocess.CalledProcessError(1, 'gh'), OSError('offline'), ValueError('bad json'),
                      subprocess.TimeoutExpired('gh', 30)):
            api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]}, pull_state='closed', fail=error)
            self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
            self.assertEqual(api.cancelled, [])

    def test_an_incomplete_listing_runs_as_before(self):
        api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]})
        api.get = lambda path, real=api.get: ({'total_count': 150, 'workflow_runs': []}
                                              if 'status=queued' in path else real(path))
        self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [])

    def test_a_failed_cancel_does_not_stop_the_run(self):
        api = FakeApi([run(100, 580, OLD)], {100: [job('automerge', 'queued')]})
        api.post = mock.Mock(side_effect=subprocess.CalledProcessError(1, 'gh'))
        self.assertEqual(self.route(api), {'lane': False, 'automerge': False})

    def test_runs_without_a_recognised_name_are_ignored(self):
        api = FakeApi([{'id': 100, 'status': 'queued', 'display_title': 'lane'}])
        self.assertEqual(self.route(api), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [])

    def test_a_same_head_run_waiting_in_another_queue_is_replaced(self):
        # #1194: #1181 sat in sm-lane-build as run 37955198225; re-arming routed the new run to the priority
        # runner, but the duplicate rule skipped it and the PR stayed in the old queue.
        api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=BUILD)]})
        queues = {'lane': PRIORITY, 'automerge': PRIORITY}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [100])

    def test_a_same_head_run_in_the_same_queue_still_stops_the_newer_one(self):
        api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=BUILD)]})
        queues = {'lane': MAIN, 'automerge': list(reversed(BUILD))}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': True})
        self.assertEqual(api.cancelled, [])

    def test_a_same_head_run_whose_mac_job_started_is_never_cancelled(self):
        # in_progress holds the automerge slot; a finished job frees it (the lane job still holds its own).
        for started, skipped_automerge in (('in_progress', True), ('completed', False)):
            with self.subTest(started=started):
                api = FakeApi([run(100, 580, NEW, 'in_progress', lane=True)],
                              {100: [job('lane', 'queued', labels=MAIN),
                                     job('automerge', started, 'success' if started == 'completed' else None,
                                         labels=BUILD)]})
                queues = {'lane': PRIORITY, 'automerge': PRIORITY}
                both = {'lane': True, 'automerge': True}
                self.assertEqual(dedupe.route(api, 580, NEW, 200, both, queues), {'lane': True, 'automerge': skipped_automerge})
                self.assertEqual(api.cancelled, [])

    def test_a_mac_job_that_starts_before_the_cancel_keeps_its_slot(self):
        api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=BUILD)]})
        real_get = api.get
        pull_reads = 0

        def get(path):
            nonlocal pull_reads
            if path.startswith('pulls/'):
                pull_reads += 1
                if pull_reads == 2:
                    api.jobs[100] = [job('automerge', 'in_progress', labels=BUILD)]
            return real_get(path)

        api.get = get
        queues = {'lane': PRIORITY, 'automerge': PRIORITY}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': True})
        self.assertEqual(api.cancelled, [])

    def test_nothing_is_replaced_without_known_queues_or_labels(self):
        # No routing file, a job with no labels (not created or not reported) and a queue with no labels:
        # today's behaviour, the newer duplicate stops.
        for queues, labels in ((None, BUILD), ({'lane': PRIORITY, 'automerge': PRIORITY}, None),
                               ({'lane': PRIORITY}, BUILD), ({'lane': PRIORITY, 'automerge': []}, BUILD)):
            with self.subTest(queues=queues, labels=labels):
                api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=labels)]})
                self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues),
                                 {'lane': False, 'automerge': True})
                self.assertEqual(api.cancelled, [])

    def test_an_older_run_is_kept_when_cancelling_it_would_drop_a_job_this_run_does_not_replace(self):
        # The older run also holds a lane job; this run only asks for automerge, so cancelling would lose it.
        api = FakeApi([run(100, 580, NEW, lane=True)], {100: [job('lane', 'queued', labels=MAIN),
                                                                job('automerge', 'queued', labels=BUILD)]})
        queues = {'lane': PRIORITY, 'automerge': PRIORITY}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': True})
        self.assertEqual(api.cancelled, [])

    def test_an_older_run_is_kept_when_one_of_its_held_jobs_stays_in_the_same_queue(self):
        api = FakeApi([run(100, 580, NEW, lane=True)], {100: [job('lane', 'queued', labels=MAIN),
                                                                job('automerge', 'queued', labels=BUILD)]})
        queues = {'lane': MAIN, 'automerge': PRIORITY}
        both = {'lane': True, 'automerge': True}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, both, queues), {'lane': True, 'automerge': True})
        self.assertEqual(api.cancelled, [])

    def test_a_run_that_finished_or_skipped_its_job_is_not_replaced(self):
        for earlier in (job('automerge', 'completed', 'success', labels=BUILD),
                        job('automerge', 'completed', 'skipped', labels=BUILD)):
            api = FakeApi([run(100, 580, NEW, 'in_progress')], {100: [earlier]})
            queues = {'lane': PRIORITY, 'automerge': PRIORITY}
            self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': False})
            self.assertEqual(api.cancelled, [])

    def test_a_newer_run_in_another_queue_is_never_cancelled(self):
        api = FakeApi([run(300, 580, NEW)], {300: [job('automerge', 'queued', labels=BUILD)]})
        queues = {'lane': PRIORITY, 'automerge': PRIORITY}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': False})
        self.assertEqual(api.cancelled, [])

    def test_queue_labels_compare_without_regard_to_case(self):
        # The jobs API may report "macos" where routing says "macOS": that is the same queue, not a move.
        api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=['self-hosted', 'macos', 'SM-Lane-Build'])]})
        queues = {'lane': MAIN, 'automerge': BUILD}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': True})
        self.assertEqual(api.cancelled, [])

    def test_a_failed_cancel_of_a_run_still_seen_waiting_stops_this_one_instead_of_doubling_up(self):
        api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=BUILD)]})
        api.post = mock.Mock(side_effect=subprocess.CalledProcessError(1, 'gh'))
        queues = {'lane': PRIORITY, 'automerge': PRIORITY}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': True})

    def test_a_cancel_that_took_effect_before_the_client_gave_up_still_lets_this_run_go_ahead(self):
        # GitHub cancelled the older run but gh timed out before the answer: stopping this run too would leave the
        # PR with none (the Codex audit's P2 on #1227).
        queues = {'lane': PRIORITY, 'automerge': PRIORITY}
        for status in ('completed', 'cancelled'):
            with self.subTest(status=status):
                api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=BUILD)]})
                api.run_status[100] = status
                api.post = mock.Mock(side_effect=subprocess.TimeoutExpired('gh', 30))
                self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues),
                                 {'lane': False, 'automerge': False})

    def test_an_unreadable_older_run_after_a_failed_cancel_lets_this_run_go_ahead(self):
        # Both running beats neither: a duplicate run is harmless, a PR with no run needs another re-arm.
        api = FakeApi([run(100, 580, NEW)], {100: [job('automerge', 'queued', labels=BUILD)]})
        real_get = api.get

        def get(path):
            if re.fullmatch(r'actions/runs/\d+', path):
                raise OSError('offline')
            return real_get(path)
        api.get = get
        api.post = mock.Mock(side_effect=subprocess.TimeoutExpired('gh', 30))
        queues = {'lane': PRIORITY, 'automerge': PRIORITY}
        self.assertEqual(dedupe.route(api, 580, NEW, 200, WANTS_AUTO, queues), {'lane': False, 'automerge': False})

    def test_the_routing_file_is_read_leniently(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            good = Path(folder, 'route.json')
            good.write_text('{"lane": ["self-hosted", "sm-lane-priority"], "automerge": "bad"}')
            self.assertEqual(dedupe.read_queues(str(good)), {'lane': PRIORITY})
            empty = Path(folder, 'empty.json')
            empty.write_text('')
            for path in (None, str(empty), str(Path(folder, 'missing.json'))):
                self.assertIsNone(dedupe.read_queues(path))
            listed = Path(folder, 'list.json')
            listed.write_text('[1]')
            self.assertIsNone(dedupe.read_queues(str(listed)))

    def test_run_names_parse(self):
        self.assertEqual(dedupe.parse_run_name(title(5, NEW, True, False)),
                         {'pr': 5, 'head': NEW, 'kinds': {'lane': True, 'automerge': False}})
        self.assertIsNone(dedupe.parse_run_name('Merge pull request'))
        self.assertIsNone(dedupe.parse_run_name(None))


class WorkflowWiringTests(unittest.TestCase):
    workflow = (SCRIPTS.parent / '.github/workflows/lane.yml').read_text()

    def test_queues_are_chosen_before_dedupe_and_handed_to_it(self):
        # #1194: dedupe compares the queue this run would use, so routing has to have written its file first.
        route = self.workflow.split('\n  route:\n')[1].split('\n  lane:\n')[0]
        self.assertLess(route.index('- name: Choose queues'), route.index('- name: Drop stale and duplicate runs'))
        self.assertIn('--queues "$RUNNER_TEMP/route.json"', route)

    def test_the_run_name_has_the_format_the_helper_parses(self):
        name = self.workflow.split('run-name: >-\n')[1].split('\non:')[0]
        flat = ' '.join(part.strip() for part in name.splitlines())
        self.assertRegex(flat, r'^lane pr=\$\{\{ [^}]+ \}\} head=\$\{\{ [^}]+ \}\} lane=\$\{\{ [^}]+ \}\} auto=\$\{\{ [^}]+ \}\}$')

    def test_the_route_job_cancels_and_both_mac_jobs_obey_it(self):
        route = self.workflow.split('\n  route:\n')[1].split('\n  lane:\n')[0]
        self.assertIn('actions: write', route)
        self.assertIn('scripts/lane_dedupe.py', route)
        self.assertIn("needs.route.outputs.skip_lane != 'true'", self.workflow)
        self.assertIn("needs.route.outputs.skip_automerge != 'true'", self.workflow)
        self.assertIn('timeout-minutes: 3', route)

    def test_dedupe_has_a_total_timeout_with_room_for_routing_and_fallback(self):
        route = self.workflow.split('\n  route:\n')[1].split('\n  lane:\n')[0]
        match = re.search(r'if timeout (\d+)s python3 scripts/lane_dedupe\.py', route)
        self.assertIsNotNone(match, 'Serial API calls must share an overall helper timeout')
        discovery_budgets = [int(value) for value in re.findall(r'timeout (\d+)s gh api', route)]
        job_budget = int(re.search(r'timeout-minutes: (\d+)', route)[1]) * 60
        self.assertLessEqual(sum(discovery_budgets) + int(match[1]), job_budget - 60)
        # A timeout must take the same unset-output fallback as a missing helper or API failure.
        step = route.split('      - name: Drop stale and duplicate runs\n')[1]
        self.assertIn('>> "$GITHUB_OUTPUT"\n          else\n', step)
        self.assertIn('Lane dedupe unavailable; running as before.', step)


if __name__ == '__main__':
    unittest.main()
