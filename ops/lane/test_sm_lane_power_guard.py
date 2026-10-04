"""Host tests for the lane power guard's decisions. No launchctl, pmset or runner processes.

Run: python3 -m unittest ops/lane/test_sm_lane_power_guard.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_lane_power_guard as g  # noqa: E402

AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%; charging;"
BATTERY = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t84%; discharging;"
LID_OPEN = '  |   "AppleClamshellCausesSleep" = Yes\n  |   "AppleClamshellState" = No\n'
LID_CLOSED = '  |   "AppleClamshellCausesSleep" = Yes\n  |   "AppleClamshellState" = Yes\n'
LID_CLOSED_EXTERNAL_DISPLAY = '  |   "AppleClamshellCausesSleep" = No\n  |   "AppleClamshellState" = Yes\n'


def runner(name='sm-lane-mac', running=True, worker=None):
    return g.Runner(g.RUNNER_PREFIX + name, f'/Users/x/actions-runner-{name}', running, worker)


class AwakeState(unittest.TestCase):
    def test_battery_cannot_stay_awake(self):
        # The 10-04 failures: unplugged, every job taken during a dark wake was lost.
        self.assertEqual(g.awake_state(BATTERY, LID_OPEN), (False, 'on battery'))

    def test_closed_lid_on_power_cannot_stay_awake(self):
        self.assertEqual(g.awake_state(AC, LID_CLOSED), (False, 'lid closed'))

    def test_power_and_open_lid_can(self):
        self.assertEqual(g.awake_state(AC, LID_OPEN), (True, 'on power'))

    def test_closed_lid_with_external_display_can(self):
        self.assertEqual(g.awake_state(AC, LID_CLOSED_EXTERNAL_DISPLAY), (True, 'on power'))

    def test_no_power_reading_counts_as_battery(self):
        self.assertEqual(g.awake_state('', LID_OPEN), (False, 'on battery'))


class Decide(unittest.TestCase):
    def test_idle_runner_is_paused_on_battery(self):
        actions = g.decide(False, 'on battery', [runner()], [])
        self.assertEqual([(a.kind, a.runner.name) for a in actions], [('stop', 'sm-lane-mac')])
        self.assertEqual(actions[0].note, 'sm-lane-mac: paused (on battery)')

    def test_busy_runner_is_held_not_stopped(self):
        actions = g.decide(False, 'on battery', [runner(worker=4242)], [])
        self.assertEqual([a.kind for a in actions], ['hold'])

    def test_busy_runner_is_held_once(self):
        self.assertEqual(g.decide(False, 'lid closed', [runner(worker=4242)], [4242]), [])

    def test_paused_runner_stays_paused_on_battery(self):
        self.assertEqual(g.decide(False, 'on battery', [runner(running=False)], []), [])

    def test_paused_runner_restarts_on_power(self):
        actions = g.decide(True, 'on power', [runner(running=False), runner('sm-lane-mac-2')], [])
        self.assertEqual([(a.kind, a.runner.name) for a in actions], [('start', 'sm-lane-mac')])

    def test_nothing_to_do_on_power_when_running(self):
        self.assertEqual(g.decide(True, 'on power', [runner(worker=1), runner('sm-lane-mac-2')], []), [])


if __name__ == '__main__':
    unittest.main()
