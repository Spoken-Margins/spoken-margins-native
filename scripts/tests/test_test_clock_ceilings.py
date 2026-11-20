"""scripts/test_clock_ceilings.py: no new wall-clock ceiling in a Swift test unless it is a listed performance budget (#4573).

The tables below are neighbouring spellings of one ceiling, each saying whether it is flagged. The #4743 class shows the
guard flags the test that held the merge queue on 2026-11-20 and passes the state check that replaced it (#4760). The
allowlist class shows a listed test passes, an unlisted one fails and a stale entry fails. The last class runs the scan
over every Swift test folder, which is the guard itself.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import test_clock_ceilings as ceilings  # noqa: E402


def found(body, name='testOne'):
    return ceilings.scan_source(f'    func {name}() throws {{\n' + body + '\n    }\n')


class TheCaseThatHeldTheMergeQueue(unittest.TestCase):
    """#4743's LibraryFolderQueryTests check, as it was, and as #4760 rewrote it."""

    BEFORE = '''    func testTheSnapshotCarriesCollectionsAndFolderRecordsWhileAWriterHoldsTheStore() throws {
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK, "another writer holds the store")
        defer { sqlite3_exec(writer, "COMMIT", nil, nil, nil); sqlite3_close(writer) }

        let started = Date()
        let snapshot = try LibraryReadSnapshot.read(store: store)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the Library read does not wait for the writer")
        XCTAssertEqual(snapshot.collections?.map(\\.id), ["f"])
    }
'''
    AFTER = '''    func testTheSnapshotCarriesCollectionsAndFolderRecordsWhileAWriterHoldsTheStore() throws {
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK, "another writer holds the store")
        defer { sqlite3_exec(writer, "COMMIT", nil, nil, nil); sqlite3_close(writer) }

        let snapshot = try LibraryReadSnapshot.read(store: store)
        XCTAssertEqual(sqlite3_get_autocommit(writer), 0, "the writer still held the store while the Library was read")
        XCTAssertEqual(snapshot.collections?.map(\\.id), ["f"], "the collections were read past the writer")
    }
'''

    def test_the_2_second_read_is_flagged(self):
        hits = ceilings.scan_source(self.BEFORE)
        self.assertEqual([(h['line'], h['func']) for h in hits],
                         [(7, 'testTheSnapshotCarriesCollectionsAndFolderRecordsWhileAWriterHoldsTheStore')])

    def test_the_state_check_that_replaced_it_is_not(self):
        self.assertEqual(ceilings.scan_source(self.AFTER), [])

    def test_it_fails_the_guard_unless_listed(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / 'Pkg' / 'Tests'
            folder.mkdir(parents=True)
            (folder / 'LibraryFolderQueryTests.swift').write_text(self.BEFORE)
            allowlist = Path(root) / 'allow.json'
            allowlist.write_text('{}')
            self.assertEqual(ceilings.main(['--folder', str(folder), '--allowlist', str(allowlist)]), 1)
            (folder / 'LibraryFolderQueryTests.swift').write_text(self.AFTER)
            self.assertEqual(ceilings.main(['--folder', str(folder), '--allowlist', str(allowlist)]), 0)


class WhichCeilingsAreFlagged(unittest.TestCase):
    def test_neighbouring_spellings_are_all_flagged(self):
        cases = {
            'Date then timeIntervalSince': 'let started = Date()\nwork()\nXCTAssertLessThan(Date().timeIntervalSince(started), 2)',
            'Date.now': 'let started = Date.now\nwork()\nXCTAssertLessThan(Date.now.timeIntervalSince(started), 2)',
            'an elapsed variable': 'let t0 = Date()\nwork()\nlet elapsed = Date().timeIntervalSince(t0)\nXCTAssertLessThan(elapsed, 5, "took \\(elapsed) s")',
            'or equal': 'let began = Date()\nwork()\nXCTAssertLessThanOrEqual(Date().timeIntervalSince(began), 0.5)',
            'ContinuousClock minus a start': 'let started = ContinuousClock.now\nwork()\nXCTAssertLessThan(ContinuousClock.now - started, .seconds(5))',
            'SuspendingClock': 'let started = SuspendingClock.now\nwork()\nXCTAssertLessThan(SuspendingClock.now - started, .seconds(5))',
            'systemUptime': 'let begin = ProcessInfo.processInfo.systemUptime\nwork()\nXCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 1)',
            'CFAbsoluteTime': 'let start = CFAbsoluteTimeGetCurrent()\nwork()\nlet took = CFAbsoluteTimeGetCurrent() - start\nXCTAssertLessThan(took, 1)',
            'DispatchTime nanoseconds': 'let start = DispatchTime.now().uptimeNanoseconds\nwork()\nXCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 1_000_000)',
            'a start with a type': 'let started: Date = Date()\nwork()\nXCTAssertLessThan(Date().timeIntervalSince(started), 2)',
            'a clock measure': 'let clock = ContinuousClock()\nlet elapsed = clock.measure { work() }\nXCTAssertLessThan(elapsed, .milliseconds(5))',
            'derived through an array': 'let clock = ContinuousClock()\nvar ms: [Double] = []\nlet elapsed = clock.measure { work() }\nms.append(Double(elapsed.components.seconds)\n    + 1)\nlet sorted = ms.sorted()\nXCTAssertLessThan(sorted[1], 5)',
            'greater-than written the other way': 'let started = Date()\nwork()\nXCTAssertGreaterThan(2, Date().timeIntervalSince(started))',
            'XCTAssert with <': 'let started = Date()\nwork()\nXCTAssert(Date().timeIntervalSince(started) < 2)',
            '#expect with <=': 'let started = Date()\nwork()\n#expect(Date().timeIntervalSince(started) <= 2)',
            'over two lines': 'let started = Date()\nwork()\nXCTAssertLessThan(\n    Date().timeIntervalSince(started),\n    2\n)',
            'a ratio of two timings': 'let a = Date()\nfast()\nlet fastTook = Date().timeIntervalSince(a)\nlet b = Date()\nslow()\nlet slowTook = Date().timeIntervalSince(b)\nXCTAssertLessThan(fastTook, slowTook * 0.8)',
            'an instance clock': 'let clock = ContinuousClock()\nlet started = clock.now\nwork()\nXCTAssertLessThan(clock.now - started, .seconds(1))',
            'CACurrentMediaTime': 'let start = CACurrentMediaTime()\nwork()\nXCTAssertLessThan(CACurrentMediaTime() - start, 1)',
            'a helper handed the start': 'let begin = DispatchTime.now()\nwork()\nlet small = elapsed(since: begin)\nXCTAssertLessThan(small, big / 2)',
            'a min of best times': 'var best = Double.infinity\nfor _ in 0..<5 {\n    let start = Date()\n    work()\n    best = min(best, Date().timeIntervalSince(start))\n}\nXCTAssertLessThan(best, 1)',
        }
        for name, body in cases.items():
            with self.subTest(name):
                self.assertEqual(len(found(body)), 1, body)

    def test_lower_bounds_timestamps_and_fake_clocks_are_not_flagged(self):
        cases = {
            'a lower bound': 'let started = Date()\nwork()\nXCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1, "it waited")',
            'a stored timestamp near now': 'let record = save()\nXCTAssertLessThan(abs(record.failedAt.timeIntervalSinceNow), 60)',
            'a stored timestamp, Date() form': 'let renewed = renew()\nXCTAssertLessThan(Date().timeIntervalSince(renewed.checkedAt), 60)',
            'a fake clock the test advances': 'var elapsed: TimeInterval = 0\npace(now: { elapsed }, sleep: { elapsed += $0 })\nXCTAssertLessThan(elapsed, delay + 2.1)',
            'a duration that is data': 'let duration = item.duration\nXCTAssertLessThan(duration, 60)',
            'a start handed to a maker': 'let started = Date()\nlet item = make(createdAt: started)\nXCTAssertLessThan(item.count, 3)',
            'a start never compared': 'let started = Date()\nlet item = make(createdAt: started)\nXCTAssertLessThan(item.count, 3)',
            'an expectation with a ceiling': 'let done = expectation(description: "done")\nwork { done.fulfill() }\nwait(for: [done], timeout: 30)',
            'a comment that mentions it': '// XCTAssertLessThan(Date().timeIntervalSince(started), 2) used to be here\nXCTAssertEqual(x, 1)',
        }
        for name, body in cases.items():
            with self.subTest(name):
                self.assertEqual(found(body), [], body)

    def test_each_func_has_its_own_starts(self):
        source = ('    func testOne() {\n        let started = Date()\n        work()\n    }\n'
                  '    func testTwo() {\n        let renewed = renew()\n'
                  '        XCTAssertLessThan(Date().timeIntervalSince(started), 60)\n    }\n')
        self.assertEqual(ceilings.scan_source(source), [], 'a start in one test does not make a duration in the next')


class TheAllowlist(unittest.TestCase):
    SOURCE = ('    func testBig() {\n        let started = Date()\n        work()\n'
              '        XCTAssertLessThan(Date().timeIntervalSince(started), 5)\n    }\n')

    def run_scan(self, source, allowlist):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / 'Pkg' / 'Tests'
            folder.mkdir(parents=True)
            (folder / 'BigTests.swift').write_text(source)
            listed = Path(root) / 'allow.json'
            listed.write_text(json.dumps(allowlist))
            return ceilings.main(['--folder', str(folder), '--allowlist', str(listed)])

    def test_a_listed_budget_passes(self):
        self.assertEqual(self.run_scan(self.SOURCE, {'Pkg/Tests/BigTests.swift::testBig': 'a quadratic scan'}), 0)

    def test_an_unlisted_ceiling_fails(self):
        self.assertEqual(self.run_scan(self.SOURCE, {}), 1)

    def test_listing_one_test_does_not_cover_another_in_the_same_file(self):
        two = self.SOURCE + self.SOURCE.replace('testBig', 'testOther')
        self.assertEqual(self.run_scan(two, {'Pkg/Tests/BigTests.swift::testBig': 'a quadratic scan'}), 1)

    def test_a_stale_entry_fails(self):
        fixed = self.SOURCE.replace('        XCTAssertLessThan(Date().timeIntervalSince(started), 5)\n', '')
        self.assertEqual(self.run_scan(fixed, {'Pkg/Tests/BigTests.swift::testBig': 'a quadratic scan'}), 1)


class TheSwiftTests(unittest.TestCase):
    def test_the_scan_reaches_every_swift_test_folder(self):
        names = {f'{folder.parent.name}/{folder.name}' for folder in ceilings.default_folders()}
        self.assertIn('SessionKit/Tests', names)
        self.assertIn('App/SpokenMarginsAppTests', names)
        self.assertIn('App/SpokenMarginsAppUITests', names)

    def test_every_listed_budget_says_what_it_guards(self):
        for name, reason in ceilings.load_allowlist().items():
            with self.subTest(name):
                self.assertIn('::test', name)
                self.assertGreater(len(reason.split()), 4, 'say the ceiling, the local time and the scaling bug it guards')

    def test_no_wall_clock_ceiling_outside_the_allowlist(self):
        new, stale = ceilings.compare(ceilings.scan_tree(), ceilings.load_allowlist())
        self.assertEqual(
            [f'{f["file"]}:{f["line"]} {f["func"]}' for f in new], [],
            'Prove "it did not wait" on state (a gate the test holds, an expectation), not on a clock; a real '
            'performance budget is listed with its reason in scripts/test_clock_ceilings_allowlist.json (#4573)')
        self.assertEqual(stale, [], 'these listed tests have no ceiling now: remove them from the allowlist')


if __name__ == '__main__':
    unittest.main()
