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
    def test_every_external_download_names_a_real_job(self):
        workflows = fresh_tree().model['workflows']
        for (file, job), hosts in H.EXTERNAL_DOWNLOADS.items():
            with self.subTest(f'{file} {job}'):
                self.assertIn(job, workflows.get(file, {}).get('jobs', {}))
                self.assertTrue(hosts)

    def test_every_known_entry_gives_its_issue_or_reason(self):
        for pattern, why in H.KNOWN.items():
            with self.subTest(pattern):
                self.assertRegex(pattern, r': (merged-broken|silent-stuck|needs-person|slow|loop)$')
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
