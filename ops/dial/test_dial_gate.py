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

**Refill when**
- [ ] Any slot opens
- [ ] 1 thread left
- [ ] No threads left

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

    def test_refill_defaults_to_any_open_slot(self):
        self.assertIsNone(g.parse_dial(BODY)['refill_at'])
        self.assertIsNone(g.parse_dial(BODY.replace('**Refill when**', '**Something else**'))['refill_at'])

    def test_refill_threshold_reads_the_box(self):
        self.assertEqual(g.parse_dial(BODY.replace('- [ ] 1 thread left', '- [x] 1 thread left'))['refill_at'], 1)
        self.assertEqual(g.parse_dial(BODY.replace('- [ ] No threads left', '- [x] No threads left'))['refill_at'], 0)
        self.assertIsNone(g.parse_dial(BODY.replace('- [ ] Any slot', '- [x] Any slot'))['refill_at'])

    def test_two_refill_ticks_take_the_one_that_wakes_less(self):
        d = g.parse_dial(BODY.replace('- [ ] Any slot', '- [x] Any slot').replace('- [ ] 1 thread left', '- [x] 1 thread left'))
        self.assertEqual(d['refill_at'], 1)
        self.assertTrue(any('Refill' in p for p in d['problems']))

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
        args = dict(now=NOW, dial=self.dial, usage_info=self.usage, ready_count=10, ack=None, state={}, active=0)
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

    def test_wake_ups_are_at_least_15_minutes_apart(self):
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(minutes=10))}
        ack = {'fire': 'fire-x', 'running': None, 'at': NOW, 'id': 1}
        self.assertFalse(self.decide(state=state, ack=ack, active=1)['fire'])
        state['last_fire_at'] = ts(NOW - dt.timedelta(minutes=16))
        self.assertTrue(self.decide(state=state, ack=ack, active=1)['fire'])

    def test_full_slots_wait_for_the_three_hour_fallback(self):
        ack = {'fire': 'fire-x', 'running': None, 'at': NOW, 'id': 1}
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(hours=2))}
        r = self.decide(state=state, ack=ack, active=3)
        self.assertFalse(r['fire'])
        self.assertIn('3 of 3', r['why'])
        state['last_fire_at'] = ts(NOW - dt.timedelta(hours=3, minutes=1))
        self.assertTrue(self.decide(state=state, ack=ack, active=3)['fire'])

    def test_fires_as_soon_as_a_slot_opens(self):
        ack = {'fire': 'fire-x', 'running': None, 'at': NOW, 'id': 1}
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(minutes=20))}
        self.assertTrue(self.decide(state=state, ack=ack, active=2)['fire'])

    def test_refill_threshold_holds_until_active_threads_fall_to_it(self):
        dial = g.parse_dial(BODY.replace('- [ ] 1 thread left', '- [x] 1 thread left'))
        ack = {'fire': 'fire-x', 'running': None, 'at': NOW, 'id': 1}
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(minutes=40))}
        r = self.decide(dial=dial, state=state, ack=ack, active=2)
        self.assertFalse(r['fire'])
        self.assertIn('1 thread', r['why'])
        self.assertTrue(self.decide(dial=dial, state=state, ack=ack, active=1)['fire'])

    def test_no_threads_left_waits_for_zero(self):
        dial = g.parse_dial(BODY.replace('- [ ] No threads left', '- [x] No threads left'))
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(NOW - dt.timedelta(minutes=40))}
        ack = {'fire': 'fire-x', 'running': None, 'at': NOW, 'id': 1}
        self.assertFalse(self.decide(dial=dial, state=state, ack=ack, active=1)['fire'])
        self.assertTrue(self.decide(dial=dial, state=state, ack=ack, active=0)['fire'])

    def test_a_threshold_at_or_above_the_maximum_means_any_open_slot(self):
        dial = dict(g.parse_dial(BODY), threads=1, refill_at=1)
        self.assertFalse(self.decide(dial=dial, active=1, state={'last_fire_at': ts(NOW - dt.timedelta(hours=1))})['fire'])
        self.assertTrue(self.decide(dial=dial, active=0)['fire'])

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


def claim(title, issue, at):
    return {'body': f'Claimed by project thread "{title}" at {at:%Y-%m-%d %H:%M} UTC. Likely files: x.',
            'created_at': ts(at), 'issue_url': f'https://api.github.com/repos/o/r/issues/{issue}'}


def stop(title, issue, at):
    return {'body': f'Thread "{title}" stopping: PR #900 armed · context near 250k',
            'created_at': ts(at), 'issue_url': f'https://api.github.com/repos/o/r/issues/{issue}'}


def comment(issue, at, body='Progress: tests written.'):
    return {'body': body, 'created_at': ts(at), 'issue_url': f'https://api.github.com/repos/o/r/issues/{issue}'}


def push(branch, at):
    return {'type': 'PushEvent', 'created_at': ts(at), 'payload': {'ref': f'refs/heads/{branch}'}}


def ago(**kw):
    return NOW - dt.timedelta(**kw)


