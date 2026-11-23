"""scripts/ci_harness.py: the timed pipeline harness reproduces the faults it was built from (#4937).

The whole sweep (`ci_harness.py --check`, about 30 seconds) runs as its own step in hosted-portable.yml. These tests
hold the harness itself to the live faults: each fixture puts one fixed fault back into the in-memory model of this
tree and expects the harness to see it again.
"""
from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import ci_harness as H  # noqa: E402

M = H.M
OLD_MERGE_POLICY_GROUP = {'group': 'merge-policy-${{ github.event.pull_request.number || github.ref }}-'
                                   '${{ github.event_name }}', 'cancel-in-progress': True}


def fresh_tree():
    return M.Tree(H.ROOT)


class LiveFaultTests(unittest.TestCase):
    def test_the_4929_race_comes_back_only_without_both_fixes(self):
        # #4898 on 2026-11-22: a re-arm's two label events, the newer merge-policy run cancelled by the group, the PR
        # armed and green and never queued. #4930 removed the group; rerun-cancelled.yml re-runs such a run.
        burst = H.case('sessionkit', 'rearm-burst', 'none', 'reversed')
        tree = fresh_tree()
        self.assertEqual(H.violations(burst, H.simulate(burst, tree), tree), [])
        tree.model['workflows']['merge-policy.yml']['concurrency'] = dict(OLD_MERGE_POLICY_GROUP)
        self.assertEqual(H.violations(burst, H.simulate(burst, tree), tree), [], 'rerun-cancelled alone repairs it')
        del tree.model['workflows']['rerun-cancelled.yml']
        self.assertEqual(H.violations(burst, H.simulate(burst, tree), tree), ['silent-stuck'])
        in_order = H.case('sessionkit', 'rearm-burst', 'none', 'created')
        self.assertEqual(H.violations(in_order, H.simulate(in_order, tree), tree), [],
                         'only the order GitHub does not promise loses the newer run')

    def test_an_expired_queue_token_is_silent_when_only_comments_fall_back(self):
        # #4942's audit: the first fix fell back to GITHUB_TOKEN for the comment only, so a dead MERGE_QUEUE_TOKEN
        # failed on the bridge's first read and no PR was told.
        expired = H.case('sessionkit', 'person', 'bridge-token-expired')
        tree = fresh_tree()
        self.assertEqual(H.violations(expired, H.simulate(expired, tree), tree), [])
        module = tree.module('bridge', 'scripts/merge_queue_label_bridge.py')
        saved = module.FALLBACK_KINDS
        try:
            module.FALLBACK_KINDS = frozenset({'comment'})
            self.assertEqual(H.violations(expired, H.simulate(expired, tree), tree), ['silent-stuck'])
        finally:
            module.FALLBACK_KINDS = saved

    def test_static_rules_see_each_fixed_shape_again(self):
        tree = fresh_tree()
        self.assertEqual(H.static_findings(tree), [])
        workflows = tree.model['workflows']
        lane = workflows['lane-conflicts.yml']
        lane['concurrency'] = {'group': 'lane-conflicts', 'cancel-in-progress': False}
        web = workflows['hosted-web.yml']['jobs']['web']
        web['if'] = "needs.changes.result == 'success' && needs.changes.outputs.web == 'true'"
        found = H.static_findings(tree)
        self.assertTrue(any(f.startswith('S1 lane-conflicts.yml') for f in found), found)
        self.assertTrue(any(f.startswith('S2 hosted-web.yml web') for f in found), found)
        required = M.SNAPSHOT['ruleset']['required_checks']
        required.append('a check nobody reports')
        try:
            self.assertIn('S3 required check "a check nobody reports" is reported by no job in .github/workflows',
                          H.static_findings(tree))
        finally:
            required.remove('a check nobody reports')

    def test_check_fails_on_a_new_violation_and_on_a_stale_known_entry(self):
        tree = fresh_tree()
        saved_known, saved_sweep = dict(H.KNOWN), H.sweep
        try:
            H.sweep = lambda tree, only=None: {'sessionkit/rearm-burst/none/reversed': ['silent-stuck']}
            H.KNOWN.clear()
            out = io.StringIO()
            self.assertEqual(H.check(tree, out=out), 1)
            self.assertIn('NEW sessionkit/rearm-burst/none/reversed: silent-stuck', out.getvalue())
            H.sweep = lambda tree, only=None: {}
            H.KNOWN['*/never/*: loop'] = '#0'
            out = io.StringIO()
            self.assertEqual(H.check(tree, out=out), 1)
            self.assertIn('GONE */never/*: loop', out.getvalue())
        finally:
            H.KNOWN.clear()
            H.KNOWN.update(saved_known)
            H.sweep = saved_sweep


