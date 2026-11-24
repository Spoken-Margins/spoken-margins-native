"""Every workflow file is valid YAML, and no green check hides a failed test (#2596).

PR #2604 deleted the `env:` line above `VERDICT:` and `HELD:` in two Verdict steps. The file was no longer
valid YAML, GitHub rejected the whole workflow, and no test noticed because the others read lane.yml as text.

Parse every .github/workflows/*.yml with a real YAML parser (PyYAML if installed, otherwise Ruby's, which macOS
and the hosted Linux images carry). If neither exists the test fails: a skipped parse is a hole. The lane's own
Verdict-step checks went with lane.yml (#4769).
"""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path
from unittest import mock

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


TEST_COMMAND = re.compile(r'\b(xcodebuild|swift test|verify-tests\.py|sm_integration_run\.py|hosted_t3_check\.py)\b')
IGNORES_FAILURE = re.compile(r'\|\|\s*(true|:)\s*$')
# check-build29-database.sh runs `swift test` for its fixture writer, so a job that calls it runs a test (shipped-build-compat).
TEST_RUNNING = re.compile(r'test-without-building|verify-tests|swift test|unittest|sm_integration_run|hosted_t3_check|check-build29-database|(?:main|branch)_t3\.py run')
# main_t3.py and branch_t3.py `run` drive lane-runner.py's T3 on a simulator clone (#4839), so a job that calls them runs tests.

# Jobs allowed to carry continue-on-error: true, by (workflow file, job id). Each one must be a ping or a
# report-of-a-report that is not a test result; lane.yml's three went with it (#4769). A new entry here needs the same
# kind of reason; a test or build step never belongs on this list.
# A cache-only step (`uses: actions/cache/...`, no `run:`) may carry it in any job.
CONTINUE_ON_ERROR_ALLOWED = set()


def is_cache_restore_only(step):
    """A step that only restores or saves a cache (`uses: actions/cache/...`, no `run:`). A failed restore must cost a
    cold build, never a red check (hosted-app-macos.yml, #2617); it runs no test, so it can't hide a failed one."""
    return str(step.get('uses', '')).startswith('actions/cache/') and 'run' not in step


def is_app_token_mint_only(step):
    """A step that only mints a GitHub App token (`uses: actions/create-github-app-token`, no `run:`). A failed mint
    must fall back to the next token, never fail the job (merge-queue-label-bridge.yml, #4915); it runs no test."""
    return str(step.get('uses', '')).startswith('actions/create-github-app-token') and 'run' not in step


