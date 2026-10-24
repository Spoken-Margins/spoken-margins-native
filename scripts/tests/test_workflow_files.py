"""Every workflow file is valid YAML, and each lane Verdict step really gets its inputs (#2596).

PR #2604 deleted the `env:` line above `VERDICT:` and `HELD:` in two Verdict steps. The file was no longer
valid YAML, GitHub rejected the whole workflow, and no test noticed because the others read lane.yml as text.

Two checks:

1. Parse every .github/workflows/*.yml with a real YAML parser (PyYAML if installed, otherwise Ruby's, which
   macOS and the hosted Linux images carry). If neither exists the test fails: a skipped parse is a hole.
2. In lane.yml, every step named Verdict has an `env` map holding every one of VERDICT and HELD that its script reads, and a text check that does
   not need a parser sees the same thing (the `env:` line sits above its keys, at the step's key indent).
"""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = sorted((ROOT / '.github/workflows').glob('*.yml'))

RUBY_DUMP = 'require "yaml"; require "json"; puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))'


def parse(path):
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        return yaml.safe_load(path.read_text())
    ruby = shutil.which('ruby')
    if ruby is None:
        raise AssertionError('no YAML parser: install PyYAML or Ruby so workflow files are really parsed')
    done = subprocess.run([ruby, '-e', RUBY_DUMP, str(path)], capture_output=True, text=True)
    if done.returncode != 0:
        raise AssertionError(f'{path.name} is not valid YAML: {done.stderr.strip()[:400]}')
    return json.loads(done.stdout)


def used_inputs(script):
    """The Verdict inputs a script reads as shell variables ($VERDICT, ${HELD})."""
    return [name for name in ('VERDICT', 'HELD') if re.search(r'\$\{?' + name + r'\b', script)]


def verdict_steps_in_text(text):
    """(line number, step lines) for each `- name: Verdict` step, the step ending at the next line indented no further than its dash."""
    lines = text.splitlines()
    found = []
    for index, line in enumerate(lines):
        match = re.match(r'^(\s*)- name: Verdict\s*$', line)
        if not match:
            continue
        dash = len(match.group(1))
        end = index + 1
        while end < len(lines) and (not lines[end].strip() or len(lines[end]) - len(lines[end].lstrip()) > dash):
            end += 1
        found.append((index + 1, lines[index:end]))
    return found


def env_keys_in_step_text(step_lines):
    """Keys listed under a step-level `env:` line, or None when the step has no such line."""
    key_indent = len(step_lines[0]) - len(step_lines[0].lstrip()) + 2
    for position, line in enumerate(step_lines):
        if re.match(r'^\s*env:\s*$', line) and len(line) - len(line.lstrip()) == key_indent:
            keys = []
            for after in step_lines[position + 1:]:
                if after.strip() and len(after) - len(after.lstrip()) <= key_indent:
                    break
                found = re.match(r'^\s+([A-Z_][A-Z0-9_]*):', after)
                if found:
                    keys.append(found.group(1))
            return keys
    return None


class WorkflowFilesParse(unittest.TestCase):
    def test_there_are_workflow_files_to_check(self):
        self.assertGreaterEqual(len(WORKFLOWS), 5)

    def test_every_workflow_file_is_valid_yaml_with_jobs(self):
        for path in WORKFLOWS:
            with self.subTest(workflow=path.name):
                document = parse(path)
                self.assertIsInstance(document, dict, f'{path.name} is not a mapping')
                self.assertIsInstance(document.get('jobs'), dict, f'{path.name} has no jobs')
                for job_name, job in document['jobs'].items():
                    self.assertIsInstance(job, dict, f'{path.name} job {job_name} is not a mapping')


class AlwaysOnCheck(unittest.TestCase):
    """workflow-files.yml is the check that notices a broken workflow, so nothing may be able to skip it."""

    def test_it_runs_on_every_pull_request_and_needs_nothing(self):
        document = parse(ROOT / '.github/workflows/workflow-files.yml')
        triggers = next(document[key] for key in ('on', True, 'true') if key in document)  # YAML 1.1 reads `on` as true
        pull_request = triggers['pull_request']
        for key in ('paths', 'paths-ignore'):
            self.assertNotIn(key, pull_request, f'a {key} filter could skip the check on a PR')
        self.assertIn('workflow_dispatch', triggers)
        for name, job in document['jobs'].items():
            self.assertNotIn('needs', job, f'{name} waits on another job')
            self.assertNotIn('vars.', str(job.get('if', '')), f'{name} is switched by a repository variable')
        steps = ' '.join(str(step.get('run', '')) for job in document['jobs'].values() for step in job['steps'])
        self.assertIn('scripts/tests/test_workflow_files.py', steps)


class LaneVerdictSteps(unittest.TestCase):
    TEXT = (ROOT / '.github/workflows/lane.yml').read_text()

    def test_each_verdict_step_has_env_with_verdict_and_held(self):
        jobs = parse(ROOT / '.github/workflows/lane.yml')['jobs']
        seen = 0
        for job_name, job in jobs.items():
            for step in job.get('steps', []):
                if step.get('name') != 'Verdict':
                    continue
                seen += 1
                with self.subTest(job=job_name):
                    self.assertIsInstance(step.get('env'), dict, f'{job_name}: Verdict step has no env map')
                    for name in used_inputs(step.get('run', '')):
                        self.assertIn(name, step['env'], f'{job_name}: Verdict step reads ${name} but env lacks it')
                    self.assertIn('VERDICT', step['env'])
        self.assertGreaterEqual(seen, 4, 'lane, automerge, automerge-mac and release each have a Verdict step')

    def test_the_text_check_sees_the_same_thing_without_a_parser(self):
        steps = verdict_steps_in_text(self.TEXT)
        self.assertGreaterEqual(len(steps), 4)
        for number, step_lines in steps:
            with self.subTest(line=number):
                keys = env_keys_in_step_text(step_lines)
                self.assertIsNotNone(keys, f'Verdict step at line {number} has no env: line')
                self.assertIn('VERDICT', keys)
                for name in used_inputs('\n'.join(step_lines)):
                    self.assertIn(name, keys, f'Verdict step at line {number} reads ${name} but env lacks it')

    def test_the_text_check_notices_the_2604_breakage(self):
        broken = self.TEXT.replace("        if: steps.run.outputs.reported == 'true'\n        env:\n          VERDICT:",
                                   "        if: steps.run.outputs.reported == 'true'\n          VERDICT:", 1)
        self.assertNotEqual(broken, self.TEXT, 'the sample no longer matches lane.yml; update this test')
        missing = [number for number, lines in verdict_steps_in_text(broken) if env_keys_in_step_text(lines) is None]
        self.assertEqual(len(missing), 1)


if __name__ == '__main__':
    unittest.main()
