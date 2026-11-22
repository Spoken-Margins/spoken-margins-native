"""A short `schedule:` is only a backstop, never the start (#4866).

GitHub drops most scheduled ticks on a busy day: in the 24 hours to 2026-11-21 `claude-audit` ran 4 of 96 times,
`merge-stall` 3 of 96, `merge-queue-label-bridge` 4 of 96 and `lane-conflicts` 3 of 24. Five "Merging has stalled" issues
in three days came from waiting on those ticks. A workflow that runs every 15 minutes (or faster) must also start on an
event, so a dropped tick costs nothing; and the five named below start on events now, with their cron cut to one daily
last resort and the VPS (ops/dispatch-backstop/) firing `workflow_dispatch` as the backstop.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'ops' / 'dispatch-backstop'))
from test_workflow_files import ROOT, WORKFLOWS, parse  # noqa: E402
import sm_dispatch_backstop as backstop  # noqa: E402

SHORT = 15  # minutes: a schedule that can fire this often needs an event trigger too
# The workflows #4866 moves onto events, with what must start each one. main-t3's `push` trigger is #4839's (PR #4844);
# until it merges, main-t3 has only its 3-hourly cron and the VPS, which the 15-minute rule does not touch.
ON_EVENTS = {
    'claude-audit.yml': 'workflow_run',
    'merge-stall.yml': 'workflow_run',
    'merge-queue-label-bridge.yml': 'pull_request_target',
    'lane-conflicts.yml': 'pull_request',
}
FIVE = set(ON_EVENTS) | {'main-t3.yml'}


def triggers(workflow):
    """The `on:` block as a dict. PyYAML reads the bare key `on` as True."""
    on = workflow.get('on', workflow.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {name: None for name in on}
    return on or {}


def field_values(field, low, high):
    """The values a cron field names, for `*`, `*/n`, `a`, `a-b`, `a-b/n` and comma lists of those."""
    values = set()
    for part in field.split(','):
        base, _, step = part.partition('/')
        step = int(step) if step else 1
        if base == '*':
            first, last = low, high
        elif '-' in base:
            first, last = (int(x) for x in base.split('-'))
        else:
            first = int(base)
            last = high if step != 1 else first
        values.update(range(first, last + 1, step))
    return values


def shortest_gap_minutes(cron):
    """The least time between two firings of a five-field cron, looking at minute and hour only (day, month and weekday
    only ever thin the firings out, so ignoring them can only make the answer shorter, the safe side for a guard)."""
    minute, hour = cron.split()[:2]
    minutes, hours = sorted(field_values(minute, 0, 59)), sorted(field_values(hour, 0, 23))
    # Two ticks in one hour; and the last tick of one firing hour to the first of the next (or of the next day).
    within = [b - a for a, b in zip(minutes, minutes[1:])]
    across = [((h2 - h1) % 24 or 24) * 60 + minutes[0] - minutes[-1] for h1 in hours for h2 in hours]
    return min(within + across)


class CronGapTests(unittest.TestCase):
    def test_gaps(self):
        cases = {
            '3,18,33,48 * * * *': 15,
            '7,22,37,52 * * * *': 15,
            '*/5 * * * *': 5,
            '* * * * *': 1,
            '*/15 * * * *': 15,
            '*/20 * * * *': 20,
            '5 * * * *': 60,
            '17 */3 * * *': 180,
            '30 13 * * *': 24 * 60,
            '3 6 * * *': 24 * 60,
            '0,10 6 * * *': 10,        # two ticks in one hour, once a day
            '0,10 6,7 * * *': 10,
            '0,10 6,9 * * *': 10,
            '0,50 6,7 * * *': 10,
            '50 6,7 * * *': 60,
            '50 23,0 * * *': 60,       # across midnight
            '*/10 9-17 * * 1-5': 10,
            '0 9-17 * * *': 60,
        }
        for cron, expected in cases.items():
            with self.subTest(cron):
                self.assertEqual(shortest_gap_minutes(cron), expected)


class ScheduleGuardTests(unittest.TestCase):
    def test_a_schedule_of_fifteen_minutes_or_less_needs_an_event_trigger(self):
        for path in WORKFLOWS:
            on = triggers(parse(path))
            crons = [entry['cron'] for entry in on.get('schedule') or []]
            short = [c for c in crons if shortest_gap_minutes(c) <= SHORT]
            events = set(on) - {'schedule', 'workflow_dispatch'}
            with self.subTest(path.name):
                self.assertFalse(short and not events,
                                 f'{path.name} has {short} and no event trigger: GitHub drops scheduled ticks; add an '
                                 'event (pull_request, workflow_run, push) and let ops/dispatch-backstop fire the backstop')

    def test_the_five_have_no_schedule_of_fifteen_minutes_or_less_at_all(self):
        for name in sorted(FIVE):
            on = triggers(parse(ROOT / '.github/workflows' / name))
            with self.subTest(name):
                self.assertIn('workflow_dispatch', on)  # the VPS's way in
                for entry in on.get('schedule') or []:
                    self.assertGreater(shortest_gap_minutes(entry['cron']), SHORT, entry['cron'])

    def test_each_of_the_four_starts_on_its_event(self):
        for name, event in ON_EVENTS.items():
            with self.subTest(name):
                self.assertIn(event, triggers(parse(ROOT / '.github/workflows' / name)))

    def test_the_backstop_covers_exactly_the_five_and_each_can_be_dispatched(self):
        self.assertEqual(set(backstop.WORKFLOWS), FIVE)
        for name in backstop.WORKFLOWS:
            self.assertIn('workflow_dispatch', triggers(parse(ROOT / '.github/workflows' / name)), name)

    def test_the_backstop_interval_is_the_one_each_workflow_used_to_ask_for(self):
        self.assertEqual(backstop.WORKFLOWS, {'claude-audit.yml': 15, 'merge-stall.yml': 15,
                                              'merge-queue-label-bridge.yml': 15, 'lane-conflicts.yml': 60,
                                              'main-t3.yml': 180})


if __name__ == '__main__':
    unittest.main()
