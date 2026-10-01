"""Host tests for the Dial gate (#589). Run: python3 -m unittest ops/dial/test_dial_gate.py"""
import datetime as dt
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import dial_gate as g  # noqa: E402

BODY = """Tap one box in each group.

**Mode**
- [ ] Off: nothing new starts
- [x] Paced: keep threads going
- [ ] Cloud max: keep threads going even with the Mac offline

**Threads**
- [ ] 1
- [ ] 2
- [x] 3
- [ ] 4

**Stop line** (weekly usage; new work holds 3 points below it)
- [ ] 80%
- [x] 97%

**Finish by**
- [ ] Sat 7 AM (the weekly reset)
- [x] Fri noon
- [ ] Fri 7 AM

---
- [x] a stray ticked box after the rule is ignored
"""

NOW = dt.datetime(2026, 10, 1, 13, 0, tzinfo=dt.timezone.utc)


def ts(d):
    return d.strftime('%Y-%m-%dT%H:%M:%SZ')


def tick(percent, at, extra=''):
    return {'body': f'**time (Mac tick)** · next x\n- pace: Claude {percent}% used, 70% of the week gone{extra}',
            'created_at': ts(at)}


class ParseDial(unittest.TestCase):
    def test_reads_the_ticked_boxes(self):
        d = g.parse_dial(BODY)
        self.assertEqual((d['mode'], d['threads'], d['stop'], d['hours_early'], d['problems']),
                         ('paced', 3, 97, 19, []))

    def test_two_finish_by_ticks_take_the_later_deadline(self):
        d = g.parse_dial(BODY.replace('- [ ] Sat 7 AM', '- [x] Sat 7 AM'))
        self.assertEqual(d['hours_early'], 0)

    def test_no_finish_by_means_the_reset(self):
        self.assertEqual(g.parse_dial(BODY.replace('- [x] Fri noon', '- [ ] Fri noon'))['hours_early'], 0)

    def test_two_threads_ticked_takes_the_lower(self):
        d = g.parse_dial(BODY.replace('- [ ] 1', '- [x] 1'))
        self.assertEqual(d['threads'], 1)
        self.assertTrue(any('lowest' in p for p in d['problems']))

    def test_two_stop_lines_takes_the_lower(self):
        self.assertEqual(g.parse_dial(BODY.replace('- [ ] 80%', '- [x] 80%'))['stop'], 80)

    def test_empty_mode_reads_off(self):
        d = g.parse_dial(BODY.replace('- [x] Paced', '- [ ] Paced'))
        self.assertEqual(d['mode'], 'off')

    def test_off_wins_over_anything(self):
        self.assertEqual(g.parse_dial(BODY.replace('- [ ] Off', '- [X] Off'))['mode'], 'off')

    def test_paced_and_cloud_max_reads_paced(self):
        self.assertEqual(g.parse_dial(BODY.replace('- [ ] Cloud max', '- [x] Cloud max'))['mode'], 'paced')

    def test_mangled_body_reads_off_and_does_not_crash(self):
        d = g.parse_dial('I accidentally deleted everything')
        self.assertEqual((d['mode'], d['threads']), ('off', 0))


class ParseUsage(unittest.TestCase):
    def test_latest_usage_and_breaker(self):
        comments = [tick(80, NOW - dt.timedelta(hours=4)),
                    {'body': '**HALT (usage breaker)** (Mac tick) at 81', 'created_at': ts(NOW - dt.timedelta(hours=3))},
                    tick(82, NOW - dt.timedelta(hours=1))]
        u = g.parse_usage(comments)
        self.assertEqual(u['usage']['percent'], 82)
        self.assertTrue(u['halted'])
        comments.append({'body': '**RESUMED (usage breaker)** · (Mac tick, owner override)', 'created_at': ts(NOW)})
        self.assertFalse(g.parse_usage(comments)['halted'])


