"""scripts/diagnostics_hangs.py: every hang and kill from the owner's Diagnostics exports, counted once (#2259)."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import diagnostics_hangs as dh  # noqa: E402


def event(time, kind, elapsed, **fields):
    return {'time': time, 'kind': kind, 'elapsedMs': elapsed, 'fields': fields}


def hang(time, elapsed, ms, screen='home', operation='none', **extra):
    return event(time, 'main.hang', elapsed, durationMs=str(ms), screen=screen, operation=operation,
                 status='paused', lastTap='none', **extra)


def write_export(folder, name, build, exported_at, events, memory=''):
    path = Path(folder) / name
    path.write_text(json.dumps({
        'developerBuild': build, 'exportedAt': exported_at, 'memoryFootprint': memory,
        'playbackEvents': json.dumps({'captureID': 'x', 'events': events}),
    }))
    return path


class Report(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        shared = [
            event('2026-10-20T10:00:00.000Z', 'app.foreground', 100, status='paused'),
            hang('2026-10-20T10:00:01.000Z', 1100, 600, operation='loadLibraryRows'),
            hang('2026-10-20T10:00:02.000Z', 2100, 400, operation='loadLibraryRows'),
        ]
        first = shared + [
            event('2026-10-20T10:00:03.000Z', 'app.background', 3100, status='paused'),
        ]
        # The second export overlaps the first: the same three events, then a new launch and its MetricKit report.
        second = shared + [
            event('2026-10-20T10:00:03.000Z', 'app.background', 3100, status='paused'),
            event('2026-10-20T11:00:00.000Z', 'app.previous_exit', 50, reason='background_cpu_limit,foreground_watchdog',
                  bgCpuLimit='5', fgWatchdog='1', source='metrickit', exitsPeriod='2026-10-19 to 2026-10-20'),
            event('2026-10-20T11:00:00.500Z', 'app.previous_exit', 60, reason='cpu_exception', cpuExceptions='1',
                  crashes='0', hangs='0', source='metrickit'),
            event('2026-10-20T11:00:00.600Z', 'app.previous_exit', 70, reason='none_reported', source='metrickit'),
            hang('2026-10-20T11:00:01.000Z', 1000, 3000, screen='playback'),
        ]
        memory_a = '10-20 10:00:00Z launch none 6MB | 10-20 10:01:00Z playback text 400MB free 3000MB'
        memory_b = '10-20 10:01:00Z playback text 400MB free 3000MB | 10-20 11:01:00Z playback text 500MB | junk'
        self.paths = [
            write_export(self.folder, 'Spoken Margins diagnostics a.json', '0.1 (35) · b039c32',
                         '2026-10-20T10:05:00Z', first, memory_a),
            write_export(self.folder, 'Spoken_Margins_diagnostics_b.json', '0.1 (35) · b039c32',
                         '2026-10-20T11:05:00Z', second, memory_b),
        ]
        exports = sorted((dh.load_export(p) for p in self.paths), key=lambda e: e.exported_at)
        self.report = dh.build_report(exports, {'b039c32': 'yes'})

    def test_finds_both_naming_forms(self):
        self.assertEqual(dh.find_exports(Path(self.folder)), sorted(self.paths))

    def test_overlapping_exports_count_each_hang_once(self):
        self.assertEqual(self.report['raw_events'], 12)
        self.assertEqual([h['durationMs'] for h in self.report['hangs']], [600, 400, 3000])

    def test_summary_by_screen_and_operation(self):
        pairs = {(r['screen'], r['operation']): r for r in self.report['by_pair']}
        library = pairs[('home', 'loadLibraryRows')]
        self.assertEqual((library['count'], library['medianMs'], library['worstMs'], library['totalMs']),
                         (2, 500, 600, 1000))
        # Ranked by total frozen time: one 3 s hang beats two short ones.
        self.assertEqual(self.report['by_pair'][0]['screen'], 'playback')

    def test_hang_rows_carry_the_three_events_before(self):
        last = self.report['hangs'][-1]
        self.assertEqual(last['context'].split(' ; ')[0], 'app.previous_exit(reason=none_reported)')
        self.assertEqual(len(last['context'].split(' ; ')), 3)
        self.assertEqual(self.report['hangs'][0]['context'], 'app.foreground(status=paused)')

    def test_kills_skip_none_reported_and_name_what_came_before(self):
        kills = self.report['kills']
        self.assertEqual([k['kind'] for k in kills], ['watchdog', 'cpu'])
        self.assertEqual(kills[0]['exits'], 6)
        self.assertEqual(kills[0]['watchdogCount'], 1)
        self.assertEqual(kills[1]['exits'], 0)
        self.assertTrue(kills[0]['hangBefore'].startswith('2026-10-20T10:00:02.000Z main.hang'))
        self.assertTrue(kills[0]['awayBefore'].startswith('2026-10-20T10:00:03.000Z app.background'))

    def test_memory_readings_are_parsed_and_deduplicated(self):
        memory = self.report['memory']
        self.assertEqual([m['footprintMB'] for m in memory], [6, 400, 500])
        self.assertEqual(memory[1]['time'], '2026-10-20T10:01:00Z')
        self.assertEqual(memory[1]['freeMB'], '3000')

    def test_build_is_sure_only_inside_a_known_run(self):
        self.assertEqual({h['build_sure'] for h in self.report['hangs']}, {'yes'})
        older = write_export(self.folder, 'Spoken Margins diagnostics c.json', '0.1 (36) · abcdef1',
                             '2026-10-21T09:00:00Z', [
                                 hang('2026-10-20T09:00:00.000Z', 5000, 700),
                                 event('2026-10-21T08:59:00.000Z', 'app.foreground', 10, status='idle'),
                             ])
        exports = [dh.load_export(older)]
        rows = dh.build_report(exports, {})['hangs']
        self.assertEqual(rows[0]['build_sure'], 'no')

    def test_summary_names_top_pairs_watchdogs_and_gaps(self):
        text = dh.render_summary(self.report)
        self.assertIn('Top 5 screen × operation', text)
        self.assertIn('**6 exits**', text)
        self.assertIn('**1 watchdog-shaped**', text)
        self.assertIn('1 CPU-exception reports', text)
        self.assertIn("What this data can't show", text)

    def test_exports_read_table_names_each_exports_budget_word(self):
        self.assertEqual([dh.budget_word(w) for w in (
            'hangs=0 skipped=0 budget=ok',
            'hangs=2 skipped=0 longestHangMs=640 budget=broken(hang,tap)',
            '', 'no such field')], ['ok', 'broken(hang,tap)', '–', '–'])
        path = Path(self.folder) / 'Spoken Margins diagnostics d.json'
        path.write_text(json.dumps({
            'developerBuild': '0.1 (36) · abcdef1', 'exportedAt': '2026-10-22T09:00:00Z',
            'responsiveness': 'hangs=1 skipped=0 longestHangMs=900 budget=broken(hang)',
            'playbackEvents': json.dumps({'events': [hang('2026-10-22T08:00:00.000Z', 10, 900)]})}))
        text = dh.render_summary(dh.build_report([dh.load_export(path)], {'abcdef1': 'yes'}))
        self.assertIn('broken(hang)', text.split('### Exports read')[1].split("### What this data")[0])
        self.assertNotIn('broken(hang)', dh.render_summary(self.report))

    def test_watchdog_shapes(self):
        rows = [
            ({'reason': 'foreground_watchdog', 'fgWatchdog': '2'}, 'watchdog', 2),
            ({'reason': 'background_watchdog', 'bgWatchdog': '1'}, 'watchdog', 1),
            ({'reason': 'crash', 'crashes': '1', 'crashTermination': 'Namespace FRONTBOARD, Code 0x8badf00d'},
             'watchdog', 1),
            # A MetricKit hang report is not a kill: the app lived through it.
            ({'reason': 'hang', 'hangs': '3'}, 'other', 0),
            ({'reason': 'crash', 'crashes': '1', 'crashSignal': 'SIGSEGV'}, 'crash', 0),
            ({'reason': 'background_memory_pressure', 'bgMemoryPressure': '2'}, 'memory', 0),
        ]
        for fields, kind, watchdogs in rows:
            with self.subTest(fields=fields):
                self.assertEqual(dh.kill_kind(fields), kind)
                self.assertEqual(dh.watchdog_count(fields), watchdogs)

    def test_a_day_reported_twice_counts_once(self):
        day = dict(reason='foreground_watchdog', source='metrickit', exitsPeriod='2026-10-19 to 2026-10-20')
        events = [
            dh.Event('2026-10-20T10:00:00Z', 'app.previous_exit', {**day, 'fgWatchdog': '1'}, 1),
            dh.Event('2026-10-20T12:00:00Z', 'app.previous_exit', {**day, 'fgWatchdog': '2'}, 1),
            dh.Event('2026-10-21T10:00:00Z', 'app.previous_exit',
                     {**day, 'exitsPeriod': '2026-10-20 to 2026-10-21', 'fgWatchdog': '1'}, 1),
        ]
        self.assertEqual(dh.total_exits(events), {'fgWatchdog': 3})

    def test_build_is_sure_after_an_earlier_export_of_the_same_build(self):
        earlier = write_export(self.folder, 'Spoken Margins diagnostics d.json', '0.1 (36) · abcdef1',
                               '2026-10-20T08:00:00Z', [event('2026-10-20T07:59:00.000Z', 'app.foreground', 5)])
        later = write_export(self.folder, 'Spoken Margins diagnostics e.json', '0.1 (36) · abcdef1',
                             '2026-10-21T09:00:00Z', [
                                 hang('2026-10-20T09:00:00.000Z', 5000, 700),
                                 event('2026-10-21T08:59:00.000Z', 'app.foreground', 10, status='idle'),
                             ])
        exports = [dh.load_export(earlier), dh.load_export(later)]
        self.assertEqual(dh.build_report(exports, {})['hangs'][0]['build_sure'], 'yes')

    def test_a_december_reading_in_a_january_export_keeps_its_year(self):
        path = write_export(self.folder, 'Spoken Margins diagnostics f.json', '0.1 (40) · abcdef2',
                            '2027-01-01T01:00:00Z', [], '12-31 23:59:00Z playback text 300MB | '
                                                        '01-01 00:30:00Z playback text 310MB')
        times = [m['time'] for m in dh.memory_rows([dh.load_export(path)])]
        self.assertEqual(times, ['2026-12-31T23:59:00Z', '2027-01-01T00:30:00Z'])

    def test_summary_lists_builds_without_the_probe(self):
        self.report['probe'] = {'b039c32': 'no'}
        text = dh.render_summary(self.report)
        self.assertIn('record no `main.hang` at all: `b039c32`', text)

    def test_parse_build(self):
        rows = [
            ('0.1 (35) · b039c32', ('35', 'b039c32')),
            ('0.1 (32)', ('32', '?')),
            ('', ('?', '?')),
        ]
        for text, expected in rows:
            with self.subTest(text=text):
                self.assertEqual(dh.parse_build(text), expected)

    def test_main_writes_tables_and_leaves_exports_alone(self):
        before = {p: p.read_bytes() for p in self.paths}
        out = Path(self.folder) / 'out'
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dh.main([*map(str, self.paths), '--out', str(out), '--no-git']), 0)
        for name in ('hangs.csv', 'kills.csv', 'memory.csv', 'by-build-screen-operation.csv', 'summary.md'):
            self.assertTrue((out / name).exists(), name)
        self.assertEqual({p: p.read_bytes() for p in self.paths}, before)


if __name__ == '__main__':
    unittest.main()
