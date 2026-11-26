"""main-t3 and branch-t3 test on iOS 26, the iOS the app targets, and never fall back to iOS 27 silently (#5221).

The hosted image ships iOS 27 only. scripts/ci-ios-runtime.sh downloads iOS 26.5 when no iOS 26 runtime is there,
tries 3 times, and fails the step if it still has none. These tests run the real script against stand-in `xcrun`,
`xcodebuild` and `sleep` commands, and read both workflows to check the install comes before the runtime choice.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci-ios-runtime.sh'
IOS27 = {'isAvailable': True, 'platform': 'iOS', 'version': '27.2', 'buildversion': '25C5'}
IOS26 = {'isAvailable': True, 'platform': 'iOS', 'version': '26.5', 'buildversion': '23F77'}


class InstallScriptTests(unittest.TestCase):
    def run_script(self, runtimes, download_works=True, installs=True, fail_first=0, xcrun_works=True):
        tmp = Path(tempfile.mkdtemp())
        state = tmp / 'runtimes.json'
        state.write_text(json.dumps({'runtimes': runtimes}))
        after = json.dumps({'runtimes': runtimes + ([IOS26] if installs else [])})
        (tmp / 'after.json').write_text(after)
        (tmp / 'calls').write_text('')
        stubs = {
            'xcrun': f'#!/bin/bash\ncat "{state}"\n' if xcrun_works else '#!/bin/bash\necho broken >&2\nexit 72\n',
            'xcodebuild': (f'#!/bin/bash\necho "xcodebuild $*" >> "{tmp}/calls"\n'
                           f'[ $(grep -c xcodebuild "{tmp}/calls") -le {fail_first} ] && exit 1\n'
                           + (f'cp "{tmp}/after.json" "{state}"\nexit 0\n' if download_works else 'exit 1\n')),
            'sleep': f'#!/bin/bash\necho "sleep $*" >> "{tmp}/calls"\n',
            'df': '#!/bin/bash\necho "/dev/disk 100G 50G 50G 50% /"\n',
        }
        for name, body in stubs.items():
            (tmp / name).write_text(body)
            (tmp / name).chmod(0o755)
        env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}')
        done = subprocess.run(['bash', str(SCRIPT), 'main-t3'], env=env, capture_output=True, text=True, timeout=60)
        return done, (tmp / 'calls').read_text().splitlines()

    def test_an_image_with_ios_26_downloads_nothing(self):
        done, calls = self.run_script([IOS27, IOS26])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(calls, [])
        self.assertIn('iOS 26.5 (23F77) is already on this image', done.stdout)

    def test_an_ios_27_image_downloads_ios_26_5(self):
        done, calls = self.run_script([IOS27])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(calls, ['xcodebuild -downloadPlatform iOS -buildVersion 26.5 -architectureVariant arm64'])
        self.assertIn('Installed iOS 26.5 (23F77).', done.stdout)

    def test_a_failing_download_is_tried_three_times_then_fails_the_step(self):
        done, calls = self.run_script([IOS27], download_works=False)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(sum(c.startswith('xcodebuild') for c in calls), 3)
        self.assertEqual([c for c in calls if c.startswith('sleep')], ['sleep 30', 'sleep 60'])
        self.assertIn('::error title=main-t3 iOS::Could not install the iOS 26.5 simulator runtime after 3 tries',
                      done.stdout)

    def test_a_download_that_fails_once_then_works_passes(self):
        done, calls = self.run_script([IOS27], fail_first=1)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(sum(c.startswith('xcodebuild') for c in calls), 2)
        self.assertEqual([c for c in calls if c.startswith('sleep')], ['sleep 30'])

    def test_a_broken_runtime_listing_fails_without_downloading(self):
        done, calls = self.run_script([IOS27, IOS26], xcrun_works=False)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, [])
        self.assertIn('could not list the simulator runtimes', done.stdout)

    def test_a_download_that_leaves_no_ios_26_runtime_fails_the_step(self):
        done, calls = self.run_script([IOS27], installs=False)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(sum(c.startswith('xcodebuild') for c in calls), 3)

    def test_an_unavailable_ios_26_runtime_does_not_count(self):
        done, calls = self.run_script([IOS27, dict(IOS26, isAvailable=False)], download_works=False)
        self.assertEqual(done.returncode, 1)


class WorkflowTests(unittest.TestCase):
    def test_both_t3_workflows_install_ios_26_before_choosing_the_runtime(self):
        for name in ('main-t3', 'branch-t3'):
            with self.subTest(name):
                text = (ROOT / f'.github/workflows/{name}.yml').read_text()
                install = text.index('- name: Install the iOS 26 simulator runtime')
                choose = text.index('- name: Lane folders, Xcode and the iOS runtime')
                self.assertLess(install, choose)
                # From the workflow's own commit, so an older commit under test still gets it.
                self.assertIn('git show "$GITHUB_SHA:scripts/ci-ios-runtime.sh"', text[install:choose])
                self.assertIn(f'ci-ios-runtime.sh" {name}', text[install:choose])
                runtime_step = text[choose:text.index('- name:', choose + 10)]
                self.assertNotIn('::warning', runtime_step)
                self.assertRegex(runtime_step, r'if \[ "\$major" != 26 \]; then\n *echo "::error[^\n]*\n *exit 1\n *fi')


if __name__ == '__main__':
    unittest.main()
