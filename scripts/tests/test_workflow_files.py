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


TEST_COMMAND = re.compile(r'\b(xcodebuild|swift test|verify-tests\.py|sm_integration_run\.py|hosted_t3_check\.py|lane-runner\.py)\b')
IGNORES_FAILURE = re.compile(r'\|\|\s*(true|:)\s*$')
# check-build29-database.sh runs `swift test` for its fixture writer, so a job that calls it runs a test (shipped-build-compat).
TEST_RUNNING = re.compile(r'test-without-building|verify-tests|swift test|unittest|sm_integration_run|hosted_t3_check|check-build29-database')

# Steps allowed to carry continue-on-error: true, by (workflow file, job id). Each one is a ping or a report-of-a-report
# that is not a test result ("Not a lane result: a failure here must not make the run look red" in lane.yml).
# A new entry here needs the same kind of reason; a test or build step never belongs on this list.
# A cache-only step (`uses: actions/cache/...`, no `run:`) may carry it in any job.
CONTINUE_ON_ERROR_ALLOWED = {
    ('lane.yml', 'lane-lost'),
    ('lane.yml', 'lane-open-lane'),
    ('lane.yml', 'lane-open-automerge'),
}


def is_cache_restore_only(step):
    """A step that only restores or saves a cache (`uses: actions/cache/...`, no `run:`). A failed restore must cost a
    cold build, never a red check (hosted-app-macos.yml, #2617); it runs no test, so it can't hide a failed one."""
    return str(step.get('uses', '')).startswith('actions/cache/') and 'run' not in step


def continue_on_error_violations(documents):
    """Messages for each job or step in `documents` ({workflow file name: parsed workflow}) that carries
    `continue-on-error: true` where it could turn a failed test into a green check."""
    found = []
    for name, document in documents.items():
        for job_id, job in document['jobs'].items():
            where = (name, job_id)
            steps = job.get('steps', [])
            flagged = job.get('continue-on-error') is True or any(
                step.get('continue-on-error') is True and not is_cache_restore_only(step) for step in steps)
            if flagged and where not in CONTINUE_ON_ERROR_ALLOWED:
                found.append(f'{where}: continue-on-error: true can turn a failed test into a green check')
            if flagged:
                found.extend(f'{where}: a test or build step must not continue on error' for step in steps
                             if TEST_RUNNING.search(step.get('run', '')) and step.get('continue-on-error') is True)
    return found


def logical_lines(script):
    """A script's lines with backslash continuations joined, so a pipeline over several lines is one line."""
    return re.sub(r'\\\n\s*', ' ', script).splitlines()


def all_steps():
    """(workflow file name, job id, job, step) for every step of every workflow."""
    for path in WORKFLOWS:
        for job_id, job in parse(path)['jobs'].items():
            for step in job.get('steps', []):
                yield path.name, job_id, job, step