def continue_on_error_violations(documents):
    """Messages for each job or step in `documents` ({workflow file name: parsed workflow}) that carries
    `continue-on-error: true` where it could turn a failed test into a green check."""
    found = []
    for name, document in documents.items():
        for job_id, job in document['jobs'].items():
            where = (name, job_id)
            steps = job.get('steps', [])
            flagged = job.get('continue-on-error') is True or any(
                step.get('continue-on-error') is True and not is_cache_restore_only(step) and not is_app_token_mint_only(step)
                for step in steps)
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

    def test_continue_on_error_is_only_on_the_listed_ping_and_report_jobs(self):
        documents = {path.name: parse(path) for path in WORKFLOWS}
        self.assertEqual(continue_on_error_violations(documents), [])

    def test_a_pr_adding_a_forbidden_continue_on_error_is_red(self):
        # #2641 added it to the lane's cache steps, its checks were green, and `main` went red (#2711, #2714). The rule
        # above, applied to the workflows as that PR would have left them, must fail for it.
        # main-t3.yml stands in for the lane's workflow, retired with it (#4769).
        workflow = parse(ROOT / '.github/workflows/main-t3.yml')
        job_id, job = next((job_id, job) for job_id, job in workflow['jobs'].items()
                           if any(step.get('run') for step in job.get('steps', [])))
        step = next(step for step in job['steps'] if step.get('run'))
        step['continue-on-error'] = True
        found = continue_on_error_violations({'main-t3.yml': workflow})
        self.assertTrue(any(f"('main-t3.yml', '{job_id}')" in message for message in found), found)
        # Job level, on a job that is not listed.
        workflow = parse(ROOT / '.github/workflows/main-t3.yml')
        workflow['jobs'][job_id]['continue-on-error'] = True
        self.assertTrue(continue_on_error_violations({'main-t3.yml': workflow}))

    def test_the_listed_jobs_and_cache_only_steps_are_allowed_but_a_test_step_on_a_listed_job_is_not(self):
        cache = {'x.yml': {'jobs': {'job': {'steps': [{'uses': 'actions/cache/restore@v4', 'continue-on-error': True}]}}}}
        self.assertEqual(continue_on_error_violations(cache), [])
        with mock.patch.dict(globals(), CONTINUE_ON_ERROR_ALLOWED={('x.yml', 'ping')}):
            listed = {'x.yml': {'jobs': {'ping': {'continue-on-error': True, 'steps': [{'run': 'echo ping'}]}}}}
            self.assertEqual(continue_on_error_violations(listed), [])
            tests = {'x.yml': {'jobs': {'ping': {'steps': [
                {'run': 'python3 scripts/verify-tests.py --plan fast', 'continue-on-error': True}]}}}}
            self.assertTrue(continue_on_error_violations(tests))

    def test_a_mint_only_step_may_continue_on_error_but_a_run_beside_it_may_not(self):
        mint = {'x.yml': {'jobs': {'job': {'steps': [
            {'uses': 'actions/create-github-app-token@f418cff399f7aef4c2f0ad47e25ca7a6abbdd6fc', 'continue-on-error': True}]}}}}
        self.assertEqual(continue_on_error_violations(mint), [])
        mint['x.yml']['jobs']['job']['steps'][0]['run'] = 'python3 scripts/verify-tests.py --plan fast'
        self.assertTrue(continue_on_error_violations(mint))

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


class QueueActsAsTheApp(unittest.TestCase):
    """#4915: the queue's PAT (MERGE_QUEUE_TOKEN) had no `workflow` scope, so GitHub refused to queue PRs that edit a
    workflow file (#5189, #5106, #5151), and its merges showed as the owner. The jobs that set PRs to merge mint the
    spoken-margins-agent App token first, with `workflows: write`, and fall back to the PAT, then GITHUB_TOKEN."""

    CASES = {
        'merge-queue-label-bridge.yml': ('bridge', 'Queue or unqueue', 'GH_TOKEN'),
        'merge-queue-dequeued.yml': ('dequeued', 'Tell the author, cancel dead group runs', 'QUEUE_TOKEN'),
    }

    def test_each_queueing_job_mints_the_app_token_before_it_queues(self):
        for name, (job_id, step_name, var) in self.CASES.items():
            with self.subTest(workflow=name):
                job = parse(ROOT / '.github/workflows' / name)['jobs'][job_id]
                self.assertEqual(job['environment'], {'name': 'agent-identity', 'deployment': False})
                steps = job['steps']
                mint = next(i for i, s in enumerate(steps) if is_app_token_mint_only(s))
                queue = next(i for i, s in enumerate(steps) if s.get('name') == step_name)
                self.assertLess(mint, queue, 'the App token must be minted before the step that queues')
                self.assertEqual(steps[mint].get('id'), 'app-token')
                self.assertIs(steps[mint].get('continue-on-error'), True, 'a failed mint must fall back, not fail')
                self.assertEqual(steps[mint]['with'].get('permission-workflows'), 'write')
                token = steps[queue]['env'][var].replace(' ', '')
                self.assertTrue(token.startswith('${{steps.app-token.outputs.token||secrets.MERGE_QUEUE_TOKEN'),
                                token)