class TableTests(unittest.TestCase):
    def test_a_merge_group_that_fails_outside_the_pr_merges_after_one_retry_and_a_test_failure_does_not_(self):
        # #4940: a Mac job that fails in a setup step, or downloads from a host that is down, is retried once by the
        # notifier and the bridge; a test that fails is the PR's and stops at once. Without the failing step the
        # notifier cannot tell them apart and every flake needs a person.
        for kind in ('sessionkit', 'app-audio'):
            for fault in ('mac-fail-once', 'mac-download-fail-once'):
                flake = H.case(kind, 'person', fault)
                tree = fresh_tree()
                result = H.simulate(flake, tree)
                self.assertEqual(H.violations(flake, result, tree), [], f'{kind} {fault}')
                self.assertTrue(result['merged'], f'{kind} {fault}')
                self.assertTrue(any('left the queue on a failure outside the PR' in line for line in result['log']))
            real = H.case(kind, 'person', 'mac-test-fail-once')
            tree = fresh_tree()
            result = H.simulate(real, tree)
            self.assertFalse(result['merged'])
            self.assertIn('needs-fix', result['labels'], 'a failed test is the PR\'s: needs-fix at once')
            self.assertFalse(any('left the queue on a failure outside the PR' in line for line in result['log']))
            self.assertEqual(H.violations(real, result, tree), [])

    def test_a_pr_check_failed_outside_the_pr_is_re_run_only_with_5057(self):
        # #5057: on the PR itself no merge group exists, so a web job failed by a runner or an outside host, or a
        # 90-minute outage, stayed red until a person re-ran it. rerun-cancelled.yml now re-runs it once after a wait.
        self.assertFalse([p for p in H.KNOWN if 'mac-fail-once' in p or 'download-fail' in p or 'outage' in p])
        tree = fresh_tree()
        cases = [H.case('web', 'person', 'mac-fail-once'), H.case('web', 'person', 'mac-download-fail-once'),
                 H.case('sessionkit', 'person', 'outage-90m'), H.case('web', 'person', 'outage-90m')]
        for c in cases:
            with self.subTest(c.name):
                result = H.simulate(c, tree)
                self.assertEqual(H.violations(c, result, tree), [])
                self.assertTrue(any('rerun-cancelled: run' in line and 'waiting 90 minutes' in line
                                    for line in result['log']))
        rerun = tree.model['workflows']['rerun-cancelled.yml']['jobs']['rerun']
        rerun['if'] = ("github.event.workflow_run.conclusion == 'cancelled' && "
                       "github.event.workflow_run.event == 'pull_request'")
        for c in cases:
            with self.subTest(f'{c.name} before #5057'):
                self.assertEqual(H.violations(c, H.simulate(c, tree), tree), ['needs-person'])

    def test_a_pr_check_failed_by_a_test_is_not_re_run(self):
        # #5057 Must not break: a real test failure on a PR stays red and is not re-run.
        c = H.case('web', 'person', 'mac-test-fail-once')
        tree = fresh_tree()
        result = H.simulate(c, tree)
        self.assertEqual(H.violations(c, result, tree), [])
        self.assertFalse(any(line.split('m ', 1)[1].startswith('re-run of') for line in result['log']), result['log'])
        self.assertTrue(result['red_on_head'])

    def test_every_external_download_names_a_real_job(self):
        workflows = fresh_tree().model['workflows']
        for (file, job), hosts in H.EXTERNAL_DOWNLOADS.items():
            with self.subTest(f'{file} {job}'):
                self.assertIn(job, workflows.get(file, {}).get('jobs', {}))
                self.assertTrue(hosts)

    def test_every_known_entry_gives_its_issue_or_reason(self):
        for pattern, why in H.KNOWN.items():
            with self.subTest(pattern):
                self.assertRegex(pattern, r': (merged-broken|silent-stuck|needs-person|slow|loop|retried-test)$')
                self.assertTrue(why.strip())

    def test_the_portable_job_runs_the_whole_sweep(self):
        import yaml
        doc = yaml.safe_load((H.ROOT / '.github/workflows/hosted-portable.yml').read_text())
        steps = doc['jobs']['portable']['steps']
        runs = [str(step.get('run') or '') for step in steps]
        self.assertTrue(any('scripts/ci_harness.py --check' in run for run in runs))
        harness = next(step for step in steps if 'scripts/ci_harness.py --check' in str(step.get('run') or ''))
        self.assertNotIn('if', harness, 'the sweep runs on every PR and merge group, not only on pipeline paths')


if __name__ == '__main__':
    unittest.main()