class Threads(unittest.TestCase):
    def by_title(self, comments, events=()):
        return {t['title']: t for t in g.parse_threads(comments, list(events), NOW)}

    def test_a_fresh_claim_is_active(self):
        t = self.by_title([claim('A', 592, ago(minutes=30))])['A']
        self.assertEqual((t['state'], t['issues']), ('active', [592]))

    def test_a_stop_note_ends_the_thread(self):
        t = self.by_title([claim('A', 592, ago(minutes=50)), stop('A', 592, ago(minutes=5))])['A']
        self.assertEqual(t['state'], 'stopped')
        self.assertIn('context near 250k', t['stop_text'])

    def test_a_claim_after_a_stop_note_is_active_again(self):
        t = self.by_title([claim('A', 1, ago(hours=1)), stop('A', 1, ago(minutes=40)),
                           claim('A', 2, ago(minutes=30))])['A']
        self.assertEqual((t['state'], t['issues']), ('active', [2]))

    def test_a_thread_with_no_stop_note_goes_stale_after_two_hours(self):
        t = self.by_title([claim('A', 470, ago(hours=2, minutes=5))])['A']
        self.assertEqual(t['state'], 'quiet')

    def test_a_comment_naming_the_thread_keeps_it_active(self):
        t = self.by_title([claim('A', 470, ago(hours=3)),
                           comment(593, ago(minutes=90), 'Handed to the Mac finisher by project thread "A".')])['A']
        self.assertEqual(t['state'], 'active')

    def test_someone_elses_comment_on_the_issue_does_not_count(self):
        # 2026-10-01: the owner's phone-check results landed on many claimed issues at once.
        t = self.by_title([claim('A', 470, ago(hours=3)), comment(470, ago(minutes=30), '**Owner phone check: PASS.**')])['A']
        self.assertEqual(t['state'], 'quiet')

    def test_a_push_for_an_earlier_issue_does_not_count(self):
        # Its earlier PR is armed; the Mac finisher or the lane may push there without the thread.
        t = self.by_title([claim('A', 331, ago(hours=4)), claim('A', 592, ago(hours=3))],
                          [push('ws/331-anchors', ago(minutes=20))])['A']
        self.assertEqual((t['state'], t['issues']), ('quiet', [331, 592]))

    def test_a_push_to_the_issue_branch_keeps_it_active(self):
        t = self.by_title([claim('A', 470, ago(hours=3))], [push('ws/470-podcast-gaps', ago(minutes=20))])['A']
        self.assertEqual(t['state'], 'active')
        self.assertEqual(t['last_seen'], ago(minutes=20))

    def test_a_push_to_another_issue_does_not_count(self):
        t = self.by_title([claim('A', 470, ago(hours=3))], [push('ws/4700-other', ago(minutes=20)),
                                                            push('ws/47-other', ago(minutes=20))])['A']
        self.assertEqual(t['state'], 'quiet')

    def test_quoted_formats_inside_other_text_are_not_claims(self):
        body = '- Threads post fixed-format notes: `Claimed by project thread "<title>"` and `Thread "<title>" stopping:`'
        self.assertEqual(g.parse_threads([comment(337, ago(minutes=5), body)], [], NOW), [])

    def test_bold_or_indented_claims_still_count(self):
        t = self.by_title([comment(5, ago(minutes=5), '**Claimed by project thread "B"** at 13:00 UTC.')])
        self.assertIn('B', t)

    def test_claims_after_a_fire_acknowledge_it(self):
        threads = g.parse_threads([claim('A', 1, ago(hours=2)), claim('B', 2, ago(minutes=40)),
                                   claim('C', 3, ago(minutes=10))], [], NOW)
        self.assertEqual(g.claims_since(threads, ago(hours=1)), 2)


class Durations(unittest.TestCase):
    def test_runs_last_from_first_claim_to_stop_note_or_last_sign_of_life(self):
        threads = g.parse_threads([claim('A', 1, ago(hours=5)), claim('A', 2, ago(hours=4)), stop('A', 2, ago(hours=3)),
                                   claim('B', 3, ago(hours=8)), claim('C', 4, ago(minutes=30))], [], NOW)
        runs = {r['title']: r for r in g.finished_runs(threads, NOW)}
        self.assertEqual(runs['A']['minutes'], 120)
        self.assertEqual(runs['A']['how'], 'stop note')
        self.assertEqual(runs['B']['minutes'], 0)       # quiet: claimed, then nothing
        self.assertEqual(runs['B']['how'], 'went quiet')
        self.assertNotIn('C', runs)                      # still running

    def test_status_reports_the_median_run(self):
        threads = g.parse_threads([claim('A', 1, ago(hours=5)), stop('A', 1, ago(hours=4)),
                                   claim('B', 2, ago(hours=3)), stop('B', 2, ago(hours=1))], [], NOW)
        dial = g.parse_dial(BODY)
        usage = g.parse_usage([tick(82, ago(minutes=30))])
        decision = g.decide(NOW, dial, usage, 10, None, {}, 0)
        text = g.status_text(NOW, dial, usage, 10, None, {}, decision, threads)
        self.assertIn('Thread runs ended in the last 24 h: 2 with a stop note, median 90 min', text)


class Status(unittest.TestCase):
    def test_lists_active_threads_by_title_and_quiet_ones_separately(self):
        threads = g.parse_threads([claim('Podcast anchors', 592, ago(minutes=30)),
                                   claim('Zotero export', 588, ago(hours=2, minutes=30)),
                                   claim('Old one', 100, ago(hours=30))], [], NOW)
        dial = g.parse_dial(BODY)
        usage = g.parse_usage([tick(82, ago(minutes=30))])
        decision = g.decide(NOW, dial, usage, 10, None, {}, g.active_count(threads))
        text = g.status_text(NOW, dial, usage, 10, None, {}, decision, threads)
        self.assertIn('Active threads: 1 of 3', text)
        self.assertIn('"Podcast anchors" on #592', text)
        self.assertIn('Gone quiet with no stop note', text)
        self.assertIn('"Zotero export"', text)
        self.assertNotIn('Old one', text)  # quiet for more than 6 hours: dropped


if __name__ == '__main__':
    unittest.main()
