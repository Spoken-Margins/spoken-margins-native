"""/lane T2 and T3 requests run on a GitHub-hosted Mac once LANE_HOSTED_APP is `on` (#1389 phase 2).

Over the three days to 2026-10-18 the Mac spent about 21 hours on 122 T3 runs (about 7 a day). What these tests guard:
with the switch unset nothing changes, with it on only the lane job moves (never the automerge job, which merges),
the hosted-only workflow steps can never run on the Mac, the PR's own setup script never sees the token, and a
hosted report says where its evidence went.
"""
import importlib
import os
from pathlib import Path
import subprocess
import sys
import json
import re
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_lane_runner import lane  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts'
sys.path.insert(0, str(SCRIPTS))
scope = importlib.import_module('test-scope')
NORMAL = {'lane': ['self-hosted', 'macOS', 'sm-lane'], 'automerge': ['self-hosted', 'macOS', 'sm-lane-build']}
HOSTED = 'github-hosted'


WORKFLOW = (ROOT / '.github/workflows/lane.yml').read_text()


def job(name):
    """A job's text in lane.yml, from its key to the next job's."""
    text = WORKFLOW.split(f'\n  {name}:\n', 1)[1]
    return re.split(r'\n  [a-z]+:\n', text, 1)[0]


def steps(name='lane'):
    """Each step's text in a job, in order (no YAML parser in the lane's tools)."""
    return ['- ' + part for part in ('\n' + job(name).split('\n    steps:\n', 1)[1]).split('\n      - ')[1:]] \
        if '\n    steps:\n' in job(name) else []


def step(title, name='lane'):
    return next(text for text in steps(name) if f'name: {title}' in text.splitlines()[0])


def condition(text):
    found = re.search(r'^\s+if: (.*)$', text, re.M)
    return found.group(1) if found else ''


class HostedToolTests(unittest.TestCase):
    def test_the_hosted_mac_gets_xcodegen_before_the_run(self):
        # #2557: verify-tests.py runs `xcodegen generate` before a T3 build; the image has none, so every hosted T3
        # was INCONCLUSIVE ("No such file or directory: 'xcodegen'") and held its PR's merge.
        titles = [text.splitlines()[0] for text in steps()]
        found = [text for text in steps() if 'xcodegen' in text and 'brew install xcodegen' in text]
        self.assertEqual(len(found), 1, 'one step installs XcodeGen on the hosted Mac')
        self.assertEqual(condition(found[0]), "runner.environment == 'github-hosted'", 'never on the build Macs')
        self.assertLess(titles.index(found[0].splitlines()[0]), titles.index(next(t for t in titles if 'Run the request' in t)))

    def test_the_hosted_mac_gets_a_crash_report_folder(self):
        # #2557 audit: verify-tests.py raises "Simulator crash reports are unavailable" when ~/Library/Logs/DiagnosticReports
        # is missing, and a fresh hosted Mac has none. The step that makes the lane folders makes it, hosted only.
        folders = step('Hosted Mac - lane folders, Xcode and the iOS runtime')
        self.assertEqual(condition(folders), "runner.environment == 'github-hosted'")
        self.assertIn('mkdir -p "$HOME/Library/Logs/DiagnosticReports"', folders)

    def test_the_lane_runs_on_python_3_12_on_the_hosted_mac_only(self):
        # #2545 / #2557 audit: /usr/bin/python3 on the image is 3.9; setup-python's 3.12 is `python3` on PATH.
        titles = [text.splitlines()[0] for text in steps()]
        for title in ('Run the request', 'Tidy up after a cancelled or failed run'):
            with self.subTest(step=title):
                text = step(title)
                self.assertIn("LANE_PYTHON: ${{ runner.environment == 'github-hosted' && 'python3' || '/usr/bin/python3' }}", text)
                self.assertIn('"$LANE_PYTHON" "$RUNNER_TEMP/lane-runner.py"', text)
                self.assertNotIn('/usr/bin/python3 "$RUNNER_TEMP', text)
        self.assertLess(titles.index(step('Hosted Mac - Python 3.12').splitlines()[0]),
                        titles.index(step('Run the request').splitlines()[0]))
        self.assertIn("python-version: '3.12'", step('Hosted Mac - Python 3.12'))


