"""#2591: after the Xcode 27.1 update, every `xcrun simctl` call waited on an admin-password prompt for Xcode's
first-launch install, and timed-out callers left 17 orphaned `xcodebuild -runFirstLaunch` waiters behind."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane_sim  # noqa: E402
import simctl_preflight as preflight  # noqa: E402

# The head of Xcode 27.1's wrapper, as installed on 2026-10-24.
WRAPPER = '''#!/bin/bash
DEVELOPER_USR_BIN_DIR=${0%/*}
export DEVELOPER_DIR=${DEVELOPER_USR_DIR%/*}

EXPECTED_VERSION="{expected}"
CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Info.plist" 2>/dev/null)"
exec "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl" "${@}"
'''


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__('shutil').rmtree(self.folder, ignore_errors=True))

    def wrapper(self, expected='1174.9.2', text=None, raw=None):
        path = self.folder / 'simctl'
        if raw is not None:
            path.write_bytes(raw)
        else:
            path.write_text(WRAPPER.replace("{expected}", expected) if text is None else text)
        return path

    def plist(self, version, binary=False):
        path = self.folder / 'Info.plist'
        with path.open('wb') as handle:
            plistlib.dump({'CFBundleVersion': version} if version is not None else {'CFBundleName': 'CoreSimulator'},
                          handle, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML)
        return path

    def test_table(self):
        missing = self.folder / 'none'
        rows = [
            # (case, wrapper, plist, fails)
            ('older (the 2026-10-24 Mac)', lambda: self.wrapper(), lambda: self.plist('1171.7'), True),
            ('older, binary plist', lambda: self.wrapper(), lambda: self.plist('1171.7', binary=True), True),
            ('older in the last part', lambda: self.wrapper(), lambda: self.plist('1174.9.1'), True),
            ('older by number, not text', lambda: self.wrapper('1174.10'), lambda: self.plist('1174.9'), True),
            ('equal', lambda: self.wrapper(), lambda: self.plist('1174.9.2'), False),
            ('newer', lambda: self.wrapper(), lambda: self.plist('1180.1'), False),
            ('newer by number, not text', lambda: self.wrapper('1174.9'), lambda: self.plist('1174.10'), False),
            ('trailing .0 on the framework', lambda: self.wrapper('1174'), lambda: self.plist('1174.0'), False),
            ('trailing .0 on the wrapper', lambda: self.wrapper('1174.9.2.0'), lambda: self.plist('1174.9.2'), False),
            ('missing plist', lambda: self.wrapper(), lambda: missing, True),
            ('plist without CFBundleVersion', lambda: self.wrapper(), lambda: self.plist(None), True),
            ('missing wrapper', lambda: missing, lambda: self.plist('1171.7'), False),
            ('non-script binary', lambda: self.wrapper(raw=b'\xcf\xfa\xed\xfe' + b'\0' * 64), lambda: self.plist('1171.7'), False),
            ('script without EXPECTED_VERSION', lambda: self.wrapper(text='#!/bin/bash\nexec simctl "$@"\n'),
             lambda: self.plist('1171.7'), False),
        ]
        for case, wrapper, plist, fails in rows:
            with self.subTest(case):
                found = preflight.problem(wrapper(), plist())
                if fails:
                    self.assertIsNotNone(found)
                    self.assertIn('sudo xcodebuild -runFirstLaunch', found)
                else:
                    self.assertIsNone(found)

    def test_message_names_both_versions(self):
        found = preflight.problem(self.wrapper(), self.plist('1171.7'))
        self.assertIn('CoreSimulator is older than Xcode expects (1171.7, Xcode wants 1174.9.2)', found)

    def test_lane_sim_fails_fast_instead_of_calling_simctl(self):
        with mock.patch.dict(os.environ, {}, clear=False), \
                mock.patch.object(lane_sim, 'simctl_problem', return_value='CoreSimulator is older than Xcode expects'), \
                mock.patch.object(lane_sim, 'bounded_output') as called:
            os.environ.pop('SM_LANE_SIMCTL', None)
            started = time.monotonic()
            with self.assertRaisesRegex(lane_sim.BootError, 'older than Xcode expects'):
                lane_sim.booted_udids()
        self.assertLess(time.monotonic() - started, 5)
        called.assert_not_called()

    def test_a_stand_in_simctl_skips_the_preflight(self):
        with mock.patch.dict(os.environ, {'SM_LANE_SIMCTL': 'fake-simctl'}), \
                mock.patch.object(lane_sim, 'simctl_problem', return_value='would fail') as checked:
            lane_sim.ensure_simctl_ready()
        checked.assert_not_called()


class BoundedOutputTests(unittest.TestCase):
    def test_a_timeout_kills_the_whole_process_group(self):
        # The wrapper's shape: a shell whose child (xcodebuild -runFirstLaunch) outlives a kill of the shell alone.
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / 'child.pid'
            script = f'sleep 60 & echo $! > {pid_file}; wait'
            with self.assertRaises(subprocess.TimeoutExpired):
                preflight.bounded_output(['/bin/sh', '-c', script], timeout=1)
            child = int(pid_file.read_text())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(child, 9)
            self.fail('the grandchild outlived the timeout: an orphan like the 17 waiters on 2026-10-24')

    def test_output_and_exit_status_match_check_output(self):
        self.assertEqual(preflight.bounded_output(['/bin/echo', 'hi'], timeout=10), 'hi\n')
        with self.assertRaises(subprocess.CalledProcessError):
            preflight.bounded_output(['/bin/sh', '-c', 'exit 3'], timeout=10)


if __name__ == '__main__':
    unittest.main()
