"""The helpers that read workflows as parsed YAML (#3704) can tell a guard from a comment that names it."""
from __future__ import annotations

import unittest

import yaml

import workflow_yaml as W

GUARD = "github.event_name != 'workflow_run' || github.event.workflow_run.conclusion != 'skipped'"


def run(condition, event, conclusion=''):
    return W.evaluate_condition(condition, github_event_name=event, github_event_workflow_run_conclusion=conclusion)


class ConditionTests(unittest.TestCase):
    def test_the_real_guard_skips_only_a_skipped_workflow_run(self):
        self.assertFalse(run(GUARD, 'workflow_run', 'skipped'))
        self.assertTrue(run(GUARD, 'workflow_run', 'success'))
        self.assertTrue(run(GUARD, 'schedule'))

    def test_a_guard_replaced_by_true_or_hidden_in_a_comment_is_not_a_guard(self):
        for text in (f'if: true  # {GUARD}', f"if: true\n# {GUARD}"):
            with self.subTest(text=text):
                condition = yaml.safe_load('job:\n  ' + text.replace('\n', '\n  '))['job'].get('if', True)
                self.assertTrue(run(condition, 'workflow_run', 'skipped'))

    def test_negation_and_expression_wrappers(self):
        self.assertFalse(W.evaluate_condition('${{ !(a.b == \'x\') }}', a_b='x'))
        self.assertTrue(W.evaluate_condition("a.b == 'x' && !(c.d == 'y')", a_b='x', c_d='z'))

    def test_a_condition_with_a_function_call_is_refused_not_guessed(self):
        with self.assertRaises(AssertionError):
            W.evaluate_condition("contains(a.b, 'x')", a_b='xy')


class SecretTests(unittest.TestCase):
    def named(self, text):
        return W.mentions_of(yaml.safe_load(text), 'secrets')

    def test_each_way_to_name_a_secret_is_found_and_a_comment_is_not(self):
        base = 'jobs:\n  j:\n    steps:\n      - name: Install\n        env:\n          ALL: %s\n'
        for value in ('${{ secrets.TOKEN }}', "${{ secrets['TOKEN'] }}", '${{ toJSON(secrets) }}'):
            with self.subTest(value=value):
                self.assertEqual(len(self.named(base % value)), 1)
        self.assertEqual(len(self.named(base % '${{ SECRETS.TOKEN }}')), 1)  # context names ignore case
        self.assertEqual(len(self.named('jobs:\n  j:\n    uses: ./x.yml\n    secrets: inherit\n')), 1)
        self.assertEqual(self.named(base % 'x  # secrets.TOKEN is not used here'), [])
        self.assertEqual(self.named('jobs:\n  j:\n    steps:\n      - run: echo hi # secrets.X\n'), [])


class PermissionTests(unittest.TestCase):
    def test_a_jobs_own_block_replaces_the_workflows(self):
        workflow = yaml.safe_load('permissions:\n  statuses: write\n  contents: read\n'
                                  'jobs:\n  a: {}\n  b:\n    permissions:\n      contents: write\n')
        self.assertEqual(W.effective_permissions(workflow, 'a'), {'statuses': 'write', 'contents': 'read'})
        self.assertEqual(W.effective_permissions(workflow, 'b'), {'contents': 'write'})

    def test_the_repositorys_workflows_parse(self):
        self.assertIn('release', W.load('lane.yml')['jobs'])
        self.assertTrue(W.checkout_steps(W.load('lane.yml')))


if __name__ == '__main__':
    unittest.main()
