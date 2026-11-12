"""scripts/app_test_poll_loops.py: no fixed-count poll loop in the app tests (#4131).

The table below is the scanner's neighbouring shapes of one wait: each says whether the loop is flagged. The last class
runs the scan over the app tests, which is the guard itself: it fails on a new `for _ in 0..<N` loop that sleeps, and
the class before it shows the scan does flag one (a test that passes without the scan would guard nothing).
"""
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import app_test_poll_loops as polls  # noqa: E402


def flagged(source):
    return polls.flagged(polls.scan_source(source))


class WhichLoopsAreFlagged(unittest.TestCase):
    def test_the_loop_that_failed_four_tests_on_4130_is_flagged(self):
        source = '        for _ in 0..<100 where coordinator.snapshot.previewState != .ready { try await Task.sleep(for: .milliseconds(20)) }\n'
        found = flagged(source)
        self.assertEqual([(l['line'], l['count'], l['deadline_s']) for l in found], [(1, 100, 2.0)])
        self.assertIn('previewState', found[0]['waits_for'])

    def test_neighbouring_spellings_of_the_same_wait_are_all_flagged(self):
        cases = {
            'count with an underscore': 'for _ in 0..<1_000 where !done() { try await Task.sleep(for: .milliseconds(10)) }',
            'try? instead of try': 'for _ in 0..<50 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }',
            'nanoseconds': 'for _ in 0..<200 where model.isLoading { try? await Task.sleep(nanoseconds: 10_000_000) }',
            'seconds': 'for _ in 0..<5 where !ready { try await Task.sleep(for: .seconds(1)) }',
            'await in the condition': 'for _ in 0..<50 where await renderer.renderCount <= 3 { try await Task.sleep(for: .milliseconds(20)) }',
            'extra spaces': '    for _ in 0..<100   where   !ready   {   try await Task.sleep(for: .milliseconds(20))   }',
            'body on the next lines': 'for _ in 0..<150 where status != .playing {\n    try await Task.sleep(for: .milliseconds(20))\n    sync()\n}',
            'no where clause, early return': 'for _ in 0..<100 {\n    if ready { return }\n    try await Task.sleep(for: .milliseconds(20))\n}',
            'no where clause, break': 'for _ in 0..<100 {\n    if ready { break }\n    try? await Task.sleep(for: .milliseconds(20))\n}',
            'one line, semicolons': 'for _ in 0..<150 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(20)) }',
            'a count that is a name': 'for _ in 0..<bridgePolls where !ready { try await Task.sleep(for: .milliseconds(20)) }',
            'a count that is an expression': 'for _ in 0..<Int(seconds * 50) where playingChunkStart != start { try? await Task.sleep(for: .milliseconds(20)) }',
            'a count in parentheses': 'for _ in 0..<(seconds * 4) {\n    if ready { return }\n    try await Task.sleep(for: .milliseconds(250))\n}',
            'a where clause over two lines': 'for _ in 0..<bridgePolls where state != "ready"\n    && state?.hasPrefix("failed:") != true {\n    try await Task.sleep(for: .milliseconds(20))\n}',
            'tabs': '\tfor _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(20)) }',
        }
        for name, source in cases.items():
            with self.subTest(name):
                self.assertEqual(len(flagged(source + '\n')), 1, source)

    def test_waits_with_a_deadline_are_not_flagged(self):
        cases = {
            'the shared wait': 'try await pollUntil { drawer.followedCount >= 5 }',
            'a clock deadline': 'let d = ContinuousClock.now + .seconds(30)\nwhile ContinuousClock.now < d {\n    if ready { return }\n    try await Task.sleep(for: .milliseconds(20))\n}',
            'a loop that does not sleep': 'for _ in 0..<100 { model.tick() }',
            'a loop over an index': 'for index in 0..<100 {\n    model.snapshot.currentMediaTimeMs = index * 500\n}',
            'a sleep after the loop': 'for _ in 0..<3 { model.tick() }\ntry await Task.sleep(for: .milliseconds(20))',
            'a loop that only yields': 'for _ in 0..<100 where gate.continuation == nil { await Task.yield() }',
            'a counted loop over two lines that does not sleep': 'for _ in 0..<(seconds * 4)\n    where model.busy {\n    model.tick()\n}',
        }
        for name, source in cases.items():
            with self.subTest(name):
                self.assertEqual(flagged(source + '\n'), [], source)

    def test_a_nested_loop_flags_both_loops_that_contain_the_sleep(self):
        source = 'for _ in 0..<20 {\n    for _ in 0..<2 {\n        try await Task.sleep(for: .milliseconds(20))\n    }\n}\n'
        self.assertEqual([l['line'] for l in flagged(source)], [1, 2])

    def test_the_sleep_after_a_loop_is_not_the_loops(self):
        source = 'for _ in 0..<3 {\n    model.tick()\n}\ntry await Task.sleep(for: .milliseconds(20))\n'
        self.assertEqual(flagged(source), [])

    def test_a_yield_only_loop_is_listed_but_not_flagged(self):
        loops = polls.scan_source('for _ in 0..<100 where gate.continuation == nil { await Task.yield() }\n')
        self.assertEqual([l['kind'] for l in loops], ['yield'])
        self.assertEqual(polls.flagged(loops), [])

    def test_a_reason_comment_exempts_the_loop_on_its_line_or_the_line_above(self):
        same = 'for _ in 0..<20 { // fixed-count ok: it makes 20 changes, not waiting for anything\n    try await Task.sleep(for: .milliseconds(20))\n}\n'
        above = '// fixed-count ok: it makes 20 changes\nfor _ in 0..<20 {\n    try await Task.sleep(for: .milliseconds(20))\n}\n'
        empty = 'for _ in 0..<20 { // fixed-count ok:\n    try await Task.sleep(for: .milliseconds(20))\n}\n'
        far = '// fixed-count ok: stale\n\nfor _ in 0..<20 {\n    try await Task.sleep(for: .milliseconds(20))\n}\n'
        self.assertEqual(flagged(same), [])
        self.assertEqual(flagged(above), [])
        self.assertEqual(len(flagged(empty)), 1, 'a reason comment needs a reason')
        self.assertEqual(len(flagged(far)), 1, 'the comment sits on the loop or the line above it')

    def test_two_loops_are_reported_at_their_own_lines(self):
        source = 'a()\nfor _ in 0..<10 where x { try await Task.sleep(for: .milliseconds(5)) }\nb()\nfor _ in 0..<10 where y { try await Task.sleep(for: .milliseconds(5)) }\n'
        self.assertEqual([l['line'] for l in flagged(source)], [2, 4])