class WorkflowHonesty(unittest.TestCase):
    """A check that is green must have tested what its name says (#2596). These rules catch the ways it was not."""

    def test_a_verdict_step_never_exits_zero_and_fails_an_inconclusive_that_is_not_a_hold(self):
        gating = 0
        for name, job_id, _, step in all_steps():
            if step.get('name') != 'Verdict' or 'INCONCLUSIVE' not in step.get('run', ''):
                continue
            gating += 1
            script = step['run']
            with self.subTest(workflow=name, job=job_id):
                self.assertNotRegex(script, r'\bexit 0\b', 'a Verdict step must not end the job green early')
                branch = re.search(r'INCONCLUSIVE\s*\][^\n]*\n?\s*then(.*?)(?:\n\s*elif|\n\s*else|\n\s*fi)', script, re.S)
                self.assertIsNotNone(branch, 'no branch for INCONCLUSIVE')
                self.assertIn('exit 1', branch.group(1), 'INCONCLUSIVE (not a hold) must make the check red')
        self.assertGreaterEqual(gating, 3, 'lane, automerge and automerge-mac Verdict steps gate on INCONCLUSIVE')

    def test_continue_on_error_is_only_on_the_listed_ping_and_report_jobs(self):
        documents = {path.name: parse(path) for path in WORKFLOWS}
        self.assertEqual(continue_on_error_violations(documents), [])

    def test_a_pr_adding_a_forbidden_continue_on_error_is_red(self):
        # #2641 added it to the lane's cache steps, its checks were green, and `main` went red (#2711, #2714). The rule
        # above, applied to the workflows as that PR would have left them, must fail for it.
        lane = parse(ROOT / '.github/workflows/lane.yml')
        step = next(step for step in lane['jobs']['lane']['steps'] if step.get('run'))
        step['continue-on-error'] = True
        found = continue_on_error_violations({'lane.yml': lane})
        self.assertTrue(any("('lane.yml', 'lane')" in message for message in found), found)
        # Job level, on a job that is not listed.
        lane = parse(ROOT / '.github/workflows/lane.yml')
        lane['jobs']['lane']['continue-on-error'] = True
        self.assertTrue(continue_on_error_violations({'lane.yml': lane}))

    def test_the_listed_jobs_and_cache_only_steps_are_allowed_but_a_test_step_on_a_listed_job_is_not(self):
        listed = {'lane.yml': {'jobs': {'lane-lost': {'continue-on-error': True, 'steps': [{'run': 'echo ping'}]}}}}
        self.assertEqual(continue_on_error_violations(listed), [])
        cache = {'x.yml': {'jobs': {'job': {'steps': [{'uses': 'actions/cache/restore@v4', 'continue-on-error': True}]}}}}
        self.assertEqual(continue_on_error_violations(cache), [])
        tests = {'lane.yml': {'jobs': {'lane-lost': {'steps': [
            {'run': 'python3 scripts/verify-tests.py --plan fast', 'continue-on-error': True}]}}}}
        self.assertTrue(continue_on_error_violations(tests))

    def test_a_build_or_test_command_that_ignores_its_exit_status_is_checked_after_it(self):
        # `xcodebuild ... | tee | grep ... || true` keeps a build from dying in the pipe, but the step must then
        # prove the success marker itself (`grep -q 'BUILD SUCCEEDED' log`), or a failed build passes.
        seen = 0
        for name, job_id, _, step in all_steps():
            script = step.get('run', '')
            for line in logical_lines(script):
                if TEST_COMMAND.search(line) and IGNORES_FAILURE.search(line.strip()):
                    seen += 1
                    with self.subTest(workflow=name, job=job_id, step=step.get('name')):
                        self.assertRegex(script, r'grep -q[F]? [^\n]*(SUCCEEDED|passed)',
                                         'no success check after a command whose exit status is ignored')
        self.assertGreaterEqual(seen, 4, 'the build steps of hosted-app-macos and phone-build use this pattern')

    def test_the_hosted_app_check_says_it_builds_and_runs_no_tests_unless_asked(self):
        job = parse(ROOT / '.github/workflows/hosted-app-macos.yml')['jobs']['app']
        self.assertRegex(job.get('name', ''), r'build.*tests only when asked')

    def test_a_job_that_only_builds_has_build_in_its_name(self):
        for path in WORKFLOWS:
            for job_id, job in parse(path)['jobs'].items():
                scripts = '\n'.join(step.get('run', '') for step in job.get('steps', []))
                if re.search(r'\bxcodebuild\b', scripts) and not TEST_RUNNING.search(scripts):
                    with self.subTest(workflow=path.name, job=job_id):
                        self.assertRegex(str(job.get('name', job_id)).lower(), r'build|archive|phone',
                                         'a job that only builds must not be named like a test result')

    def test_hosted_t3_still_reconciles_its_tests_whatever_the_earlier_steps_did(self):
        steps = parse(ROOT / '.github/workflows/hosted-app-macos.yml')['jobs']['app']['steps']
        reconcile = [step for step in steps if 'hosted_t3_check.py reconcile' in step.get('run', '')]
        self.assertEqual(len(reconcile), 1)
        self.assertIn('always()', reconcile[0].get('if', ''))
        self.assertIsNot(reconcile[0].get('continue-on-error'), True)

    def test_the_rules_notice_a_dishonest_step(self):
        # The rules above, applied to made-up text, so a weakened rule fails here.
        self.assertTrue(IGNORES_FAILURE.search('xcodebuild build | tee log | grep BUILD || true'))
        self.assertTrue(TEST_COMMAND.search(logical_lines('xcodebuild -scheme X \\\n  build | grep BUILD || true')[0]))
        self.assertIsNone(re.search(r'grep -q[F]? [^\n]*(SUCCEEDED|passed)', 'xcodebuild build | grep BUILD || true'))


if __name__ == '__main__':
    unittest.main()