class RoutingTests(unittest.TestCase):
    def test_unset_or_anything_but_on_keeps_the_mac(self):
        for env in ({}, {'LANE_HOSTED_APP': ''}, {'LANE_HOSTED_APP': 'off'}, {'LANE_HOSTED_APP': 'yes'}):
            with self.subTest(env=env):
                self.assertEqual(scope.hosted_app_routing(dict(NORMAL), env), NORMAL)

    def test_on_moves_only_the_lane_job(self):
        priority = {'lane': ['self-hosted', 'sm-lane-priority'], 'automerge': ['ubuntu-latest']}
        for result in (NORMAL, priority):
            with self.subTest(result=result):
                routed = scope.hosted_app_routing(dict(result), {'LANE_HOSTED_APP': ' On '})
                self.assertEqual(routed['lane'], ['xcode-27'])
                self.assertEqual(routed['automerge'], result['automerge'])

    def test_cli_reads_the_switch_from_the_environment_even_on_bad_input(self):
        command = [sys.executable, str(SCRIPTS / 'test-scope.py'), '--runner-routing', '/nonexistent/a', '/b', '/c']
        for value, expected in (('on', ['xcode-27']), ('', NORMAL['lane'])):
            with self.subTest(value=value):
                env = dict(os.environ, LANE_HOSTED_APP=value)
                out = subprocess.check_output(command, text=True, env=env)
                self.assertEqual(json.loads(out)['lane'], expected)

    def test_route_job_hands_the_variable_to_the_routing_step(self):
        self.assertIn('LANE_HOSTED_APP: ${{ vars.LANE_HOSTED_APP }}', step('Choose queues', 'route'))


class WorkflowTests(unittest.TestCase):
    def test_hosted_steps_never_run_on_the_mac(self):
        hosted = [text for text in steps() if text.startswith('- name: Hosted Mac')]
        self.assertGreaterEqual(len(hosted), 7)
        for text in hosted:
            with self.subTest(step=text.splitlines()[0]):
                self.assertIn(f"runner.environment == '{HOSTED}'", condition(text))
        # Every other step is the Mac's as before: none of them is gated on the runner.
        for text in steps():
            if text not in hosted:
                self.assertNotIn('runner.environment', condition(text))
        # And the other jobs, which merge, never take the hosted steps.
        for other in ('automerge', 'release'):
            self.assertNotIn('Hosted Mac', job(other))

    def test_mac_checkout_keeps_lfs_and_the_hosted_one_fetches_from_the_cache(self):
        self.assertIn(f"lfs: ${{{{ runner.environment != '{HOSTED}' }}}}", steps()[0])

    def test_hosted_python_tools_use_a_python_new_enough_for_the_pins(self):
        # The image's /usr/bin/python3 is 3.9; requirements-dev.txt pins jsonschema 4.26.0, which needs 3.10 (#2545).
        self.assertIn("python-version: '3.12'", step('Hosted Mac - Python 3.12'))
        self.assertNotIn('/usr/bin/python3', step('Hosted Mac - Python tools'))

    def test_the_prs_setup_script_never_sees_the_token(self):
        self.assertIn("GH_TOKEN: ''", step('Hosted Mac - Python tools'))

    def test_hosted_setup_marks_the_job_and_keeps_its_folders_in_runner_temp(self):
        setup = step('Hosted Mac - lane folders, Xcode and the iOS runtime')
        for line in ('SM_LANE_GITHUB_HOSTED=1', 'SM_LANE_STATE_DIR=$RUNNER_TEMP/lane-state',
                     'SM_LANE_EVIDENCE_DIR=$RUNNER_TEMP/lane-evidence', 'SM_LANE_IOS_MAJOR=$major'):
            self.assertIn(line, setup)

    def test_evidence_is_uploaded_even_after_a_failure(self):
        keep = step('Hosted Mac - keep the evidence')
        self.assertTrue(condition(keep).startswith('always() &&'))
        self.assertIn('name: lane-evidence', keep)


class RunnerTests(unittest.TestCase):
    def report(self):
        return lane.report('pr1-r2', 'PASS', 'a' * 40, 'b' * 40, 'T3', 'cloned iPhone 17, iOS 26.0', 60, 'X (1 passed)',
                           [], 'none', '/tmp/e', 'nothing', {})

    def test_report_says_where_hosted_evidence_went(self):
        with mock.patch.dict(os.environ, {'SM_LANE_GITHUB_HOSTED': '1'}):
            self.assertIn('evidence: /tmp/e (on a GitHub-hosted Mac; the run\'s `lane-evidence` artifact keeps it',
                          self.report())
        with mock.patch.dict(os.environ, {'SM_LANE_GITHUB_HOSTED': ''}):
            self.assertIn('evidence: /tmp/e (on the Mac)', self.report())

    def test_ios_major_follows_the_hosted_override(self):
        code = 'import lane_sim; print(lane_sim.IOS_MAJOR)'
        for value, expected in (('', '26'), ('27', '27')):
            with self.subTest(value=value):
                env = dict(os.environ, SM_LANE_IOS_MAJOR=value)
                out = subprocess.check_output([sys.executable, '-c', code], cwd=SCRIPTS, text=True, env=env)
                self.assertEqual(out.strip(), expected)


if __name__ == '__main__':
    unittest.main()
