"""scripts/app_test_negative_sleeps.py: no new fixed sleep before a "must not happen" assertion (#4313).

The tables below are neighbouring shapes of one sleep: each says whether it is flagged. The baseline class shows a new
sleep in a listed test still fails, and the last class runs the scan over the app and UI tests, which is the guard
itself (the classes before it show the scan does flag one: a test that passes without the scan would guard nothing).
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import app_test_negative_sleeps as sleeps  # noqa: E402


def flagged(source):
    return sleeps.flagged(sleeps.scan_source(source))


class WhichSleepsAreFlagged(unittest.TestCase):
    def test_the_handoff_sleep_named_in_4313_is_flagged(self):
        source = ('    func testAReplacedLink() async throws {\n'
                  '        // Give the replaced task time to reach its catch on the main actor.\n'
                  '        try await Task.sleep(for: .milliseconds(200))\n'
                  '\n'
                  '        XCTAssertEqual(failures.second, ["This link has expired."])\n'
                  '        XCTAssertEqual(failures.first, [], "the replaced link must not show an error")\n')
        found = flagged(source)
        self.assertEqual([(f['line'], f['func']) for f in found], [(3, 'testAReplacedLink')])
        self.assertIn('failures.first', found[0]['asserts'])

    def test_neighbouring_spellings_of_the_same_sleep_are_all_flagged(self):
        cases = {
            'nil': 'try await Task.sleep(for: .milliseconds(500))\nXCTAssertNil(model.marginMoment)',
            'false': 'try await Task.sleep(for: .milliseconds(300))\nXCTAssertFalse(log.contains("stall"))',
            'empty array': 'try await Task.sleep(for: .milliseconds(100))\nXCTAssertEqual(log.feeds, [], "nothing was followed")',
            'zero': 'try await Task.sleep(for: .milliseconds(100))\nXCTAssertEqual(requests.value, 0)',
            'isEmpty': 'try await Task.sleep(for: .milliseconds(300))\nXCTAssertTrue(log.values.isEmpty, "\\(log.values)")',
            'try?': 'try? await Task.sleep(for: .milliseconds(300))\nXCTAssertNil(x)',
            'nanoseconds': 'try await Task.sleep(nanoseconds: 300_000_000)\nXCTAssertNil(x)',
            'Thread.sleep in a UI test': 'Thread.sleep(forTimeInterval: 3)\nXCTAssertTrue(confirm.exists, "The End sheet closed by itself")',
            'usleep': 'usleep(300_000)\nXCTAssertFalse(done)',
            'the negative one after a positive one': 'try await Task.sleep(for: .milliseconds(400))\nXCTAssertEqual(model.snapshot.status, .paused)\nXCTAssertNil(model.marginMoment)',
            'comments and blanks between': 'try await Task.sleep(for: .milliseconds(400))\n\n// the review must not start\nXCTAssertNil(model.marginMoment)',
            'a message that says never': 'try await Task.sleep(for: .milliseconds(400))\nXCTAssertEqual(count, 1, "the second tap never plays")',
            'tabs': '\ttry await Task.sleep(for: .milliseconds(400))\n\tXCTAssertNil(x)',
            '_ = try? in front': '_ = try? await Task.sleep(for: .milliseconds(300))\nXCTAssertNil(x)',
            'a clock': 'try await ContinuousClock().sleep(for: .milliseconds(300))\nXCTAssertNil(x)',
            'C sleep': 'sleep(1)\nXCTAssertNil(x)',
            'a run loop': 'RunLoop.main.run(until: Date().addingTimeInterval(1.5))\nXCTAssertNil(record.firstHeardAt)',
            'an XCTWaiter wait': '_ = XCTWaiter().wait(for: [XCTestExpectation(description: "pause")], timeout: 1)\nXCTAssertFalse(sheet.exists)',
            'an empty dictionary': 'try await Task.sleep(for: .milliseconds(300))\nXCTAssertEqual(model.drafts, [:])',
            'empty first': 'try await Task.sleep(for: .milliseconds(300))\nXCTAssertEqual([], log.values)',
            'XCTAssert isEmpty': 'try await Task.sleep(for: .milliseconds(300))\nXCTAssert(log.values.isEmpty)',
            "a message with n't": 'try await Task.sleep(for: .milliseconds(300))\nXCTAssertEqual(starts, 1, "the voice didn\'t start again")',
            'a message with not': 'try await Task.sleep(for: .milliseconds(300))\nXCTAssertEqual(state, .playing, "a citation list is not a stall")',
        }
        for name, source in cases.items():
            with self.subTest(name):
                self.assertEqual(len(flagged(source + '\n')), 1, source)

    def test_waits_on_a_signal_and_positive_checks_are_not_flagged(self):
        cases = {
            'the shared wait': 'try await pollUntil { task.finished }\nXCTAssertNil(model.marginMoment)',
            'a sleep before a positive check': 'try await Task.sleep(for: .milliseconds(400))\nXCTAssertEqual(model.snapshot.status, .playing)',
            'a sleep before other code': 'try await Task.sleep(for: .milliseconds(400))\nmodel.pause()\nXCTAssertNil(model.marginMoment)',
            'a sleep in a poll loop': 'while !done { try await Task.sleep(for: .milliseconds(20)) }\nXCTAssertNil(x)',
            'a sleep inside a closure': 'let t = Task { try? await Task.sleep(for: .seconds(30)) }\nXCTAssertNil(x)',
            'a positive message': 'try await Task.sleep(for: .milliseconds(400))\nXCTAssertEqual(count, 1, "the tap plays")',
        }
        for name, source in cases.items():
            with self.subTest(name):
                self.assertEqual(flagged(source + '\n'), [], source)

    def test_a_written_reason_exempts_the_sleep(self):
        cases = {
            'on the line': 'Thread.sleep(forTimeInterval: 3) // fixed-sleep ok: the claim is three seconds\nXCTAssertFalse(x)',
            'in the comment block above': '// The claim is about three seconds of nothing.\n// fixed-sleep ok: no signal marks the end\nThread.sleep(forTimeInterval: 3)\nXCTAssertFalse(x)',
        }
        for name, source in cases.items():
            with self.subTest(name):
                found = sleeps.scan_source(source + '\n')
                self.assertEqual([f['exempt'] for f in found], [True])
        broken = '// fixed-sleep ok: an old reason\nmodel.tick()\nThread.sleep(forTimeInterval: 3)\nXCTAssertFalse(x)\n'
        self.assertEqual(len(flagged(broken)), 1, 'a reason above other code does not carry down to the sleep')


class TheBaseline(unittest.TestCase):
    SOURCE = ('    func testOne() async throws {\n'
              '        try await Task.sleep(for: .milliseconds(300))\n'
              '        XCTAssertNil(model.marginMoment)\n'
              '    }\n')

    def run_scan(self, source, baseline):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'NewTests.swift').write_text(source)
            listed = Path(folder) / 'baseline.json'
            listed.write_text(json.dumps(baseline))
            return sleeps.main(['--folder', folder, '--baseline', str(listed)])

    def test_a_listed_sleep_passes_and_a_new_one_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            name = Path(folder).name
            (Path(folder) / 'NewTests.swift').write_text(self.SOURCE)
            listed = Path(folder) / 'baseline.json'
            listed.write_text(json.dumps({f'{name}/NewTests.swift::testOne': 1}))
            self.assertEqual(sleeps.main(['--folder', folder, '--baseline', str(listed)]), 0)
            second = self.SOURCE.replace('    }\n', '        try await Task.sleep(for: .milliseconds(300))\n'
                                                   '        XCTAssertFalse(done)\n    }\n')
            (Path(folder) / 'NewTests.swift').write_text(second)
            self.assertEqual(sleeps.main(['--folder', folder, '--baseline', str(listed)]), 1,
                             'a second sleep in a listed test is new')

    def test_an_unlisted_sleep_fails(self):
        self.assertEqual(self.run_scan(self.SOURCE, {}), 1)

    def test_update_only_shrinks_the_baseline(self):
        two = self.SOURCE.replace('    }\n', '        try await Task.sleep(for: .milliseconds(300))\n'
                                           '        XCTAssertFalse(done)\n    }\n')
        with tempfile.TemporaryDirectory() as folder:
            name = Path(folder).name
            (Path(folder) / 'NewTests.swift').write_text(two)
            listed = Path(folder) / 'baseline.json'
            listed.write_text(json.dumps({f'{name}/NewTests.swift::testOne': 1, f'{name}/Gone.swift::testGone': 2}))
            self.assertEqual(sleeps.main(['--folder', folder, '--baseline', str(listed), '--update']), 1,
                             'the second sleep is still new after an update')
            self.assertEqual(json.loads(listed.read_text()), {f'{name}/NewTests.swift::testOne': 1})

    def test_a_fixed_listed_test_must_be_dropped_from_the_baseline(self):
        fixed = self.SOURCE.replace('try await Task.sleep(for: .milliseconds(300))', 'try await pollUntil { done }')
        with tempfile.TemporaryDirectory() as folder:
            name = Path(folder).name
            self.assertEqual(self.run_scan(fixed, {f'{name}/NewTests.swift::testOne': 1}), 1)


class TheAppTests(unittest.TestCase):
    def test_no_new_fixed_sleep_before_a_negative_assertion(self):
        new, stale = sleeps.compare(sleeps.scan_tree(), sleeps.load_baseline())
        self.assertEqual(
            [f'{f["file"]}:{f["line"]}' for f in new], [],
            'Wait for the signal that would have caused the event, not a fixed time; a sleep that is the point carries '
            '`// fixed-sleep ok: <why>` (#4313)')
        self.assertEqual(stale, [], 'these tests no longer have their listed sleeps: run '
                                    'scripts/app_test_negative_sleeps.py --update to shrink the baseline')

    def test_the_sleeps_named_in_4313_are_gone_or_carry_their_reason(self):
        named = {'SpokenMarginsAppTests/SpokenMarginsPackageHandoffTests.swift',
                 'SpokenMarginsAppTests/WrittenMarginTapAppTests.swift',
                 'SpokenMarginsAppTests/SharedMarginReturnAppTests.swift',
                 'SpokenMarginsAppTests/CatalogDrawerTests.swift',
                 'SpokenMarginsAppTests/Gate2CompactControlTests.swift',
                 'SpokenMarginsAppUITests/Gate1FlowUITests.swift'}
        listed = {key.split('::')[0] for key in sleeps.load_baseline()}
        self.assertEqual(sorted(named & listed), [], 'the files #4313 names keep no unexplained sleep in the baseline')
        tests = {f'SpokenMarginsAppTests/SupertonicSpeechTests.swift::{name}' for name in (
            'testPauseInsideASplitCitationResumesTheCurrentChunk', 'testPlayAndRateChangeWhilePlayingKeepTheLiveAudio',
            'testASeekWhileTheIOSVoiceHasNotBegunEndsTheWaitAndPlaysOn',
            'testAPlayWhileTheIOSVoiceHasNotBegunStaysWithItWhenTheChosenVoiceMayNotRender',
            'testAStallSampledBeforeTheListenerPlaysTheIOSVoiceAgainLeavesItAlone', 'testAStopDuringAnUncachedRenderDeletesItsFile')}
        tests.add('SpokenMarginsAppTests/WatchContractAppTests.swift::testTheBoardGoesOutOnceMoreAfterATransportCommandEvenWhenNothingChanged')
        self.assertEqual(sorted(tests & set(sleeps.load_baseline())), [], 'the tests #4313 names keep no unexplained sleep')


if __name__ == '__main__':
    unittest.main()
