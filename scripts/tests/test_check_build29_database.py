"""scripts/check-build29-database.sh must fail when the writer's tests fail (#1899), and imports the
current exporter tests' packets with every shipped build's own reader (#1900).

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
    printf '%s\n' "$@" > "$TMPDIR/swift-test-args"
    echo "Executed 3 tests, with $FAKE_FAILURES failures"
    echo "error: XCTAssertEqual failed" >&2
    [ "${FAKE_WRITES_DB:-1}" = 1 ] && echo '{}' > "$SM_BUILD29_DB.expected.json"
    [ "${FAKE_WRITES_PACKETS:-1}" = 1 ] && echo zip > "$SM_SHIPPED_PACKETS_DIR/a.spokenmargins"
    exit "$FAKE_TEST_EXIT" ;;
  build)
    echo "error: cannot find 'x' in scope"
    if [ "$FAKE_BUILD_EXIT" = 0 ]; then
      mkdir -p "$3/.build/debug"
      printf '#!/bin/sh\necho "ok   \$2 opened the database"\n' > "$3/.build/debug/reader"
      printf '#!/bin/sh\nls "$1"\nexit %s\n' "${FAKE_PACKET_EXIT:-0}" > "$3/.build/debug/packet-reader"
      chmod +x "$3/.build/debug/reader" "$3/.build/debug/packet-reader"
    fi
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
    full = {key: value for key, value in full.items() if value is not None}  # BUILD29_TAG=None leaves it unset
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
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_writer_tests_that_keep_no_packets_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp, FAKE_WRITES_PACKETS='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL the exporter tests kept no packets', result.stderr)
        self.assertNotIn('building Build 29', result.stdout)

    def test_a_reader_that_does_not_build_fails_the_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp, FAKE_BUILD_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL Build 29's reader did not build", result.stderr)
        self.assertNotIn('== reading it with Build 29', result.stdout)


class PacketTests(unittest.TestCase):
    """#1900: the build's own packet reader imports the packets the exporter tests kept."""

    def test_the_packet_reader_gets_the_kept_packets(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp)
        self.assertIn('kept 1 packets', result.stdout)
        self.assertIn('== importing the packets with Build 29', result.stdout)
        self.assertIn('a.spokenmargins', result.stdout)  # the fake reader lists the folder it was given

    def test_the_writer_runs_only_the_exporter_classes_of_sessionkittests(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_script(tmp)
            args = (Path(tmp) / 'swift-test-args').read_text().splitlines()
        selected = args[args.index('--filter') + 1]
        self.assertTrue(selected.startswith('Build29DatabaseFixtureTests|SessionKitTests\\.('), selected)
        classes = selected.split('(', 1)[1].rstrip(')/').split('|')
        self.assertIn('SharingTests', classes)
        self.assertIn('ShippedReaderRoundTripTests', classes)
        # Real-time audio tests need a sound output the hosted runner lacks; they export no packet.
        self.assertNotIn('KittenRendererTests', classes)
        self.assertNotIn('HeardSourceWindowFilesTests', classes)

    def test_a_packet_the_build_cannot_import_fails_the_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp, FAKE_PACKET_EXIT='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('== importing the packets with Build 29', result.stdout)


TAGS = ['testflight/0.1-build-29', 'testflight/0.1-build-32', 'testflight/0.1-build-34']


class EveryShippedBuildTests(unittest.TestCase):
    """#1900: with no BUILD29_TAG the script opens the database with Builds 29, 32 and 34, in that order."""

    def setUp(self):
        root = SCRIPT.parents[1]
        missing = [tag for tag in TAGS if subprocess.run(
            ['git', '-C', str(root), 'rev-parse', '--verify', '--quiet', f'{tag}^{{commit}}'], capture_output=True).returncode]
        if missing:
            self.skipTest(f'tags not fetched here: {missing}')  # the compat workflow fetches them

    def test_each_build_gets_its_own_reader_and_a_failing_one_names_itself(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script(tmp, BUILD29_TAG=None)
        steps = [line for line in result.stdout.splitlines() if line.startswith('== building ')]
        self.assertEqual([line.split("'s")[0] for line in steps],
                         ['== building Build 29', '== building Build 32', '== building Build 34'])
        self.assertEqual(result.stdout.count('== reading it with Build'), 3)
        self.assertEqual([line for line in result.stdout.splitlines() if line.startswith('== importing the packets')],
                         ['== importing the packets with Build 29', '== importing the packets with Build 32',
                          '== importing the packets with Build 34'])

        with tempfile.TemporaryDirectory() as tmp:
            failed = run_script(tmp, BUILD29_TAG=None, FAKE_BUILD_EXIT='1')
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("FAIL Build 29's reader did not build", failed.stderr)
        self.assertNotIn('== building Build 32', failed.stdout, 'the first failure stops the run')


if __name__ == '__main__':
    unittest.main()