class Decide(unittest.TestCase):
    def setUp(self):
        self.dial = g.parse_dial(BODY)
        self.usage = g.parse_usage([tick(82, NOW - dt.timedelta(minutes=30))])

    def decide(self, **kw):
        args = dict(now=NOW, dial=self.dial, usage_info=self.usage, ready_count=10, ack=None, state={})
        args.update(kw)
        return g.decide(**args)

    def test_fires_when_allowed(self):
        self.assertTrue(self.decide()['fire'])

    def test_holds_three_points_below_the_stop_line(self):
        usage = g.parse_usage([tick(94, NOW - dt.timedelta(minutes=30))])
        r = self.decide(usage_info=usage)
        self.assertFalse(r['fire'])
        self.assertIn('hold line 94%', r['why'])

    def test_paced_waits_when_the_mac_report_is_stale(self):
        usage = g.parse_usage([tick(50, NOW - dt.timedelta(hours=4))])
        self.assertFalse(self.decide(usage_info=usage)['fire'])

    def test_cloud_max_ignores_stale_usage(self):
        dial = g.parse_dial(BODY.replace('- [x] Paced', '- [ ] Paced').replace('- [ ] Cloud max', '- [x] Cloud max'))
        usage = g.parse_usage([tick(96, NOW - dt.timedelta(hours=9))])
        self.assertTrue(self.decide(dial=dial, usage_info=usage)['fire'])

    def test_one_fire_outstanding_until_acknowledged(self):
        state = {'last_fire': 'fire-20261001T1100Z', 'last_fire_at': ts(NOW - dt.timedelta(hours=2))}
        self.assertFalse(self.decide(state=state)['fire'])
        ack = {'fire': 'fire-20261001T1100Z', 'running': 2, 'at': NOW, 'id': 1}
        self.assertTrue(self.decide(state=state, ack=ack)['fire'])

    def test_unacknowledged_fire_is_retried_after_three_hours(self):
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(hours=4))}
        self.assertTrue(self.decide(state=state)['fire'])
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(hours=2))}
        self.assertFalse(self.decide(state=state)['fire'])

    def test_a_claim_after_the_fire_counts_as_acknowledged(self):
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(hours=2))}
        ack = {'fire': 'fire-x', 'running': None, 'started': 3, 'at': NOW, 'id': None, 'via': 'claims'}
        self.assertTrue(self.decide(state=state, ack=ack)['fire'])

    def test_no_more_than_one_wake_up_an_hour(self):
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(minutes=20))}
        ack = {'fire': 'fire-x', 'running': 1, 'at': NOW, 'id': 1}
        self.assertFalse(self.decide(state=state, ack=ack)['fire'])

    def test_all_threads_running_waits_three_hours(self):
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(hours=2))}
        ack = {'fire': 'fire-x', 'running': 3, 'at': NOW, 'id': 1}
        self.assertFalse(self.decide(state=state, ack=ack)['fire'])

    def test_trend_line_runs_from_week_start_to_the_stop_line(self):
        # Week: Sat 2026-09-26 11:00Z to Sat 10-03 11:00Z; Fri noon EDT = 19 h early = Fri 16:00Z.
        self.assertAlmostEqual(g.trend_line(dt.datetime(2026, 10, 2, 16, 0, tzinfo=dt.timezone.utc), 97, 19), 97)
        self.assertAlmostEqual(g.trend_line(dt.datetime(2026, 9, 26, 11, 0, tzinfo=dt.timezone.utc), 97, 19), 0)
        self.assertAlmostEqual(g.trend_line(NOW, 97, 19), 97 * 122 / 149, places=3)

    def test_paced_holds_when_far_ahead_of_trend(self):
        dial = g.parse_dial(BODY.replace('- [x] Fri noon', '- [ ] Fri noon'))  # finish at the reset: line ~70% now
        r = self.decide(dial=dial)  # usage 82% is 12 points ahead
        self.assertFalse(r['fire'])
        self.assertIn('ahead of the trend', r['why'])

    def test_paced_fires_when_within_slack_of_trend(self):
        self.assertTrue(self.decide()['fire'])  # Fri noon: line ~79%, usage 82%

    def test_empty_ready_queue_does_nothing(self):
        self.assertFalse(self.decide(ready_count=0)['fire'])

    def test_halt_holds_paced(self):
        usage = dict(self.usage, halted=True)
        self.assertFalse(self.decide(usage_info=usage)['fire'])


if __name__ == '__main__':
    unittest.main()