class DeployWaitAlertStep(unittest.TestCase):
    """#5255: a deploy waiting for the owner's approval gave him no alert (deploy-web sat `waiting` all of 2026-11-23).
    owner-tap-alert.yml's scheduled run also runs scripts/deploy_wait_alert.py, as github-actions[bot]."""

    def setUp(self):
        self.document = parse(ROOT / '.github/workflows/owner-tap-alert.yml')
        self.step = next((s for s in self.document['jobs']['alert']['steps']
                          if 'deploy_wait_alert.py' in (s.get('run') or '')), None)

    def test_step_exists_on_the_schedule_and_runs_the_script(self):
        self.assertIsNotNone(self.step, 'owner-tap-alert.yml must run scripts/deploy_wait_alert.py')
        self.assertIn("github.event_name == 'schedule'", self.step['if'])
        self.assertNotIn('pull_request', self.step['if'])
        self.assertTrue((ROOT / 'scripts/deploy_wait_alert.py').is_file())

    def test_script_is_in_the_sparse_checkout(self):
        checkout = self.document['jobs']['alert']['steps'][0]
        self.assertIn('scripts/deploy_wait_alert.py', checkout['with']['sparse-checkout'].split())

    def test_permissions_and_token_let_the_bot_read_runs_and_write_comments(self):
        permissions = self.document['permissions']
        self.assertEqual(permissions.get('actions'), 'read')
        self.assertEqual(permissions.get('issues'), 'write')
        self.assertEqual(self.step['env']['GH_TOKEN'].replace(' ', ''), '${{github.token}}')


class ReadersUseTheAppBudget(unittest.TestCase):
    """#5217: GITHUB_TOKEN's 1,000 requests an hour for the repository ran out on 2026-11-23 and the last three main-t3
    runs failed on `commits/<sha>/statuses`. The readers that run in main's context mint the App token (its own, larger
    budget) with read-only permissions and fall back to GITHUB_TOKEN. merge-policy.yml runs on pull_request from PR
    branches, which can't use the main-only environment, so it stays on GITHUB_TOKEN; claude-audit.yml already has its
    own environment and stays too."""

    CASES = {
        'main-t3.yml': ('decide', 'Decide'),
        'merge-stall.yml': ('watch', 'Look for a stall'),
    }

    def test_each_reader_mints_a_read_only_token_first_and_falls_back(self):
        for name, (job_id, step_name) in self.CASES.items():
            with self.subTest(workflow=name):
                job = parse(ROOT / '.github/workflows' / name)['jobs'][job_id]
                self.assertEqual(job['environment'], {'name': 'agent-identity', 'deployment': False})
                steps = job['steps']
                self.assertTrue(is_app_token_mint_only(steps[0]), 'mint before anything that calls the API')
                self.assertEqual(steps[0].get('id'), 'app-token')
                self.assertIs(steps[0].get('continue-on-error'), True, 'a failed mint must fall back, not fail')
                granted = {k: v for k, v in steps[0]['with'].items() if k.startswith('permission-')}
                self.assertTrue(granted)
                self.assertEqual(set(granted.values()), {'read'}, granted)
                env = next(s for s in steps if s.get('name') == step_name)['env']
                self.assertEqual(env['GH_TOKEN'].replace(' ', ''), '${{steps.app-token.outputs.token||github.token}}')

    def test_the_app_token_never_reaches_a_checkout(self):
        for name, (job_id, _) in self.CASES.items():
            with self.subTest(workflow=name):
                for step in parse(ROOT / '.github/workflows' / name)['jobs'][job_id]['steps']:
                    if str(step.get('uses', '')).startswith('actions/checkout'):
                        self.assertNotIn('app-token', str(step))

    def test_the_alarm_issue_is_still_written_with_the_workflow_token(self):
        steps = parse(ROOT / '.github/workflows/merge-stall.yml')['jobs']['watch']['steps']
        look = next(s for s in steps if s.get('name') == 'Look for a stall')
        self.assertEqual(look['env']['SM_WRITE_TOKEN'], '${{ github.token }}')
        budget = next(s for s in steps if s.get('name') == 'Read the API budget')
        self.assertEqual(budget['env']['GH_TOKEN'], '${{ github.token }}', "it watches that token's budget")

    def test_the_main_t3_job_that_writes_stays_on_the_workflow_token(self):
        job = parse(ROOT / '.github/workflows/main-t3.yml')['jobs']['t3']
        self.assertEqual(job['env']['GH_TOKEN'], '${{ github.token }}')
        self.assertNotIn('environment', job)
