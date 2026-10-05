import sys
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_posterboard_repair import crash_snapshot, new_crash, poster_state, supervise


class PosterRepairTests(unittest.TestCase):
    def run_probe(self, crash=lambda: None, state=lambda: {'complete': True}):
        self.events = []
        self.now = 0

        def sleep(seconds):
            self.now += 1

        return supervise(lambda: self.events.append('boot'),
                         lambda: self.events.append('shutdown'), crash, state,
                         clock=lambda: self.now, sleep=sleep,
                         timeout=10, stable_seconds=3)

    def test_success_requires_stable_state_and_shuts_down(self):
        result = self.run_probe()
        self.assertEqual(result['status'], 'verified')
        self.assertEqual(self.now, 3)
        self.assertEqual(self.events, ['boot', 'shutdown'])

    def test_first_crash_stops_without_retry(self):
        result = self.run_probe(crash=lambda: Path('crash.ips'))
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(self.now, 0)
        self.assertEqual(self.events, ['boot', 'shutdown'])

    def test_incomplete_state_times_out_and_shuts_down(self):
        result = self.run_probe(state=lambda: {'complete': False})
        self.assertEqual(result['status'], 'incomplete')
        self.assertEqual(self.events, ['boot', 'shutdown'])

    def test_interruption_still_shuts_down(self):
        def interrupted():
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.run_probe(state=interrupted)
        self.assertEqual(self.events, ['boot', 'shutdown'])

    def test_old_and_other_device_reports_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / 'WidgetRenderer_Default.ips'
            report.write_text('com.apple.CoreSimulator.SimDevice.target')
            baseline = {report: (report.stat().st_mtime_ns, report.stat().st_size)}
            (root / 'PosterBoard-other.ips').write_text('com.apple.CoreSimulator.SimDevice.other')
            self.assertIsNone(new_crash(root, baseline, 'target'))
            report.write_text('new com.apple.CoreSimulator.SimDevice.target')
            self.assertEqual(new_crash(root, baseline, 'target'), report)

    def test_hidden_and_vanished_reports_do_not_abort_the_check(self):
        # Codex audit on #824: macOS writes each report as a hidden `.Name-date.ips` and then renames
        # it, so a report can vanish between the glob and the stat (#822). The check uses lane_sim's
        # guarded scans instead of its own copies.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.PosterBoard-2026-10-04-095145.ips').write_text('com.apple.CoreSimulator.SimDevice.target')
            self.assertEqual(crash_snapshot(root), {})
            self.assertIsNone(new_crash(root, {}, 'target'), 'a report still being written is not a crash yet')

            class VanishingFolder:
                def is_dir(self):
                    return True

                def glob(self, pattern):
                    found = list(root.glob(pattern))
                    for path in found:
                        path.unlink()
                    return iter(found)

            self.assertEqual(crash_snapshot(VanishingFolder()), {})
            self.assertIsNone(new_crash(VanishingFolder(), {}, 'target'))

    def test_missing_descriptor_prevents_recovery_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index in range(7):
                provider = 'com.apple.ClockPoster.ClockPosterExtension' if index < 5 else 'other'
                path = root / '61' / 'Extensions' / provider / 'configurations' / str(index)
                path.mkdir(parents=True)
                (path / 'com.apple.posterkit.provider.descriptor.identifier').write_text(str(index))
            self.assertTrue(poster_state(root)['complete'])
            next(root.glob('*/Extensions/*/configurations/*/com.apple.posterkit.provider.descriptor.identifier')).unlink()
            self.assertFalse(poster_state(root)['complete'])


if __name__ == '__main__':
    unittest.main()
