"""Every hosted Mac job that builds Swift keeps its packages, so a bad binary-target host can't stop it (#4664).

On 2026-11-21 download.onnxruntime.ai served an invalid certificate. SessionKit depends on onnxruntime's binary targets,
so any job that fetched them afresh failed before running a test: main-t3 (fixed in #4821), and the merge queue's
`hosted fast: Mac rest` job, whose `tools` step builds Packages/SessionKitTools into a scratch folder the job's cache
had never saved (it shared one key with the `sessionkit` job, which never runs `tools`). PR #4795 was dequeued for it.

The class is "a hosted Mac job fetches the packages afresh". These tests read the parsed workflow files, so a job
added later, or a cache turned into a comment, fails here instead of in the queue.
"""
from __future__ import annotations

import re
import unittest

import workflow_yaml as W
from test_workflow_files import ROOT

WORKFLOWS = sorted(p.name for p in (ROOT / '.github' / 'workflows').glob('*.yml'))

# xcodebuild resolves packages into -clonedSourcePackagesDirPath (verify-tests.py adds it from SM_SPM_DIR).
XCODEBUILD = re.compile(r'xcodebuild -project|lane-runner\.py"? --tree|main_t3\.py run|sm_integration_run|--plan app\b')
# `swift build` and `swift test` resolve them into Packages/SessionKit/.build.
SWIFTPM = re.compile(r'swift (build|test)\b|--plan fast-hosted-sessionkit|--plan fast-mac-rest|check-build29-database')


def is_hosted_mac(workflow_name: str, job_name: str, job: dict) -> bool:
    # lane.yml's `lane` job is a hosted Mac only when the router says so; its hosted steps are marked github-hosted.
    if workflow_name == 'lane.yml' and job_name == 'lane':
        return True
    return job.get('runs-on') == 'xcode-27'


def run_text(job: dict) -> str:
    return '\n'.join(str(step.get('run', '')) for step in job.get('steps', []))


def cache_steps(job: dict) -> list[dict]:
    return [step for step in job.get('steps', []) if str(step.get('uses', '')).startswith('actions/cache')]


def hosted_swift_jobs():
    """(workflow, job name, job, builds with xcodebuild, builds with SwiftPM) for every hosted Mac job that builds."""
    found = []
    for name in WORKFLOWS:
        for job_name, job in (W.load(name).get('jobs') or {}).items():
            if not is_hosted_mac(name, job_name, job):
                continue
            text = run_text(job)
            xcode, swiftpm = bool(XCODEBUILD.search(text)), bool(SWIFTPM.search(text))
            if xcode or swiftpm:
                found.append((name, job_name, job, xcode, swiftpm))
    return found


def names_package_folder(job: dict) -> bool:
    """The job hands xcodebuild a package folder: SM_SPM_DIR (job env, step env, or written to GITHUB_ENV) or the flag."""
    text = run_text(job)
    if '-clonedSourcePackagesDirPath' in text or 'SM_SPM_DIR' in text:
        return True
    envs = [job.get('env') or {}] + [step.get('env') or {} for step in job.get('steps', [])]
    return any('SM_SPM_DIR' in env for env in envs)


