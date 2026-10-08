"""Host tests for the lane power guard's decisions. No launchctl, pmset or runner processes.

Run: python3 -m unittest ops/lane/test_sm_lane_power_guard.py
"""
import sys
import tempfile
import threading
import unittest
from unittest import mock
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


class StateFiles(unittest.TestCase):
    """The paused file and lock in a temporary folder."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        state = Path(folder.name)
        for name, value in (('STATE_DIR', state), ('PAUSED', state / 'paused'), ('LOCK', state / 'lock')):
            patcher = mock.patch.object(g, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)


class Apply(StateFiles):
    """#836: Codex's post-merge audits of #763 and #792."""

    def test_a_failed_restart_keeps_the_runner_marked_paused(self):
        g.set_paused(g.RUNNER_PREFIX + 'sm-lane-mac', True)
        line = g.apply(g.Action('start', runner(running=False), 'started'), 501, control=lambda args: 3)
        self.assertEqual(g.paused_labels(), [g.RUNNER_PREFIX + 'sm-lane-mac'])  # the next check retries
        self.assertIn('start failed', line)

    def test_a_restart_that_works_forgets_the_pause(self):
        g.set_paused(g.RUNNER_PREFIX + 'sm-lane-mac', True)
        calls = []
        g.apply(g.Action('start', runner(running=False), 'started'), 501,
                control=lambda args: calls.append(args) or 0)
        self.assertEqual(calls, [['kickstart', 'gui/501/' + g.RUNNER_PREFIX + 'sm-lane-mac']])
        self.assertEqual(g.paused_labels(), [])

    def test_a_runner_that_took_a_job_since_the_look_is_not_stopped(self):
        calls = []
        line = g.apply(g.Action('stop', runner(), 'paused'), 501, control=lambda args: calls.append(args) or 0,
                       look_again=lambda r: runner(listener_job=True))
        self.assertEqual(calls, [])  # a TERM now would cancel the job it just accepted
        self.assertEqual(g.paused_labels(), [])
        self.assertIn('took a job', line)

    def test_an_idle_runner_is_stopped_and_marked_paused(self):
        calls = []
        g.apply(g.Action('stop', runner(), 'paused'), 501, control=lambda args: calls.append(args) or 0,
                look_again=lambda r: r)
        self.assertEqual(calls, [['kill', 'TERM', 'gui/501/' + g.RUNNER_PREFIX + 'sm-lane-mac']])
        self.assertEqual(g.paused_labels(), [g.RUNNER_PREFIX + 'sm-lane-mac'])


class CycleLock(StateFiles):
    def test_a_second_guard_waits_for_the_first_to_finish(self):
        # The worker-exit guard and the scheduled guard used to read and rewrite the paused file at
        # the same time; the last write dropped the other's label, and that runner never restarted.
        entered = threading.Event()

        def second_guard():
            with g.cycle_lock():
                entered.set()

        with g.cycle_lock():
            second = threading.Thread(target=second_guard)
            second.start()
            self.assertFalse(entered.wait(0.5), 'the second guard ran while the first held the lock')
        self.assertTrue(entered.wait(5))
        second.join(5)

    def test_both_guards_keep_their_pause_records(self):
        labels = [g.RUNNER_PREFIX + 'sm-lane-mac', g.RUNNER_PREFIX + 'sm-lane-mac-2']

        def guard(label):
            with g.cycle_lock():
                g.set_paused(label, True)

        threads = [threading.Thread(target=guard, args=(label,)) for label in labels * 20]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        self.assertEqual(sorted(g.paused_labels()), labels)


if __name__ == '__main__':
    unittest.main()
