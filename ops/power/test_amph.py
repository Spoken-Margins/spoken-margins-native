"""Host tests for amph's ensure decision (#837). Runs the real AppleScript with osascript, through
a test-only command that never talks to Amphetamine.

Run: python3 -m unittest ops/power/test_amph.py
"""
import shutil
import subprocess
import unittest
from pathlib import Path

AMPH = Path(__file__).resolve().with_name('amph')
NOW = 1_000_000


@unittest.skipUnless(shutil.which('osascript'), 'amph is AppleScript; it needs macOS')
class EnsureDecision(unittest.TestCase):
    def decide(self, secs, mins, hold_end):
        result = subprocess.run(['osascript', str(AMPH), '_ensure-decision', str(secs), str(mins), str(hold_end),
                                 str(NOW)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_a_hold_near_its_end_is_kept(self):
        # `amph hold 41h` with nine minutes left: a build's `ensure 20 --lid` replaced it with a
        # 20-minute session, keeping the Mac awake past the time Cole asked for.
        self.assertEqual(self.decide(540, 20, NOW + 540), 'keep')

    def test_a_short_hold_is_kept(self):
        # `amph hold 5m` with two minutes left, against the job's usual `ensure 20`.
        self.assertEqual(self.decide(120, 20, NOW + 120), 'keep')

    def test_the_same_session_without_a_hold_is_renewed(self):
        self.assertEqual(self.decide(540, 20, 0), 'start')

    def test_a_hold_record_that_does_not_match_the_session_is_ignored(self):
        # The hold ended, or another session replaced it: the record can't pin that session.
        self.assertEqual(self.decide(540, 20, NOW + 50_000), 'start')
        self.assertEqual(self.decide(540, 20, NOW - 60), 'start')

    def test_ordinary_renewal_is_unchanged(self):
        self.assertEqual(self.decide(-3, 20, 0), 'start')     # no session
        self.assertEqual(self.decide(3000, 20, 0), 'keep')    # more than half of 20 minutes left
        self.assertEqual(self.decide(0, 20, 0), 'keep')       # until stopped
        self.assertEqual(self.decide(-2, 20, 0), 'keep')      # app or end-time session


if __name__ == '__main__':
    unittest.main()