class HostedSwiftJobsKeepTheirPackagesTests(unittest.TestCase):
    def test_the_check_sees_every_known_hosted_mac_swift_job(self):
        # A pattern that matched nothing would pass every test below.
        seen = {(w, j) for w, j, *_ in hosted_swift_jobs()}
        for expected in [('lane.yml', 'lane'), ('hosted-integration.yml', 'integration'),
                         ('hosted-portable.yml', 'sessionkit'), ('hosted-portable.yml', 'app-compile'),
                         ('hosted-portable.yml', 'mac-rest'), ('shipped-build-compat.yml', 'compat'),
                         ('hosted-app-macos.yml', 'app'), ('phone-build.yml', 'build'), ('main-t3.yml', 't3')]:
            with self.subTest(expected=expected):
                self.assertIn(expected, seen, f'{expected} is not detected: its name or what it runs changed')

    def test_a_job_that_runs_xcodebuild_restores_the_packages_and_names_the_folder(self):
        for workflow, name, job, xcode, _ in hosted_swift_jobs():
            if not xcode:
                continue
            with self.subTest(job=f'{workflow}:{name}'):
                paths = [str((step.get('with') or {}).get('path', '')) for step in cache_steps(job)]
                self.assertTrue(any('spm' in p.lower() for p in paths),
                                f'{workflow}:{name} runs xcodebuild with no spm cache step (cache paths: {paths})')
                self.assertTrue(names_package_folder(job),
                                f'{workflow}:{name} restores the packages but never gives xcodebuild the folder '
                                '(SM_SPM_DIR or -clonedSourcePackagesDirPath)')

    def test_a_job_that_runs_swiftpm_restores_the_package_build_folder(self):
        for workflow, name, job, _, swiftpm in hosted_swift_jobs():
            if not swiftpm:
                continue
            with self.subTest(job=f'{workflow}:{name}'):
                paths = [str((step.get('with') or {}).get('path', '')) for step in cache_steps(job)]
                self.assertIn('Packages/SessionKit/.build', paths,
                              f'{workflow}:{name} runs swift build/test with no cache of Packages/SessionKit/.build')


    def test_the_restore_comes_before_the_first_step_that_builds(self):
        for workflow, name, job, xcode, swiftpm in hosted_swift_jobs():
            steps = job['steps']
            building = next(i for i, step in enumerate(steps) if XCODEBUILD.search(str(step.get('run', '')))
                            or SWIFTPM.search(str(step.get('run', ''))))
            restoring = [i for i, step in enumerate(steps) if step in cache_steps(job) and re.search(
                r'spm|SessionKit/\.build', str((step.get('with') or {}).get('path', '')), re.I)]
            with self.subTest(job=f'{workflow}:{name}'):
                self.assertTrue(restoring and min(restoring) < building,
                                f'{workflow}:{name} builds (step {building}) before it restores the packages {restoring}')

    def test_the_lane_job_keeps_its_package_folder_out_of_the_build_folder_the_runner_replaces(self):
        # scripts/lane-runner.py warm_build_folders() removes a real .build directory and links it to the warm cache
        # before every T2/T3 build, so a folder inside .build is empty by the time xcodebuild reads it.
        job = W.load('lane.yml')['jobs']['lane']
        writes = [str(step.get('run', '')) for step in job['steps'] if 'SM_SPM_DIR=' in str(step.get('run', ''))]
        self.assertEqual(len(writes), 1, writes)
        value = re.search(r'SM_SPM_DIR=(\S+)', writes[0]).group(1)
        self.assertNotIn('.build', value)
        self.assertIn('RUNNER_TEMP', value)


class SessionKitBuildCacheKeysTests(unittest.TestCase):
    """Two jobs on one key: whichever saves first decides what the other restores, and a step the first never ran
    (`tools`, in mac-rest) is never cached. A cache is saved only on a key miss, so the second job never fixes it."""

    @staticmethod
    def build_folder_keys():
        keys = {}
        for workflow, name, job, _, swiftpm in hosted_swift_jobs():
            for step in cache_steps(job):
                with_ = step.get('with') or {}
                # Only a job that saves needs a key of its own; actions/cache/restore reads another job's entry.
                if with_.get('path') == 'Packages/SessionKit/.build' and not str(step['uses']).startswith('actions/cache/restore'):
                    keys[f'{workflow}:{name}'] = str(with_['key'])
        return keys

    def test_each_job_has_its_own_key_prefix(self):
        keys = self.build_folder_keys()
        self.assertGreaterEqual(len(keys), 2, keys)  # sessionkit and mac-rest save it
        prefixes = {job: key.split('${{')[0] for job, key in keys.items()}
        self.assertEqual(len(set(prefixes.values())), len(prefixes), f'two jobs share a cache key: {prefixes}')

    def test_mac_rest_keys_on_the_tools_package_it_builds_and_falls_back_to_the_shared_key(self):
        job = W.load('hosted-portable.yml')['jobs']['mac-rest']
        # fast-mac-rest is the plan whose `tools` step builds Packages/SessionKitTools into .build/tools.
        self.assertIn('--plan fast-mac-rest', run_text(job))
        key_step = next(step for step in cache_steps(job)
                        if (step.get('with') or {}).get('path') == 'Packages/SessionKit/.build')['with']
        for file in ('Packages/SessionKitTools/Package.swift', 'Packages/SessionKitTools/Package.resolved'):
            self.assertIn(file, key_step['key'], 'the key must change when the tools package does')
        fallbacks = [line.strip() for line in str(key_step['restore-keys']).splitlines() if line.strip()]
        self.assertEqual(fallbacks[0], key_step['key'].split('${{')[0].strip(), 'its own prefix restores first')
        self.assertIn('sessionkit-macos-xcode27.0-', fallbacks, 'the first run starts from the shared cache, not cold')


if __name__ == '__main__':
    unittest.main()
