"""scripts/ci_model.py: the offline model of a PR's path from arming to merged.

The scenario outcomes are the model's findings about the pipeline as it is on this tree. A CI change that alters one
should change the expectation here in the same PR, with the reason in its description (`ci_model.py --diff`).
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('ci_model', SCRIPTS / 'ci_model.py')
ci_model = importlib.util.module_from_spec(spec)
sys.modules['ci_model'] = ci_model  # dataclasses look the module up by name
spec.loader.exec_module(ci_model)

TREE = ci_model.Tree(ROOT)
RESULTS = {}


def outcome(name):
    if name not in RESULTS:
        scenario = next(s for s in ci_model.scenarios() if s.name == name)
        RESULTS[name] = ci_model.simulate(scenario, TREE)
    return RESULTS[name]


class ExpressionTests(unittest.TestCase):
    CTX = {'github': {'event_name': 'pull_request_target', 'event': {
        'action': 'labeled', 'label': {'name': 'automerge'},
        'pull_request': {'labels': [{'name': 'automerge'}, {'name': 'lane:done'}]}}},
        'vars': {'MERGE_QUEUE': 'on'}, 'needs': {'scope': {'result': 'success', 'outputs': {'docs_only': 'true'}}}}

    def check(self, text, needs=()):
        return ci_model.condition(text, self.CTX, list(needs))

    def test_the_bridge_condition(self):
        text = TREE.model['workflows']['merge-queue-label-bridge.yml']['jobs']['bridge']['if']
        self.assertTrue(self.check(text))

    def test_operators_and_functions(self):
        self.assertTrue(self.check("contains(github.event.pull_request.labels.*.name, 'AUTOMERGE')"))
        self.assertFalse(self.check("vars.MISSING == 'on'"))
        self.assertTrue(self.check("vars.MISSING != 'on'"))
        self.assertTrue(self.check("!cancelled() && needs.scope.outputs.docs_only == 'true'", ['success']))
        self.assertFalse(self.check("needs.scope.outputs.docs_only != 'true'", ['success']))
        self.assertTrue(self.check("startsWith(github.event_name, 'pull_')"))
        self.assertEqual(ci_model.Expr("'a' || 'b'", {}, {}).evaluate(), 'a')

    def test_implicit_success(self):
        # No status function: GitHub adds success(), so a failed need skips the job.
        self.assertFalse(self.check("vars.MERGE_QUEUE == 'on'", ['failure']))
        self.assertTrue(self.check("always() && vars.MERGE_QUEUE == 'on'", ['failure']))


class FilterAndCronTests(unittest.TestCase):
    def test_paths_with_negation(self):
        patterns = ['App/**', 'Packages/**', '!Packages/SessionKit/Tests/**']
        self.assertTrue(ci_model.filter_match(['App/A/B.swift'], patterns))
        self.assertFalse(ci_model.filter_match(['Packages/SessionKit/Tests/X.swift'], patterns))
        self.assertFalse(ci_model.filter_match(['docs/x.md'], patterns))
        self.assertTrue(ci_model.filter_match(['docs/x.md'], None))
        self.assertFalse(ci_model.filter_match(['docs/x.md'], None, ['docs/**']))

    def test_cron(self):
        self.assertTrue(ci_model.cron_fires('7,22,37,52 * * * *', 10 * 60 + 22, 5, 20, 11))
        self.assertFalse(ci_model.cron_fires('7,22,37,52 * * * *', 10 * 60 + 23, 5, 20, 11))
        self.assertTrue(ci_model.cron_fires('17 */3 * * *', 9 * 60 + 17, 5, 20, 11))
        self.assertFalse(ci_model.cron_fires('17 */3 * * *', 10 * 60 + 17, 5, 20, 11))


class ExtractTests(unittest.TestCase):
    def test_every_required_check_has_a_producer_on_pull_request_and_merge_group(self):
        for name, producers in TREE.model['required_checks'].items():
            events = {e for p in producers for e in p['events']}
            self.assertTrue({'pull_request', 'merge_group'} <= events, name)

    def test_tokens_and_effects(self):
        workflows = TREE.model['workflows']
        self.assertEqual(workflows['merge-queue-label-bridge.yml']['jobs']['bridge']['token'], 'secret:MERGE_QUEUE_TOKEN')
        self.assertEqual(workflows['merge-queue-dequeued.yml']['jobs']['dequeued']['token'], 'github_token')
        kinds = {e['kind'] for e in workflows['merge-queue-dequeued.yml']['effects']}
        self.assertTrue({'label-add', 'label-remove', 'comment'} <= kinds)
        self.assertIn('rerun', {e['kind'] for e in workflows['claude-audit.yml']['effects']})
        self.assertTrue(workflows['lane.yml']['disabled'])

    def test_every_assumption_is_cited(self):
        for key, item in ci_model.ASSUMPTIONS.items():
            self.assertIn(item['basis'], ('documented', 'observed', 'inferred'), key)
            self.assertTrue(item['source'], key)


class ScenarioTests(unittest.TestCase):
    """What the model says about the pipeline on this tree (SNAPSHOT of 2026-11-20)."""

    def test_a_docs_pr_armed_by_a_person_merges(self):
        result = outcome('a-docs-armed')
        self.assertTrue(result['merged'])
        self.assertEqual(result['relied_on_schedule'], [])

    def test_b_lane_pr_waits_for_the_scheduled_audit_and_its_re_run(self):
        result = outcome('b-lane-no-audit')
        self.assertTrue(result['merged'])
        self.assertEqual(result['relied_on_schedule'], ['claude-audit.yml'])  # lane.yml disabled: no workflow_run
        self.assertTrue(any('re-run of merge-policy.yml' in line for line in result['log']))

    def test_b2_an_audit_posted_outside_a_workflow_leaves_merge_policy_red(self):
        result = outcome('b2-lane-audit-from-outside')
        self.assertFalse(result['merged'])
        self.assertIn('merge policy', ' '.join(result['why']))

    def test_b3_no_re_run_when_the_policy_run_is_still_going(self):
        result = outcome('b3-lane-audit-while-policy-runs')
        self.assertFalse(result['merged'])
        self.assertTrue(any('merge policy check still running' in line for line in result['log']))

    def test_b4_failed_rearm_job_stops_the_audit(self):
        result = outcome('b4-lane-armed-before-checks')
        self.assertFalse(result['merged'])
        self.assertTrue(any('rearm: ::error::PR #1: could not start its merge run' in line for line in result['log']))
        self.assertTrue(any('not audited (checks failed)' in line for line in result['log']))

    def test_b4_unsticks_when_rearm_stands_down_with_the_lane_off(self):
        """The same scenario on a tree whose lane_rearm.py stands down green when lane.yml is not active (#4755).
        The model runs the tree's real lane_rearm.main(), so the fix shows without any change to the model."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ('.github', 'ops', 'project.yml', 'TestPlans'):
                if (ROOT / name).exists():
                    os.symlink(ROOT / name, root / name)
            (root / 'scripts').mkdir()
            for entry in (ROOT / 'scripts').iterdir():
                if entry.name != 'lane_rearm.py':
                    os.symlink(entry, root / 'scripts' / entry.name)
            text = (ROOT / 'scripts/lane_rearm.py').read_text(encoding='utf-8')
            anchor = '    started, failed = [], []\n'
            self.assertIn(anchor, text)
            stand_down = ("    if api.get('actions/workflows/lane.yml').get('state') != 'active':\n"
                          "        print('lane.yml is not active: nothing to start', file=out)\n"
                          "        return [], []\n")
            (root / 'scripts/lane_rearm.py').write_text(text.replace(anchor, stand_down + anchor, 1), encoding='utf-8')
            scenario = next(s for s in ci_model.scenarios() if s.name == 'b4-lane-armed-before-checks')
            result = ci_model.simulate(scenario, ci_model.Tree(root))
        self.assertTrue(result['merged'], ci_model.summary(result))
        self.assertTrue(any('rearm: lane.yml is not active' in line for line in result['log']))
        self.assertEqual(result['relied_on_schedule'], ['claude-audit.yml'])

    def test_c_a_token_label_is_queued_only_by_the_sweep(self):
        for name in ('c-token-label', 'c2-token-label-nominal'):
            result = outcome(name)
            self.assertTrue(result['merged'], name)
            self.assertEqual(result['relied_on_schedule'], ['merge-queue-label-bridge.yml'], name)
            self.assertFalse(any('pull_request_target): bridge=' in line and line.startswith('1m')
                                 for line in result['log']), name)
        self.assertGreater(outcome('c-token-label')['merged_at_minute'], outcome('c2-token-label-nominal')['merged_at_minute'])

    def test_d_failed_group_dequeues_and_adds_needs_fix(self):
        result = outcome('d-group-fails')
        self.assertFalse(result['merged'])
        self.assertEqual(result['merge_groups'], 1)
        self.assertIn('needs-fix', result['labels'])
        self.assertNotIn('automerge', result['labels'])

    def test_d2_if_auto_merge_survived_a_dequeue_the_pr_loops(self):
        self.assertGreaterEqual(outcome('d2-group-fails-auto-merge-kept')['merge_groups'], ci_model.MAX_GROUPS)

    def test_e_app_compile_error_passes_every_required_check(self):
        result = outcome('e-app-swift-compile-error')
        self.assertTrue(result['merged'])
        self.assertEqual(result['main_broken']['detected_by'], 'hosted-app-macos.yml')

    def test_f_re_arm_by_token_after_needs_fix_never_queues(self):
        result = outcome('f-rearm-by-token-after-fix')
        self.assertFalse(result['merged'])
        self.assertEqual(result['labels'], ['automerge', 'needs-fix'])

    def test_g_owner_tap_pr_merges_after_audit_and_tap(self):
        result = outcome('g-owner-tap-workflow')
        self.assertTrue(result['merged'])
        self.assertGreaterEqual(result['merged_at_minute'], 600)


class DiffTests(unittest.TestCase):
    def test_a_workflow_change_shows_as_a_changed_outcome(self):
        """A copy of the tree whose claude-audit.yml also starts on hosted-portable: scenario b stops waiting."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ('scripts', 'ops', 'project.yml', 'TestPlans'):
                if (ROOT / name).exists():
                    os.symlink(ROOT / name, root / name)
            shutil.copytree(ROOT / '.github', root / '.github')
            audit = root / '.github/workflows/claude-audit.yml'
            text = audit.read_text(encoding='utf-8')
            self.assertIn('workflows: [lane]', text)
            audit.write_text(text.replace('workflows: [lane]', 'workflows: [lane, hosted-portable]'), encoding='utf-8')
            changed = ci_model.Tree(root)
            self.assertEqual(ci_model.static_diff(TREE.model, changed.model), ['claude-audit.yml: triggers changed'])
            scenario = next(s for s in ci_model.scenarios() if s.name == 'b-lane-no-audit')
            after = ci_model.simulate(scenario, changed)
            self.assertNotEqual(ci_model.summary(after), ci_model.summary(outcome('b-lane-no-audit')))
            self.assertEqual(after['relied_on_schedule'], [])


if __name__ == '__main__':
    unittest.main()
