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
            'author_association': 'OWNER', 'created_at': ts(at)}


class ParseDial(unittest.TestCase):
    def test_codex_groups_leave_the_claude_dial_unchanged(self):
        codex = '''**Codex workers**
- [x] 1
**Codex stop line** (Codex weekly usage; Codex holds 3 points below it)
- [x] 70%
- [x] 80%
**Codex finish by** (Codex follows its own window)
- [x] Sat 7 AM
- [x] Codex reset
'''
        # Check both orders so the new groups cannot shadow the Claude headings.
        for body in (codex + BODY, BODY.replace('---', codex + '\n---')):
            self.assertEqual(g.parse_dial(body), g.parse_dial(BODY))

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
                    {'body': '**HALT (usage breaker)** (Mac tick) at 81', 'author_association': 'OWNER', 'created_at': ts(NOW - dt.timedelta(hours=3))},
                    tick(82, NOW - dt.timedelta(hours=1))]
        u = g.parse_usage(comments)
        self.assertEqual(u['usage']['percent'], 82)
        self.assertTrue(u['halted'])
        comments.append({'body': '**RESUMED (usage breaker)** · (Mac tick, owner override)', 'author_association': 'OWNER', 'created_at': ts(NOW)})
        self.assertFalse(g.parse_usage(comments)['halted'])


class UsageBreakerPerProvider(unittest.TestCase):
    """Owner, 2026-10-09: a provider over its line halts only the work that runs on it."""

    def comments(self, *bodies):
        return [{'body': b, 'author_association': 'OWNER', 'created_at': ts(NOW - dt.timedelta(hours=len(bodies) - i))}
                for i, b in enumerate(bodies)]

    def advice_tick(self, advice):
        return (f'**02:16 CDT (Mac tick)** · next x\n- pace: Claude 80% used, 83% of the week gone '
                f'(3 under the line). Codex 85% used, 30% gone (far over its line).\n'
                f'- advice for dispatch: {advice}\n')

    def test_codex_halt_leaves_claude_running(self):
        u = g.parse_usage(self.comments(self.advice_tick('HALT (usage breaker: Codex): Codex tasks pause.')))
        self.assertFalse(u['halted'])
        self.assertEqual(u['halted_by'], ['codex'])
        self.assertTrue(g.decide(NOW, g.parse_dial(BODY), dict(u, usage={'percent': 82, 'at': NOW}),
                                 10, None, {}, 0)['fire'])

    def test_claude_halt_holds_claude(self):
        u = g.parse_usage(self.comments(self.advice_tick('HALT (usage breaker: Claude): no new threads.')))
        self.assertTrue(u['halted'])
        self.assertEqual(u['halted_by'], ['claude'])

    def test_both_named_then_one_resumed(self):
        u = g.parse_usage(self.comments(
            self.advice_tick('HALT (usage breaker: Claude, Codex): start nothing.'),
            '**RESUMED (usage breaker: Claude)** · under the line again'))
        self.assertFalse(u['halted'])
        self.assertEqual(u['halted_by'], ['codex'])

    def test_unscoped_resumed_clears_every_provider(self):
        u = g.parse_usage(self.comments(
            '**HALT (usage breaker: Claude, Codex)** (Mac tick) at 81',
            '**RESUMED (usage breaker)** · owner override'))
        self.assertEqual(u['halted_by'], [])

    def test_unscoped_halt_in_first_line_still_halts_claude(self):
        u = g.parse_usage(self.comments('**HALT (usage breaker)** (Mac tick) at 81'))
        self.assertTrue(u['halted'])
        self.assertEqual(u['halted_by'], ['claude', 'codex'])

    def test_unscoped_halt_in_advice_line_is_ignored(self):
        # The old tick wording; it can't tell which provider is over, so the gate leaves it.
        u = g.parse_usage(self.comments(self.advice_tick('HALT (usage breaker): start no new threads.')))
        self.assertFalse(u['halted'])

    def test_quoted_marker_in_a_plain_comment_is_ignored(self):
        u = g.parse_usage(self.comments('Please do not post HALT (usage breaker: Claude) yet'))
        self.assertFalse(u['halted'])

    def test_provider_names_ignore_case_and_spacing(self):
        u = g.parse_usage(self.comments('**HALT (usage breaker:  codex ,CLAUDE )** (Mac tick)'))
        self.assertEqual(u['halted_by'], ['claude', 'codex'])


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

    def test_paced_fires_eight_points_ahead_of_trend(self):
        # 2026-10-19: the worker held all evening at 44% against a 36% line while the breaker allowed 10.
        dial = g.parse_dial(BODY.replace('- [x] Fri noon', '- [ ] Fri noon'))  # finish at the reset: line ~70% now
        usage = g.parse_usage([tick(78, NOW - dt.timedelta(minutes=30))])
        self.assertTrue(self.decide(dial=dial, usage_info=usage)['fire'])

    def test_paced_fires_when_within_slack_of_trend(self):
        self.assertTrue(self.decide()['fire'])  # Fri noon: line ~79%, usage 82%

    def test_empty_ready_queue_does_nothing(self):
        self.assertFalse(self.decide(ready_count=0)['fire'])

    def test_halt_holds_paced(self):
        usage = dict(self.usage, halted=True)
        self.assertFalse(self.decide(usage_info=usage)['fire'])


