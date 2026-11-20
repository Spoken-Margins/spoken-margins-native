"""scripts/ci_model.py: the offline model of a PR's path from arming to merged.

These tests run in CI (runner-tests), so none may go red when a CI fix lands: a test that pins a current defect runs
on a fixture tree, and outcomes on this tree are asserted only where a fix would not flip them. Read
`ci_model.py --diff` to see what a CI change does to each scenario.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

import yaml

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
        self.assertTrue(workflows['lane.yml']['disabled'])

    def test_effects_are_found_however_a_script_is_formatted(self):
        """On a fixture script, never a live one: how a live script is formatted must not matter to any test."""
        script = '''import subprocess
def run(github, number, sha):
    github.post(f'issues/{number}/comments', {'body': 'one line'})
    github.post(
        f"issues/{number}/labels",
        {"labels": ["needs-fix"]},
    )
    github.delete(f'issues/{number}/labels/{"automerge"}')
    subprocess.run(['gh', 'run',
                    'rerun', sha], check=True)
    subprocess.run(
        [
            "gh",
            "pr",
            "merge",
            str(number),
        ]
    )
    # gh pr comment in a comment is not an effect
    command = ['gh', 'workflow', 'run', 'x.yml']
'''
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'scripts').mkdir()
            (Path(tmp) / 'scripts/fake.py').write_text(script, encoding='utf-8')
            (Path(tmp) / 'scripts/fake.sh').write_text('gh pr comment "$PR" --body hi\n# gh pr merge\n', encoding='utf-8')
            effects = ci_model.script_effects(Path(tmp), 'scripts/fake.py')
            shell = ci_model.script_effects(Path(tmp), 'scripts/fake.sh')
        self.assertEqual([(e['kind'], e['at']) for e in effects],
                         [('comment', 'scripts/fake.py:3'), ('label-add', 'scripts/fake.py:4'),
                          ('label-remove', 'scripts/fake.py:8'), ('rerun', 'scripts/fake.py:9'),
                          ('queue', 'scripts/fake.py:11'), ('dispatch', 'scripts/fake.py:20')])
        self.assertEqual([(e['kind'], e['at']) for e in shell], [('comment', 'scripts/fake.sh:1')])

    def test_every_assumption_is_cited(self):
        for key, item in ci_model.ASSUMPTIONS.items():
            self.assertIn(item['basis'], ('documented', 'observed', 'inferred'), key)
            self.assertTrue(item['source'], key)


def fixture_tree(tmp, replace):
    """A copy of this tree in tmp, every entry a symlink except the files in `replace` ({relative path: text}).
    Tests that pin a current pipeline defect run on a fixture like this, so landing the fix never turns them red."""
    root = Path(tmp)
    dirs = {Path(rel).parts[0] for rel in replace}
    for entry in ROOT.iterdir():
        if entry.name in ('.github', 'scripts', 'ops', 'project.yml', 'TestPlans') and entry.name not in dirs:
            os.symlink(entry, root / entry.name)
    for top in dirs:
        if top == '.github':
            shutil.copytree(ROOT / '.github', root / '.github')
        else:
            (root / top).mkdir()
            for entry in (ROOT / top).iterdir():
                if f'{top}/{entry.name}' not in replace:
                    os.symlink(entry, root / top / entry.name)
    for rel, text in replace.items():
        (root / rel).write_text(text, encoding='utf-8')
    return ci_model.Tree(root)


def on_fixture(name, replace):
    with tempfile.TemporaryDirectory() as tmp:
        scenario = next(s for s in ci_model.scenarios() if s.name == name)
        return ci_model.simulate(scenario, fixture_tree(tmp, replace))


def logged(result, text):
    return any(text in line for line in result['log'])


# A lane_rearm.py that always asks for a lane run, as the script did before #4755, and one that stands down green
# when lane.yml is not active, as #4755 makes it. Both answer the interface ci_model.b_rearm calls.
REARM_ALWAYS_DISPATCHES = '''import argparse, subprocess, sys
def main(argv=None, api=None, out=sys.stdout):
    parser = argparse.ArgumentParser()
    for flag in ('--repo', '--trunk', '--head', '--results'):
        parser.add_argument(flag)
    args = parser.parse_args(argv)
    try:
        api.dispatch_lane(args.trunk, 1, args.head)
    except subprocess.CalledProcessError:
        print('::error::PR #1: could not start its merge run', file=out)
        return 1
    return 0
'''
REARM_STANDS_DOWN = REARM_ALWAYS_DISPATCHES.replace(
    '    try:\n',
    "    if api.get('actions/workflows/lane.yml').get('state') != 'active':\n"
    "        print('lane.yml is not active: nothing to start', file=out)\n"
    "        return 0\n"
    '    try:\n', 1)


class ScenarioTests(unittest.TestCase):
    """What the model says about the pipeline on this tree (SNAPSHOT of 2026-11-20).

    Outcomes that a CI fix would flip are asserted only on a fixture (b4) or as "if it is still stuck, the log names
    this cause", so a fix landing on main never turns these red. Exact outcomes on this tree are the job of
    `ci_model.py --diff`, read by a person, not of a test."""

    def test_a_docs_pr_armed_by_a_person_merges(self):
        result = outcome('a-docs-armed')
        self.assertTrue(result['merged'], ci_model.summary(result))
        self.assertEqual(result['relied_on_schedule'], [])

    def test_b_lane_pr_is_merged_once_audited(self):
        result = outcome('b-lane-no-audit')
        self.assertTrue(result['merged'], ci_model.summary(result))
        self.assertLessEqual(set(result['relied_on_schedule']), {'claude-audit.yml'})

    def test_b2_if_an_outside_audit_leaves_the_pr_stuck_merge_policy_is_why(self):
        result = outcome('b2-lane-audit-from-outside')
        if not result['merged']:
            self.assertIn('merge policy', ' '.join(result['why']))

    def test_b3_if_the_racing_audit_leaves_the_pr_stuck_the_running_policy_is_why(self):
        result = outcome('b3-lane-audit-while-policy-runs')
        if not result['merged']:
            self.assertTrue(logged(result, 'merge policy check still running'), ci_model.summary(result))

    def test_b4_a_failing_rearm_job_stops_the_audit(self):
        """Pinned on a fixture whose lane_rearm.py always dispatches the disabled lane (the defect before #4755)."""
        result = on_fixture('b4-lane-armed-before-checks', {'scripts/lane_rearm.py': REARM_ALWAYS_DISPATCHES})
        self.assertTrue(logged(result, 'rearm: ::error::PR #1: could not start its merge run'), ci_model.summary(result))
        if not result['merged']:
            self.assertTrue(logged(result, 'not audited (checks failed)'), ci_model.summary(result))

    def test_b4_unsticks_when_rearm_stands_down_with_the_lane_off(self):
        result = on_fixture('b4-lane-armed-before-checks', {'scripts/lane_rearm.py': REARM_STANDS_DOWN})
        self.assertTrue(result['merged'], ci_model.summary(result))
        self.assertTrue(logged(result, 'rearm: lane.yml is not active'))

    def test_b4_on_this_tree_either_merges_or_is_stuck_by_the_rearm_job(self):
        result = outcome('b4-lane-armed-before-checks')
        if not result['merged']:
            self.assertTrue(logged(result, 'not audited (checks failed)'), ci_model.summary(result))

    def test_c_a_token_label_still_merges_and_the_label_event_starts_nothing(self):
        for name in ('c-token-label', 'c2-token-label-nominal'):
            result = outcome(name)
            self.assertTrue(result['merged'], name)
            self.assertLessEqual(set(result['relied_on_schedule']), {'merge-queue-label-bridge.yml'}, name)
            self.assertFalse(any('pull_request_target): bridge=' in line and line.startswith('1m')
                                 for line in result['log']), name)  # GITHUB_TOKEN events start no runs (A2)

    def test_d_failed_group_dequeues_and_adds_needs_fix(self):
        result = outcome('d-group-fails')
        self.assertFalse(result['merged'])
        self.assertEqual(result['merge_groups'], 1)
        self.assertIn('needs-fix', result['labels'])
        self.assertNotIn('automerge', result['labels'])

    def test_d2_a_failed_group_never_merges_and_a_requeue_loop_runs_to_the_cap(self):
        result = outcome('d2-group-fails-auto-merge-kept')
        self.assertFalse(result['merged'])
        if result['merge_groups'] > 1:
            self.assertGreaterEqual(result['merge_groups'], ci_model.MAX_GROUPS)

    def test_e_an_app_compile_error_is_caught_before_or_after_merge(self):
        result = outcome('e-app-swift-compile-error')
        if result['merged']:
            self.assertTrue(result['main_broken'], ci_model.summary(result))
        else:
            self.assertTrue(result['why'], ci_model.summary(result))

    def test_f_if_a_token_re_arm_stays_stuck_the_pr_says_why(self):
        result = outcome('f-rearm-by-token-after-fix')
        if not result['merged']:
            self.assertTrue(result['why'], ci_model.summary(result))

    def test_g_owner_tap_pr_merges_after_audit_and_tap(self):
        result = outcome('g-owner-tap-workflow')
        self.assertTrue(result['merged'], ci_model.summary(result))
        self.assertGreaterEqual(result['merged_at_minute'], 600)


class DiffTests(unittest.TestCase):
    def test_a_workflow_change_shows_as_a_changed_outcome(self):
        """A fixture whose label bridge job never runs: the static diff names it and scenario a stops merging."""
        with tempfile.TemporaryDirectory() as tmp:
            path = '.github/workflows/merge-queue-label-bridge.yml'
            doc = yaml.safe_load((ROOT / path).read_text(encoding='utf-8'))
            self.assertIn('bridge', doc['jobs'])
            doc['jobs']['bridge']['if'] = 'false'
            changed = fixture_tree(tmp, {path: yaml.safe_dump(doc, sort_keys=False)})
            self.assertEqual(ci_model.static_diff(TREE.model, changed.model),
                             ['merge-queue-label-bridge.yml bridge: if changed'])
            scenario = next(s for s in ci_model.scenarios() if s.name == 'a-docs-armed')
            after = ci_model.simulate(scenario, changed)
        self.assertFalse(after['merged'], ci_model.summary(after))
        self.assertTrue(outcome('a-docs-armed')['merged'])


if __name__ == '__main__':
    unittest.main()
