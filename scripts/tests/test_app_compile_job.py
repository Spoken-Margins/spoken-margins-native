"""hosted-portable.yml's `app-compile` job: the merge queue's app build (2026-11-20, #4750)."""
import unittest

import workflow_yaml as W

WORKFLOW = W.load('hosted-portable.yml')
JOB = WORKFLOW['jobs']['app-compile']


def runs(event, app='true', scope='success'):
    condition = str(JOB['if']).replace('!cancelled() &&', '')  # the helper evaluates no function calls
    return W.evaluate_condition(condition, github_event_name=event, needs_scope_result=scope, needs_scope_outputs_app=app)


class AppCompileJobTests(unittest.TestCase):
    def test_it_builds_in_the_merge_queue_and_on_a_dispatch(self):
        self.assertTrue(runs('merge_group'))
        self.assertTrue(runs('workflow_dispatch'))

    def test_it_never_runs_on_a_pr_push_so_the_required_check_is_earned_in_the_queue(self):
        # A skipped job reports success: the PR is admitted, and the group's run is the one that counts.
        self.assertFalse(runs('pull_request'))
        self.assertFalse(runs('push'))

    def test_a_group_with_no_app_input_skips_it_and_an_unknown_answer_builds(self):
        self.assertFalse(runs('merge_group', app='false'))
        self.assertTrue(runs('merge_group', app=''))  # scope said nothing: build

    def test_a_failed_scope_job_does_not_wave_it_through(self):
        # needs.scope failing skips this job, which reports success; `hosted fast: scope` is itself required, so a red
        # scope still blocks the group.
        self.assertFalse(runs('merge_group', scope='failure'))

    def test_it_is_compile_only_on_a_mac_and_cannot_wait_forever(self):
        self.assertEqual(JOB['runs-on'], 'xcode-27')
        self.assertLessEqual(JOB['timeout-minutes'], 45)
        build = next(s['run'] for s in JOB['steps'] if 'xcodebuild' in str(s.get('run', '')))
        self.assertIn('build-for-testing', build)
        self.assertNotIn('test-without-building', build)
        self.assertNotIn('simctl', build)

    def test_the_scope_job_publishes_the_app_answer(self):
        self.assertIn('app', WORKFLOW['jobs']['scope']['outputs'])
        self.assertIn('--app-compile-required', WORKFLOW['jobs']['scope']['steps'][-1]['run'])

    def test_the_workflow_runs_in_the_merge_queue(self):
        on = WORKFLOW.get('on', WORKFLOW.get(True))
        self.assertIn('merge_group', on)


if __name__ == '__main__':
    unittest.main()
