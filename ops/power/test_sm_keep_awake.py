import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_keep_awake as ka  # noqa: E402

ON_POWER = """Now drawing from 'AC Power'
 -InternalBattery-0 (id=24182883)\t100%; charged; 0:00 remaining present: true
"""
ON_BATTERY_9 = """Now drawing from 'Battery Power'
 -InternalBattery-0 (id=24182883)\t9%; discharging; 0:31 remaining present: true
"""
NWI_UP = """IPv4 network interface information
     en0 : flags      : 0x5 (IPv4,DNS)
           reach      : 0x00000002 (Reachable)

   REACH : flags 0x00000002 (Reachable)

IPv6 network interface information
   No IPv6 states found

   REACH : flags 0x00000000 (Not Reachable)
"""
NWI_DOWN = """IPv4 network interface information
   No IPv4 states found
   REACH : flags 0x00000000 (Not Reachable)
"""


class ParseTests(unittest.TestCase):
    def test_battery(self):
        self.assertEqual(ka.parse_battery(ON_POWER), (False, 100))
        self.assertEqual(ka.parse_battery(ON_BATTERY_9), (True, 9))
        self.assertEqual(ka.parse_battery("Now drawing from 'AC Power'\n"), (False, None))

    def test_network(self):
        self.assertTrue(ka.network_reachable(NWI_UP))
        self.assertFalse(ka.network_reachable(NWI_DOWN))

    def test_build_processes_by_exact_name(self):
        ps = '\n'.join([
            'COMM',
            '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild',
            '/Users/me/actions-runner-spoken-margins-2/bin/Runner.Worker',
            '/Users/me/actions-runner-spoken-margins/bin/Runner.Listener',
            '/usr/bin/swift-frontend',
            '/usr/bin/swift-frontend',
            '/Users/me/bin/claude',
        ])
        self.assertEqual(ka.build_processes(ps), ['xcodebuild', 'Runner.Worker', 'swift-frontend'])


class TranscriptAgeTests(unittest.TestCase):
    def test_newest_jsonl_wins_and_other_files_are_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = root / 'project' / 'old.jsonl'
            new = root / 'project' / 'session' / 'subagents' / 'agent.jsonl'
            other = root / 'project' / 'notes.txt'
            for path in (old, new, other):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('x')
            now = time.time()
            os.utime(old, (now - 3600, now - 3600))
            os.utime(new, (now - 120, now - 120))
            os.utime(other, (now, now))
            age = ka.newest_transcript_age([root, root / 'missing'], now)
            self.assertAlmostEqual(age, 120, delta=1)

    def test_no_transcripts(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(ka.newest_transcript_age([Path(tmp)], time.time()))


class DecideTests(unittest.TestCase):
    def test_low_battery_wins_over_a_running_build(self):
        keep, why = ka.decide(True, 10, True, ['xcodebuild'], 5)
        self.assertFalse(keep)
        self.assertIn('10%', why)

    def test_battery_above_the_floor_holds_for_a_build(self):
        self.assertTrue(ka.decide(True, 11, True, ['xcodebuild'], None)[0])

    def test_low_battery_on_power_still_holds(self):
        self.assertTrue(ka.decide(False, 5, True, ['xcodebuild'], None)[0])

    def test_build_holds_without_network(self):
        self.assertTrue(ka.decide(False, 100, False, ['Runner.Worker'], None)[0])

    def test_fresh_agent_holds_only_with_network(self):
        self.assertTrue(ka.decide(True, 50, True, [], 300)[0])
        keep, why = ka.decide(True, 50, False, [], 300)
        self.assertFalse(keep)
        self.assertIn('no network', why)

    def test_stale_agent_or_nothing_releases(self):
        self.assertFalse(ka.decide(False, 100, True, [], 601)[0])
        self.assertFalse(ka.decide(False, 100, True, [], None)[0])


if __name__ == '__main__':
    unittest.main()
