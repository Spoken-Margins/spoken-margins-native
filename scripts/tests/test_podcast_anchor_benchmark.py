"""scripts/run-podcast-anchor-benchmark.sh reports only a measurement it made (#2133).

The held-out corpus test skips unless the script hands it every input, and `swift test --filter` passes
when the filter matches nothing. Either way the script used to print "Benchmark result:" and exit 0
beside a result file from an earlier run, or none. These tests run the script with stand-in tools on
PATH and a pre-filled cache, so nothing is downloaded, transcribed or built.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts' / 'run-podcast-anchor-benchmark.sh'
SHARING_TESTS = ROOT / 'Packages' / 'SessionKit' / 'Tests' / 'SessionKitTests' / 'SharingTests.swift'
CACHE_FILES = (
    'adventuresofsherlockhomes_04_conandoyle_64kb.mp3', 'adventuresofsherlockhomes_05_conandoyle_64kb.mp3',
    'sender-edition.m4a', 'inserted-speech.m4a', 'recipient-edition.m4a', 'sender-edition.wav',
    'recipient-edition.wav', 'ggml-base.en.bin', 'sender-transcript.json', 'recipient-transcript.json',
)
RESULT = {
    'anchors': {'total': 232, 'eligible': 220, 'absent': 12},
    'timestampOnly': {'p95ErrorMs': 45000, 'falseConfident': 140},
    'transcript': {'p95ErrorMs': 900, 'falseConfident': 1},
    'acoustic': {'p95ErrorMs': 400, 'falseConfident': 0},
    'fusedMonotonic': {'p95ErrorMs': 380, 'falseConfident': 0},
}


class BenchmarkScriptTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        cache = self.scratch / 'tmp' / 'spoken-margins-anchor-held-out-v2'
        cache.mkdir(parents=True)
        for name in CACHE_FILES:
            (cache / name).write_text('cached')
        self.bin = self.scratch / 'bin'
        self.bin.mkdir()
        for tool in ('curl', 'ffmpeg', 'whisper-cli'):
            self.tool(tool, 'echo "unexpected call: $0 $*" >&2; exit 3')
        (self.bin / 'python3').symlink_to(sys.executable)
        self.result = self.scratch / 'out' / 'result.json'

    def tool(self, name, body):
        path = self.bin / name
        path.write_text(f'#!/bin/bash\n{body}\n')
        path.chmod(0o755)

    def run_script(self):
        env = {**os.environ, 'PATH': f'{self.bin}:/usr/bin:/bin', 'TMPDIR': str(self.scratch / 'tmp'),
               'SPOKEN_MARGINS_BENCHMARK_RESULT_PATH': str(self.result)}
        return subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)

    def test_a_run_that_writes_no_result_fails(self):
        self.tool('swift', 'exit 0')
        run = self.run_script()
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('no result', run.stderr)

    def test_a_result_left_by_an_earlier_run_is_not_reported_as_this_one(self):
        self.result.parent.mkdir(parents=True)
        self.result.write_text(json.dumps(RESULT))
        self.tool('swift', 'exit 0')
        run = self.run_script()
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn('p95', run.stdout)

    def writing_swift(self, status):
        payload = json.dumps(RESULT)
        self.tool('swift', f"""[[ "$SPOKEN_MARGINS_RUN_ANCHOR_CORPUS" == 1 ]] || exit 4
printf '%s' '{payload}' > "$SPOKEN_MARGINS_BENCHMARK_RESULT_PATH"
exit {status}""")

    def test_a_fresh_result_is_summarised(self):
        self.writing_swift(0)
        run = self.run_script()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('fusedMonotonic: p95 380 ms, false-confident 0', run.stdout)
        self.assertIn('acoustic: p95 400 ms, false-confident 0', run.stdout)
        self.assertIn('eligible 220', run.stdout)

    def test_a_missed_gate_still_reports_its_numbers_and_fails(self):
        # The test writes its result before asserting the gate, so a miss shows how far off it is.
        self.writing_swift(1)
        run = self.run_script()
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn('transcript: p95 900 ms, false-confident 1', run.stdout)

    def test_the_script_exits_with_the_test_status(self):
        self.writing_swift(7)
        self.assertEqual(self.run_script().returncode, 7)


class FilterNameTests(unittest.TestCase):
    # A renamed test would leave the filter matching nothing, which `swift test` passes.
    def test_the_filter_names_a_test_that_exists(self):
        match = re.search(r'--filter\s+(\w+)/(\w+)', SCRIPT.read_text())
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), 'SharingTests')
        self.assertRegex(SHARING_TESTS.read_text(), rf'func {match.group(2)}\(\)')


if __name__ == '__main__':
    unittest.main()
