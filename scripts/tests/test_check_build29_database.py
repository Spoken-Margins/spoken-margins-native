"""scripts/check-build29-database.sh must fail when the writer's tests fail (#1899).

A fake `swift` on PATH stands in for the toolchain, so the script's own exit handling is what runs.
Before the fix, `swift test | grep | tail` hid a non-zero exit and the script went on to build Build 29's reader.
"""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-build29-database.sh'
FAKE_SWIFT = """#!/bin/sh
case "$1" in
  test)
    echo "Executed 3 tests, with $FAKE_FAILURES failures"
    echo "error: XCTAssertEqual failed" >&2
    [ "${FAKE_WRITES_DB:-1}" = 1 ] && echo '{}' > "$SM_BUILD29_DB.expected.json"
    exit "$FAKE_TEST_EXIT" ;;
  build)
    echo "error: cannot find 'x' in scope"
    exit "$FAKE_BUILD_EXIT" ;;
esac
"""


def run_script(tmp, **env):
    fake = Path(tmp) / 'bin'
    fake.mkdir()
    swift = fake / 'swift'
    swift.write_text(FAKE_SWIFT)
    swift.chmod(swift.stat().st_mode | stat.S_IEXEC)
    full = {**os.environ, 'PATH': f'{fake}:{os.environ["PATH"]}', 'TMPDIR': tmp, 'BUILD29_TAG': 'HEAD',
            'FAKE_FAILURES': '0', 'FAKE_TEST_EXIT': '0', 'FAKE_BUILD_EXIT': '0', **env}
    return subprocess.run(['sh', str(SCRIPT)], env=full, capture_output=True, text=True, timeout=120)


class WriterStatusTests(unittest.TestCase):
    def test_a_failing_writer_test_fails_the_script_before_build_29_is_built(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp, FAKE_TEST_EXIT='1', FAKE_FAILURES='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL the writer's tests failed", result.stderr)
        self.assertNotIn('building Build 29', result.stdout)
        self.assertIn('Executed 3 tests, with 1 failures', result.stdout)  # the summary still shows

    def test_a_writer_that_leaves_no_database_still_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp, FAKE_WRITES_DB='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL the writer produced no database', result.stderr)

    def test_a_passing_writer_goes_on_to_build_29(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp)
        self.assertIn('== building Build 29', result.stdout)  # control: the happy path reaches the next step

    def test_a_reader_that_does_not_build_fails_the_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp, FAKE_BUILD_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL Build 29's reader did not build", result.stderr)
        self.assertNotIn('== reading it with Build 29', result.stdout)


if __name__ == '__main__':
    unittest.main()