class TheScanOverAFolder(unittest.TestCase):
    def test_a_new_loop_in_a_test_file_fails_the_scan(self):
        with tempfile.TemporaryDirectory() as folder:
            clean = Path(folder) / 'CleanTests.swift'
            clean.write_text('try await pollUntil { ready }\n')
            self.assertEqual(polls.main(['--folder', folder]), 0)
            (Path(folder) / 'NewTests.swift').write_text(
                'func t() async throws {\n    for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(20)) }\n}\n')
            self.assertEqual(polls.main(['--folder', folder]), 1)
            found = polls.flagged(polls.scan_tree(folder))
            self.assertEqual([(l['file'], l['line']) for l in found], [('NewTests.swift', 2)])


class TheAppTests(unittest.TestCase):
    def test_no_app_test_waits_with_a_fixed_count_poll_loop(self):
        bad = polls.flagged(polls.scan_tree())
        self.assertEqual(
            bad, [], 'Wait with pollUntil { ... } (App/SpokenMarginsAppTests/PollUntil.swift) or a ContinuousClock '
                     'deadline, not a tick count; a loop whose count is the point carries `// fixed-count ok: <why>` (#4131): '
                     + ', '.join(f'{l["file"]}:{l["line"]}' for l in bad[:10]))

    def test_the_shared_wait_exists_and_takes_a_deadline(self):
        source = (polls.TESTS / 'PollUntil.swift').read_text()
        self.assertIn('func pollUntil(', source)
        self.assertIn('timeout: Duration', source)


if __name__ == '__main__':
    unittest.main()