def claim(title, issue, at):
    return {'body': f'Claimed by project thread "{title}" at {at:%Y-%m-%d %H:%M} UTC. Likely files: x.',
            'author_association': 'OWNER', 'created_at': ts(at), 'issue_url': f'https://api.github.com/repos/o/r/issues/{issue}'}


def stop(title, issue, at):
    return {'body': f'Thread "{title}" stopping: PR #900 armed · context near 250k',
            'author_association': 'OWNER', 'created_at': ts(at), 'issue_url': f'https://api.github.com/repos/o/r/issues/{issue}'}


def comment(issue, at, body='Progress: tests written.'):
    return {'body': body, 'author_association': 'OWNER', 'created_at': ts(at), 'issue_url': f'https://api.github.com/repos/o/r/issues/{issue}'}


def push(branch, at):
    return {'type': 'PushEvent', 'author_association': 'OWNER', 'created_at': ts(at), 'payload': {'ref': f'refs/heads/{branch}'}}


def ago(**kw):
    return NOW - dt.timedelta(**kw)


def by_stranger(item):
    return dict(item, author_association='NONE', user={'login': 'mallory'})


class Strangers(unittest.TestCase):
    """#1822: anyone can comment once the repo is public, so only trusted authors move the gate."""

    def test_a_strangers_halt_does_not_halt_the_project(self):
        halt = by_stranger({'body': '**HALT (usage breaker)** (Mac tick) at 99', 'created_at': ts(NOW)})
        self.assertFalse(g.parse_usage([tick(10, NOW - dt.timedelta(hours=1)), halt])['halted'])
        self.assertTrue(g.parse_usage([dict(halt, **{'author_association': 'OWNER', 'user': {'login': 'uncomposed'}})])['halted'])

    def test_a_strangers_usage_figure_is_not_the_macs(self):
        forged = by_stranger(tick(99, NOW))
        info = g.parse_usage([tick(10, NOW - dt.timedelta(hours=1)), forged])
        self.assertEqual(info['usage']['percent'], 10)

    def test_a_strangers_resume_does_not_lift_a_halt(self):
        halt = {'body': '**HALT (usage breaker)** (Mac tick) at 81', 'author_association': 'OWNER', 'created_at': ts(NOW - dt.timedelta(hours=1))}
        resume = by_stranger({'body': '**RESUMED (usage breaker)** · (Mac tick)', 'created_at': ts(NOW)})
        self.assertTrue(g.parse_usage([halt, resume])['halted'])

    def test_a_strangers_claim_note_is_not_a_thread(self):
        forged = by_stranger(claim('Fake thread', 592, ago(minutes=5)))
        self.assertEqual(g.parse_threads([forged], [], NOW), [])

    def test_a_strangers_comment_naming_a_thread_is_not_a_sign_of_life(self):
        old = claim('A', 592, ago(hours=3))
        named = by_stranger(comment(592, ago(minutes=1), body='"A" is great'))
        thread = g.parse_threads([old, named], [], NOW)[0]
        self.assertEqual(thread['state'], 'quiet')

    def test_a_strangers_stop_note_does_not_end_a_thread(self):
        thread = g.parse_threads([claim('A', 592, ago(minutes=30)), by_stranger(stop('A', 592, ago(minutes=5)))], [], NOW)[0]
        self.assertEqual(thread['state'], 'active')

    def test_a_strangers_acknowledgement_is_not_the_coordinators(self):
        forged = by_stranger({'body': g.ACK_MARK + '\nAck fire-20261001T1200Z · running 3', 'created_at': ts(NOW), 'id': 5})
        self.assertIsNone(g.parse_ack([forged]))


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


class StatusBreaker(unittest.TestCase):
    def status(self, halt):
        dial = g.parse_dial(BODY)
        usage = g.parse_usage([tick(82, NOW - dt.timedelta(minutes=30)),
                               {'body': f'**{halt}** (Mac tick)', 'author_association': 'OWNER', 'created_at': ts(NOW)}])
        decision = g.decide(NOW, dial, usage, 10, None, {}, 0)
        return g.status_text(NOW, dial, usage, 10, None, {}, decision, [])

    def test_codex_halt_is_named_and_does_not_hold(self):
        text = self.status('HALT (usage breaker: Codex)')
        self.assertIn('Usage breaker: Codex halted (not Claude, so this gate is unaffected)', text)

    def test_claude_halt_is_named_and_holds(self):
        text = self.status('HALT (usage breaker: Claude)')
        self.assertIn('Usage breaker: Claude halted (Claude, so this gate holds)', text)
        self.assertIn('HALT (usage breaker: Claude)', text)


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


