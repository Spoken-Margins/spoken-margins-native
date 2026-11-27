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


def evaluate_if(expression, context):
    """A GitHub Actions `if:` built only from `github.*` lookups, string literals, ==, !=, !, && and ||, evaluated
    against <context> (a missing field reads as None, as an absent event field reads empty in Actions)."""
    def lookup(path):
        value = context
        for key in path.split('.')[1:]:
            value = value.get(key) if isinstance(value, dict) else None
        return value
    python = re.sub(r'github(?:\.[A-Za-z_]+)+', lambda m: f'lookup({m.group(0)!r})', expression)
    python = python.replace('&&', ' and ').replace('||', ' or ')
    python = re.sub(r'!(?!=)', ' not ', python)
    return bool(eval(python, {'lookup': lookup}))  # noqa: S307 - our own workflow text, in a test


class OwnerReviewRunsTheMergePolicy(unittest.TestCase):
    """2026-11-24: the owner approved #5212, #5252 and #5256 and all three stayed "Waiting for the owner's tap",
    because merge-policy.yml never ran on a review. His approval of the head is now his tap (scripts/owner_review_tap.py),
    and his review starts the check: only his, only on a same-repository PR into main."""

    @classmethod
    def setUpClass(cls):
        cls.workflow = parse(ROOT / '.github/workflows/merge-policy.yml')
        cls.job = cls.workflow['jobs']['policy']
        import importlib.util
        spec = importlib.util.spec_from_file_location('owner_review_tap_for_workflows', ROOT / 'scripts/owner_review_tap.py')
        cls.rule = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.rule)

    def event(self, name, *, reviewer='uncomposed', repo='o/r', base='main'):
        return {'event_name': name, 'repository': 'o/r',
                'event': {'pull_request': {'number': 7, 'head': {'sha': 'a' * 40, 'repo': {'full_name': repo}},
                                           'base': {'ref': base}},
                          'review': {'user': {'login': reviewer}}}}

    def test_a_submitted_or_dismissed_review_starts_it(self):
        on = next(self.workflow[key] for key in ('on', True, 'true') if key in self.workflow)
        self.assertEqual(on['pull_request_review'], {'types': ['submitted', 'dismissed']})

    def test_only_the_owners_review_on_a_same_repo_pr_into_main_runs_the_job(self):
        condition = self.job['if']
        self.assertIn(f"github.event.review.user.login == '{self.rule.OWNER_LOGIN}'", condition)
        cases = [
            ('the owner reviews', self.event('pull_request_review'), True),
            ('someone else reviews', self.event('pull_request_review', reviewer='pat'), False),
            ('a bot reviews', self.event('pull_request_review', reviewer='github-actions[bot]'), False),
            ('a fork PR is reviewed', self.event('pull_request_review', repo='eve/r'), False),
            ('a PR into another branch', self.event('pull_request_review', base='next'), False),
            ('a same-repo pull_request event', self.event('pull_request', reviewer=None), True),
            ('a fork pull_request event', self.event('pull_request', repo='eve/r'), False),
            ('a merge group', {'event_name': 'merge_group', 'repository': 'o/r', 'event': {}}, True),
            ('a dispatch', {'event_name': 'workflow_dispatch', 'repository': 'o/r', 'event': {}}, True),
        ]
        for name, context, runs in cases:
            with self.subTest(name):
                self.assertEqual(evaluate_if(condition, context), runs)

    def test_a_review_run_reports_on_the_pr_head_with_the_same_token(self):
        step = next(s for s in self.job['steps'] if s.get('name') == 'Check the merge rules')
        # The review event carries the same pull_request object, so these read the PR and its head unchanged.
        self.assertEqual(step['env']['PR'], '${{ github.event.pull_request.number || inputs.pr }}')
        self.assertEqual(step['env']['HEAD_SHA'], '${{ github.event.pull_request.head.sha }}')
        self.assertEqual(self.workflow['permissions'], {'contents': 'read', 'pull-requests': 'read', 'statuses': 'write'})


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


