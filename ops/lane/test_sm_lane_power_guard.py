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


def runner(name='sm-lane-mac', running=True, worker=None, listener_job=False):
    return g.Runner(g.RUNNER_PREFIX + name, f'/Users/x/actions-runner-{name}', running, worker, listener_job)


PAUSED_BY_GUARD = [g.RUNNER_PREFIX + 'sm-lane-mac']


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


class AwakeStateWithAmphetamine(unittest.TestCase):
    HOLD_LID = (True, True)      # session active, lid-closed running on
    HOLD_NO_LID = (True, False)
    NO_SESSION = (False, True)

    def test_closed_lid_on_power_with_lid_hold_can(self):
        # Owner, 2026-10-04: close the lid for 14 hours on power and keep the lane working.
        self.assertEqual(g.awake_state(AC, LID_CLOSED, self.HOLD_LID),
                         (True, 'Amphetamine holds the Mac awake (on power, lid closed)'))

    def test_battery_above_the_floor_with_a_hold_can(self):
        self.assertEqual(g.awake_state(BATTERY, LID_OPEN, self.HOLD_NO_LID),
                         (True, 'Amphetamine holds the Mac awake (on battery at 84%)'))

    def test_battery_at_the_floor_cannot_even_with_a_hold(self):
        low = BATTERY.replace('84%', '10%')
        self.assertEqual(g.awake_state(low, LID_OPEN, self.HOLD_LID), (False, 'on battery at 10%'))

    def test_closed_lid_without_lid_running_cannot(self):
        self.assertEqual(g.awake_state(AC, LID_CLOSED, self.HOLD_NO_LID), (False, 'lid closed'))
        self.assertEqual(g.awake_state(BATTERY, LID_CLOSED, self.HOLD_NO_LID), (False, 'lid closed'))

    def test_no_session_or_no_answer_keeps_the_old_rules(self):
        self.assertEqual(g.awake_state(BATTERY, LID_OPEN, self.NO_SESSION), (False, 'on battery'))
        self.assertEqual(g.awake_state(AC, LID_CLOSED, None), (False, 'lid closed'))

    def test_battery_without_a_reading_cannot(self):
        self.assertEqual(g.awake_state("Now drawing from 'Battery Power'\n", LID_OPEN, self.HOLD_LID),
                         (False, 'on battery at unknown%'))


class Decide(unittest.TestCase):
    def test_idle_runner_is_paused_on_battery(self):
        actions = g.decide(False, 'on battery', [runner()], [], [])
        self.assertEqual([(a.kind, a.runner.name) for a in actions], [('stop', 'sm-lane-mac')])
        self.assertEqual(actions[0].note, 'sm-lane-mac: paused (on battery)')

    def test_busy_runner_is_held_not_stopped(self):
        actions = g.decide(False, 'on battery', [runner(worker=4242)], [], [])
        self.assertEqual([a.kind for a in actions], ['hold'])

    def test_busy_runner_is_held_once(self):
        self.assertEqual(g.decide(False, 'lid closed', [runner(worker=4242)], [4242], []), [])

    def test_paused_runner_stays_paused_on_battery(self):
        self.assertEqual(g.decide(False, 'on battery', [runner(running=False)], [], PAUSED_BY_GUARD), [])

    def test_paused_runner_restarts_on_power(self):
        actions = g.decide(True, 'on power', [runner(running=False), runner('sm-lane-mac-2')], [], PAUSED_BY_GUARD)
        self.assertEqual([(a.kind, a.runner.name) for a in actions], [('start', 'sm-lane-mac')])

    def test_runner_stopped_by_someone_else_is_left_alone(self):
        # A lane freeze by hand, or a runner that exited after a session conflict.
        self.assertEqual(g.decide(True, 'on power', [runner(running=False)], [], []), [])

    def test_listener_that_just_took_a_job_is_not_stopped(self):
        # Worker not started yet; stopping the listener now would cancel the job.
        self.assertEqual(g.decide(False, 'on battery', [runner(listener_job=True)], [], []), [])

    def test_nothing_to_do_on_power_when_running(self):
        self.assertEqual(g.decide(True, 'on power', [runner(worker=1), runner('sm-lane-mac-2')], [], []), [])


class ListenerHasJob(unittest.TestCase):
    STARTED = '[2026-10-04 12:59:47Z INFO Terminal] WRITE LINE: 2026-10-04 12:59:47Z: Running job: automerge\n'
    FINISHED = ('[2026-10-04 12:59:45Z INFO Terminal] WRITE LINE: 2026-10-04 12:59:45Z: '
                'Job automerge completed with result: Succeeded\n')

    def test_job_started_after_the_last_finish(self):
        self.assertTrue(g.listener_has_job(self.FINISHED + self.STARTED))

    def test_job_finished(self):
        self.assertFalse(g.listener_has_job(self.STARTED + self.FINISHED))

    def test_empty_log(self):
        self.assertFalse(g.listener_has_job(''))


if __name__ == '__main__':
    unittest.main()