class PerProviderSlots(unittest.TestCase):
    """2026-10-14: the Dial gave Claude 2 slots and Codex 3, but Codex workers were counted
    against Claude's 2, so the gate read "2 of 2" with only Codex workers running."""
    DIAL = BODY.replace('- [x] 3\n- [ ] 4', '- [ ] 3\n- [x] 2').replace('- [ ] Any slot opens', '- [x] Any slot opens')
    COMMENTS = [claim('Codex worker 1', 1577, ago(minutes=20)), claim('Codex worker 2', 861, ago(minutes=10))]

    def setUp(self):
        self.dial = g.parse_dial(self.DIAL)
        self.threads = g.parse_threads(self.COMMENTS, [], NOW)
        self.usage = g.parse_usage([tick(40, ago(minutes=30))])

    def test_fixture_reads_two_claude_threads(self):
        self.assertEqual(self.dial['threads'], 2)

    def test_codex_workers_are_not_claude_threads(self):
        self.assertEqual({t['title']: t['provider'] for t in self.threads},
                         {'Codex worker 1': 'codex', 'Codex worker 2': 'codex'})
        self.assertEqual(g.active_count(self.threads), 0)
        self.assertEqual(g.active_count(self.threads, 'codex'), 2)

    def test_only_codex_workers_running_leaves_both_claude_slots_open(self):
        decision = g.decide(NOW, self.dial, self.usage, 10, None, {}, g.active_count(self.threads))
        self.assertTrue(decision['fire'], decision['why'])
        self.assertIn('0 of 2', decision['why'])

    def test_claude_threads_still_fill_claude_slots_beside_codex_workers(self):
        threads = g.parse_threads(self.COMMENTS + [claim('Podcast anchors', 592, ago(minutes=5)),
                                                   claim('Zotero export', 588, ago(minutes=4))], [], NOW)
        self.assertEqual(g.active_count(threads), 2)
        self.assertEqual(g.active_count(threads, 'codex'), 2)
        state = {'last_fire': 'fire-x', 'last_fire_at': ts(ago(hours=1))}
        ack = {'fire': 'fire-x', 'running': None, 'at': NOW}
        decision = g.decide(NOW, self.dial, self.usage, 10, ack, state, g.active_count(threads))
        self.assertFalse(decision['fire'])
        self.assertIn('2 of 2 threads are active', decision['why'])

    def test_a_codex_claim_does_not_acknowledge_a_claude_fire(self):
        self.assertEqual(g.claims_since(self.threads, ago(hours=1)), 0)
        self.assertEqual(g.claims_since(self.threads, ago(hours=1), 'codex'), 2)

    def test_title_matching_is_exact_to_the_worker_format(self):
        for title in ('Codex worker 3', 'codex worker 12', ' Codex worker 1 '):
            self.assertEqual(g.thread_provider(title), 'codex', title)
        for title in ('Codex worker', 'Codex workers 1', 'Fix Codex worker 1 crash', 'Mac finisher', 'Podcast anchors'):
            self.assertEqual(g.thread_provider(title), 'claude', title)

    def test_fire_payload_states_claudes_number_and_claudes_count(self):
        threads = g.parse_threads(self.COMMENTS + [claim('Podcast anchors', 592, ago(minutes=5))], [], NOW)
        active = [t for t in g.of_provider(threads) if t['state'] == 'active']
        text = g.fire_text('fire-1', self.dial['threads'], active)
        self.assertIn('allows up to 2 Claude threads', text)
        self.assertIn('1 Claude threads look active', text)
        self.assertIn('"Podcast anchors"', text)
        self.assertNotIn('Codex worker 1"', text)

    def test_status_counts_claude_and_names_codex_separately(self):
        decision = g.decide(NOW, self.dial, self.usage, 10, None, {}, 0)
        text = g.status_text(NOW, self.dial, self.usage, 10, None, {}, decision, self.threads)
        self.assertIn('Active threads: 0 of 2 (Claude).', text)
        self.assertIn('Codex workers active: 2', text)


class RequestHeaderTests(unittest.TestCase):
    def test_a_write_says_it_is_json_and_a_read_does_not(self):
        from unittest import mock

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'{}'

        with mock.patch.object(g.urllib.request, 'urlopen', return_value=Response()) as opened:
            g.gh('POST', 'repos/o/r/issues/1/comments', 't', {'body': 'x'})
            g.gh('GET', 'repos/o/r/issues/1', 't')
        write, read = (call.args[0] for call in opened.call_args_list)
        self.assertEqual(write.get_header('Content-type'), 'application/json')  # form-encoded gets 415 (#2265)
        self.assertIsNone(read.get_header('Content-type'))


if __name__ == '__main__':
    unittest.main()