class GuardsRunBeforeTheMacs(unittest.TestCase):
    """2026-11-20 to 11-24: 157 merge groups failed first in `hosted fast: portable` while their Mac jobs ran beside it,
    1,569 hosted-Mac minutes, mostly on repository rule tests. hosted-portable.yml's `guards` job runs those tests first
    in each merge group, every Mac job waits for it, and stop-on-guard-red cancels the run when a guard test fails. No
    result of `guards` skips a Mac job (audit on 089d17c): a skipped required check counts as passed, so a guards red
    whose cancel failed, or a setup flake in `guards`, would have let a group merge with no Mac check."""

    REQUIRED = ('hosted fast: scope', 'hosted fast: portable', 'hosted fast: Mac rest', 'hosted app: build (no tests)')

    @classmethod
    def setUpClass(cls):
        cls.jobs = parse(ROOT / '.github/workflows/hosted-portable.yml')['jobs']

    @staticmethod
    def needs(job):
        needs = job.get('needs', [])
        return [needs] if isinstance(needs, str) else list(needs)

    def test_guards_is_a_linux_job_of_the_merge_group_that_runs_the_guard_list(self):
        guards = self.jobs['guards']
        self.assertEqual(guards['runs-on'], 'ubuntu-latest')
        self.assertEqual(guards['if'].strip(), "github.event_name == 'merge_group'")
        self.assertEqual(self.needs(guards), [], 'it starts at once, beside scope')
        self.assertNotIn('permissions', guards, 'it runs the merge group\'s code with the read-only token')
        self.assertLessEqual(guards['timeout-minutes'], 10)
        runs = [step.get('run', '') for step in guards['steps']]
        self.assertIn('.venv/bin/python scripts/queue_guards.py', runs)

    def test_every_mac_job_waits_for_guards_and_no_guards_result_skips_it(self):
        macs = [name for name, job in self.jobs.items() if not str(job.get('runs-on', '')).startswith('ubuntu')]
        self.assertEqual(sorted(macs), ['app-compile', 'mac-rest', 'sessionkit'])
        for name in macs:
            with self.subTest(job=name):
                job = self.jobs[name]
                self.assertIn('guards', self.needs(job))
                condition = ' '.join(job['if'].split())
                # !cancelled() lets the job run whatever `guards` ended with (skipped on every PR push, failed in a
                # setup step or a test); only the run's cancel stops it, and a failed cancel leaves the Macs running.
                self.assertTrue(condition.startswith('!cancelled() && '), condition)
                self.assertNotIn('needs.guards', condition)

    def test_only_a_failed_guard_test_step_cancels_the_run(self):
        guards = self.jobs['guards']
        tests = [step for step in guards['steps'] if step.get('run') == '.venv/bin/python scripts/queue_guards.py']
        self.assertEqual(len(tests), 1)
        # A step that never ran (checkout, setup-python or Python tools failed) has an empty outcome: not red.
        self.assertEqual(' '.join(str(guards['outputs']['red']).split()),
                         "${{ steps.%s.outcome == 'failure' }}" % tests[0]['id'])
        stop = self.jobs['stop-on-guard-red']
        self.assertEqual(self.needs(stop), ['guards'])
        self.assertEqual(stop['runs-on'], 'ubuntu-latest')
        self.assertEqual(stop['permissions'], {'actions': 'write'})
        self.assertEqual(' '.join(stop['if'].split()), "always() && needs.guards.outputs.red == 'true'")
        self.assertIn('gh run cancel', stop['steps'][0]['run'])

    def test_rearm_still_waits_for_every_other_job(self):
        self.assertEqual(sorted(self.needs(self.jobs['rearm'])), sorted(name for name in self.jobs if name != 'rearm'))

    def test_the_required_check_names_are_all_still_here_and_guards_is_not_one(self):
        names = {job.get('name') for job in self.jobs.values()}
        for required in self.REQUIRED:
            self.assertIn(required, names)
        self.assertEqual(self.jobs['guards']['name'], 'hosted fast: guards')


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
    branches, which can't use the main-only environment, so it stays on GITHUB_TOKEN; claude-audit.yml mints in its
    own environment (ClaudeAuditReadsAsTheApp)."""

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


class ClaudeAuditReadsAsTheApp(unittest.TestCase):
    """#5217: claude-audit read the API with GITHUB_TOKEN, whose 1,000 requests an hour for the repository ran out. It
    mints the App token and reads with it; writes stay on GITHUB_TOKEN (SM_WRITE_TOKEN). Claude never gets either."""

    def steps(self):
        return parse(ROOT / '.github/workflows/claude-audit.yml')['jobs']['audit']['steps']

    def test_the_audit_step_reads_as_the_app_and_writes_as_the_workflow(self):
        steps = self.steps()
        mint = next(i for i, s in enumerate(steps) if is_app_token_mint_only(s))
        audit = next(i for i, s in enumerate(steps) if s.get('name') == 'Audit')
        self.assertLess(mint, audit)
        self.assertEqual(steps[mint].get('id'), 'app-token')
        self.assertIs(steps[mint].get('continue-on-error'), True, 'a failed mint must fall back, not fail')
        permissions = {k for k in steps[mint]['with'] if k.startswith('permission-')}
        self.assertTrue(permissions, 'the App token must be narrowed')
        for name in permissions:
            self.assertEqual(steps[mint]['with'][name], 'read', f'{name}: the App token only reads')
        env = steps[audit]['env']
        self.assertEqual(env['GH_TOKEN'].replace(' ', ''), '${{steps.app-token.outputs.token||github.token}}')
        self.assertEqual(env['SM_WRITE_TOKEN'].replace(' ', ''), '${{github.token}}')

    def test_the_app_token_reaches_no_other_step(self):
        for step in self.steps():
            if step.get('name') != 'Audit':
                self.assertNotIn('app-token', json.dumps(step.get('env', {})) + str(step.get('run', '')))

    def test_the_job_keeps_its_environment(self):
        self.assertEqual(parse(ROOT / '.github/workflows/claude-audit.yml')['jobs']['audit']['environment'],
                         'claude-audit')
