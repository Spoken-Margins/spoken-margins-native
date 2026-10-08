"""Host tests for the Codex worker. Run: python3 -m unittest ops/codex/test_sm_codex_worker.py

No network, no real Codex, no real gh: every side effect goes through a fake. Git is faked too,\nexcept SaveDiffTests, which runs it in a throwaway repo.
"""
import datetime as dt
import json
import os
import shutil
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_codex_worker as w  # noqa: E402

NOW = dt.datetime(2026, 10, 1, 13, 0, tzinfo=dt.timezone.utc)
CODEX_RESET = int(dt.datetime(2026, 10, 6, 14, 10, tzinfo=dt.timezone.utc).timestamp())

DIAL = """Tap one box in each group.

**Mode**
- [ ] Off: nothing new starts
- [{paced}] Paced: keep threads going
- [{off}] Off again

**Threads**
- [x] 3

**Stop line** (weekly usage; new work holds 3 points below it)
- [ ] 80%
- [x] 90%

{codex}
---
- [x] 3
"""


def dial(codex_group: str = '', mode: str = 'paced') -> str:
    return DIAL.format(paced='x' if mode == 'paced' else ' ', off='x' if mode == 'off' else ' ',
                       codex=codex_group)


def codex_group(*ticked: int) -> str:
    lines = ['**Codex workers**']
    for n in range(4):
        lines.append(f"- [{'x' if n in ticked else ' '}] {n}")
    return '\n'.join(lines)


def codex_pacing(stops=(), finishes=()) -> str:
    lines = ['**Codex stop line** (Codex weekly usage; Codex holds 3 points below it)']
    lines += [f"- [{'x' if n in stops else ' '}] {n}%" for n in (70, 80, 90, 97)]
    lines += ['**Codex finish by** (Codex follows a straight line from its window\'s start)']
    lines += [f"- [{'x' if name in finishes else ' '}] {name}"
              for name in ('Fri noon', 'Sat 7 AM', 'Codex reset')]
    return '\n'.join(lines)


def limits_result(used, window_mins=7 * 24 * 60, resets_at=None, secondary=None):
    resets_at = resets_at if resets_at is not None else int(NOW.timestamp()) + 3 * 24 * 3600
    rl = {'primary': {'usedPercent': used, 'windowDurationMins': window_mins, 'resetsAt': resets_at}}
    if secondary is not None:
        rl['secondary'] = {'usedPercent': secondary, 'windowDurationMins': 300, 'resetsAt': resets_at}
    return {'rateLimits': rl}


def issue(number, labels=('ready',), created='2026-09-20T10:00:00Z', body='', title=None, comments=()):
    return {'number': number, 'title': title or f'Issue {number}', 'body': body, 'state': 'OPEN',
            'labels': [{'name': n} for n in labels], 'createdAt': created, 'comments': list(comments)}


def claim(at):
    return {'body': 'Claimed by project thread "Something" at x', 'createdAt': at}


# ---------------------------------------------------------------------------
# Dial
# ---------------------------------------------------------------------------

class DialTests(unittest.TestCase):
    def setUp(self):
        self.parse = w.load_parse_dial()
        self.assertIsNotNone(self.parse, 'ops/dial/dial_gate.py must import')

    def read(self, body):
        return w.read_dial(body, self.parse)

    def test_no_group_reads_zero(self):
        d = self.read(dial(''))
        self.assertEqual(d['workers'], 0)
        self.assertIn('no Codex workers group', d['problems'][0])

    def test_group_without_tick_reads_zero(self):
        self.assertEqual(self.read(dial(codex_group()))['workers'], 0)

    def test_zero_one_two(self):
        for n in (0, 1, 2, 3):
            self.assertEqual(self.read(dial(codex_group(n)))['workers'], n)

    def test_two_ticks_take_the_lower(self):
        d = self.read(dial(codex_group(2, 1)))
        self.assertEqual(d['workers'], 1)
        self.assertTrue(any('lowest, 1' in p for p in d['problems']))

    def test_mode_off_reads_zero(self):
        d = self.read(dial(codex_group(2), mode='off'))
        self.assertEqual((d['mode'], d['workers']), ('off', 0))

    def test_stop_line_comes_from_the_dial(self):
        self.assertEqual(self.read(dial(codex_group(1)))['stop'], 90)

    def test_no_codex_pacing_groups_preserve_the_old_line(self):
        # Claude's finish-by must not change Codex's default weekly-reset target.
        body = dial(codex_group(1) + '\n**Finish by**\n- [x] Fri noon')
        d = self.read(body)
        limits = w.parse_rate_limits(limits_result(50))
        self.assertEqual((d['stop'], d['stop_source'], d['finish_by']),
                         (90, 'Dial Stop line', ('Codex reset',)))
        self.assertAlmostEqual(w.trend_line(NOW.timestamp(), limits, d['stop'], d['finish_by']),
                               90 * 4 / 7)

    def test_codex_stop_line_only_overrides_the_shared_stop(self):
        body = dial(codex_group(1) + '\n**Codex stop line**\n- [x] 70%')
        d = self.read(body)
        self.assertEqual((d['stop'], d['stop_source'], d['finish_by']),
                         (70, 'Codex stop line', ('Codex reset',)))
        self.assertIn('hold line 67%', w.pacing_hold(NOW.timestamp(), d['stop'],
                      w.parse_rate_limits(limits_result(67)), 100 * 2**30, d['finish_by']))

    def test_empty_codex_groups_keep_the_fallbacks(self):
        d = self.read(dial(codex_group(1) + '\n' + codex_pacing()))
        self.assertEqual((d['stop'], d['stop_source'], d['finish_by']),
                         (90, 'Dial Stop line', ('Codex reset',)))

    def test_two_stop_ticks_take_the_lower(self):
        d = self.read(dial(codex_group(1) + '\n' + codex_pacing((80, 97))))
        self.assertEqual(d['stop'], 80)
        self.assertTrue(any('lowest, 80%' in p for p in d['problems']))

    def test_muddled_stop_group_holds_instead_of_using_a_higher_fallback(self):
        for ticks in ('- [x] seventy', '- [x] 70%\n- [x] ninety?', '- [x] 970%'):
            with self.subTest(ticks=ticks):
                d = self.read(dial(codex_group(1) + '\n**Codex stop line**\n' + ticks))
                self.assertIsNone(d['stop'])
                self.assertTrue(d['problems'])

    def test_muddled_finish_group_uses_reset(self):
        d = self.read(dial(codex_group(1) + '\n**Codex finish by**\n- [x] Friday-ish'))
        self.assertEqual(d['finish_by'], ('Codex reset',))
        self.assertTrue(any('Codex finish by' in p for p in d['problems']))

    def test_repeated_groups_and_uppercase_ticks_stay_cautious(self):
        body = dial(codex_group(1) + '\n' + codex_pacing((97,)) +
                    '\n**Codex stop line**\n- [X] 70%\n**Codex finish by**\n- [X] Fri noon')
        d = self.read(body)
        self.assertEqual((d['stop'], d['finish_by']), (70, ('Fri noon',)))

    def test_pacing_ticks_after_the_rule_do_not_override_the_fallback(self):
        body = dial(codex_group(1)) + '\n- [x] 70%\n- [x] Fri noon'
        d = self.read(body)
        self.assertEqual((d['stop'], d['finish_by']), (90, ('Codex reset',)))

    def test_ticks_after_the_rule_are_ignored(self):
        # The stray "- [x] 3" after --- must not count as a Codex workers tick.
        self.assertEqual(self.read(dial(codex_group(1)))['workers'], 1)

    def test_parse_dial_missing_reads_off(self):
        d = w.read_dial(dial(codex_group(2)), None)
        self.assertEqual(d['workers'], 0)

    def test_parse_dial_raising_reads_off(self):
        def boom(_):
            raise ValueError('bad')
        self.assertEqual(w.read_dial(dial(codex_group(2)), boom)['workers'], 0)

    def test_newer_parse_dial_with_extra_fields_works(self):
        def newer(body):
            return {'mode': 'paced', 'stop': 80, 'threads': 3, 'refill_at': 1, 'problems': []}
        self.assertEqual(w.read_dial(dial(codex_group(2)), newer)['workers'], 2)


# ---------------------------------------------------------------------------
# Pacing
# ---------------------------------------------------------------------------

class PacingTests(unittest.TestCase):
    PLENTY = 100 * 2**30

    def hold(self, result, stop=90, free=PLENTY):
        return w.pacing_hold(NOW.timestamp(), stop, w.parse_rate_limits(result), free)

    def test_go_when_on_trend(self):
        # 4 of 7 days through the window: trend 90 * 4/7 = 51.4; 50 is fine.
        self.assertIsNone(self.hold(limits_result(50)))

    def test_hold_at_stop_line_minus_margin(self):
        self.assertIn('hold line 87%', self.hold(limits_result(87, resets_at=int(NOW.timestamp()) + 60)))

    def test_secondary_window_counts_for_the_stop_line(self):
        self.assertIn('hold line', self.hold(limits_result(10, secondary=88)))

    def test_hold_ahead_of_trend(self):
        self.assertIn('ahead of the', self.hold(limits_result(57)))

    def test_trend_slack_is_five_points(self):
        line = w.trend_line(NOW.timestamp(), w.parse_rate_limits(limits_result(0)), 90)
        self.assertAlmostEqual(line, 90 * 4 / 7, places=3)
        self.assertIsNone(self.hold(limits_result(int(line + 5))))

    def test_fri_noon_before_the_time_frontloads_from_window_start(self):
        # Tue Sep 29 10:10 EDT -> Fri Oct 2 noon EDT (73 h 50 m).
        limits = w.parse_rate_limits(limits_result(60, resets_at=CODEX_RESET))
        d = w.read_dial(dial(codex_group(1) + '\n' + codex_pacing(finishes=('Fri noon',))),
                        w.load_parse_dial())
        line = w.trend_line(NOW.timestamp(), limits, d['stop'], d['finish_by'])
        self.assertAlmostEqual(line, 90 * (46 * 60 + 50) / (73 * 60 + 50))
        self.assertIsNone(w.pacing_hold(NOW.timestamp(), d['stop'], limits, self.PLENTY, d['finish_by']))
        limits['used'] = line + 5.01
        self.assertIn('ahead of the', w.pacing_hold(NOW.timestamp(), d['stop'], limits,
                                                 self.PLENTY, d['finish_by']))

    def test_fri_noon_after_the_time_stays_at_stop_and_keeps_margin(self):
        limits = w.parse_rate_limits(limits_result(86, resets_at=CODEX_RESET))
        d = w.read_dial(dial(codex_group(1) + '\n' + codex_pacing(finishes=('Fri noon',))),
                        w.load_parse_dial())
        for now in (dt.datetime(2026, 10, 2, 16, tzinfo=dt.timezone.utc),
                    dt.datetime(2026, 10, 3, 18, tzinfo=dt.timezone.utc)):
            with self.subTest(now=now):
                self.assertEqual(w.trend_line(now.timestamp(), limits, d['stop'], d['finish_by']), 90)
                self.assertIsNone(w.pacing_hold(now.timestamp(), d['stop'], limits, self.PLENTY, d['finish_by']))
                self.assertIn('hold line 87%', w.pacing_hold(now.timestamp(), d['stop'],
                              dict(limits, worst=87), self.PLENTY, d['finish_by']))

    def test_two_finish_ticks_take_the_later_resolved_deadline(self):
        limits = w.parse_rate_limits(limits_result(0, resets_at=CODEX_RESET))
        saturday = dt.datetime(2026, 10, 3, 11, tzinfo=dt.timezone.utc).timestamp()
        for choices, label, end in ((('Fri noon', 'Sat 7 AM'), 'Sat 7 AM', saturday),
                                    (('Fri noon', 'Codex reset'), 'Codex reset', CODEX_RESET)):
            with self.subTest(choices=choices):
                d = w.read_dial(dial(codex_group(1) + '\n' + codex_pacing(finishes=choices)),
                                w.load_parse_dial())
                self.assertEqual(w.finish_target(limits, d['finish_by']), (label, end))
                self.assertTrue(any('later' in p for p in d['problems']))

    def test_finish_is_next_occurrence_after_start_not_after_now(self):
        # A window starting Friday afternoon reaches Sat before the next Fri noon.
        reset = dt.datetime(2026, 10, 9, 18, tzinfo=dt.timezone.utc).timestamp()
        limits = w.parse_rate_limits(limits_result(0, resets_at=reset))
        label, end = w.finish_target(limits, ('Fri noon', 'Sat 7 AM'))
        self.assertEqual(label, 'Fri noon')
        self.assertEqual(end, dt.datetime(2026, 10, 9, 16, tzinfo=dt.timezone.utc).timestamp())
        self.assertEqual(w.trend_line(reset - 60, limits, 90, ('Fri noon',)), 90)

    def test_eastern_finish_observes_dst_and_skips_start_itself(self):
        reset = dt.datetime(2026, 11, 6, 16, tzinfo=dt.timezone.utc).timestamp()
        limits = w.parse_rate_limits(limits_result(0, resets_at=reset))
        # Start is exactly Fri noon EDT; the next Fri noon is in EST.
        label, end = w.finish_target(limits, ('Fri noon',))
        self.assertEqual(end, dt.datetime(2026, 11, 6, 17, tzinfo=dt.timezone.utc).timestamp())
        self.assertEqual(w.trend_line(reset - 7 * 24 * 3600 - 1, limits, 90, ('Fri noon',)), 0)

    def test_muddled_finish_with_a_valid_tick_does_not_accelerate_spending(self):
        body = dial(codex_group(1) + '\n**Codex finish by**\n- [x] Fri noon\n- [x] tomorrow?')
        d = w.read_dial(body, w.load_parse_dial())
        limits = w.parse_rate_limits(limits_result(60, resets_at=CODEX_RESET))
        self.assertEqual(w.finish_target(limits, d['finish_by']), ('Codex reset', CODEX_RESET))
        self.assertIn('ahead of the', w.pacing_hold(NOW.timestamp(), d['stop'], limits,
                                                 self.PLENTY, d['finish_by']))

    def test_hold_when_read_failed(self):
        self.assertIn('could not be read', self.hold(None))
        self.assertIn('could not be read', self.hold({'rateLimits': {'primary': {'usedPercent': 5}}}))

    def test_hold_without_stop_line(self):
        self.assertIn('Stop line', self.hold(limits_result(5), stop=None))

    def test_hold_low_disk(self):
        self.assertIn('GiB free disk', self.hold(limits_result(5), free=29 * 2**30))
        self.assertIsNone(self.hold(limits_result(5), free=30 * 2**30))


# ---------------------------------------------------------------------------
# Slots
# ---------------------------------------------------------------------------

class SlotTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='cw-'))

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def test_counts_live_and_dead(self):
        w.write_lock(self.home, 1, {'pid': 111, 'issue': 5})
        w.write_lock(self.home, 2, {'pid': 222, 'issue': 6})
        (self.home / 'slot-3.lock').write_text('not json')
        live, dead = w.scan_slots(self.home, alive=lambda pid: pid == 111)
        self.assertEqual(sorted(live), [1])
        self.assertEqual(sorted(s for s, _, _ in dead), [2, 3])

    def test_free_slot(self):
        self.assertEqual(w.free_slot({}, 2), 1)
        self.assertEqual(w.free_slot({1: {}}, 2), 2)
        self.assertIsNone(w.free_slot({1: {}, 2: {}}, 2))
        self.assertIsNone(w.free_slot({}, 0))
        # Dial lowered below the live count: nothing new.
        self.assertIsNone(w.free_slot({2: {}, 3: {}}, 1))

    def test_missing_home_is_empty(self):
        live, dead = w.scan_slots(self.home / 'nope', alive=lambda pid: True)
        self.assertEqual((live, dead), ({}, []))


# ---------------------------------------------------------------------------
# Issue choice
# ---------------------------------------------------------------------------

class IssueTests(unittest.TestCase):
    def test_excluded_labels(self):
        for lab in ('in-progress', 'where:mac', 'regression', 'blocked'):
            ok, why = w.eligible(issue(1, labels=('ready', lab)), [], NOW)
            self.assertFalse(ok, lab)
            self.assertIn(lab, why)

    def test_needs_ready(self):
        self.assertFalse(w.eligible(issue(1, labels=('bug',)), [], NOW)[0])

    def test_recent_claim_blocks_old_claim_does_not(self):
        self.assertFalse(w.eligible(issue(1), [claim('2026-10-01T01:00:00Z')], NOW)[0])
        self.assertTrue(w.eligible(issue(1), [claim('2026-09-29T01:00:00Z')], NOW)[0])

    def test_held_by_live_slot(self):
        self.assertFalse(w.eligible(issue(7), [], NOW, held={7})[0])

    def test_prefers_sessionkit_then_oldest(self):
        issues = [
            issue(10, created='2026-09-01T00:00:00Z', body='Gate1RootView layout'),
            issue(11, created='2026-09-10T00:00:00Z', body='Fix in Packages/SessionKit/Sources/SessionKit/X.swift'),
            issue(12, created='2026-09-05T00:00:00Z', body='host test in SessionKitAudio/'),
        ]
        self.assertEqual([i['number'] for i in w.order_issues(issues)], [12, 11, 10])

    def test_priority_label_goes_first(self):
        issues = [
            issue(20, created='2026-09-01T00:00:00Z', body='host test in SessionKitAudio/'),
            issue(21, labels=('ready', 'priority'), created='2026-09-30T00:00:00Z', body='Gate1RootView layout'),
            issue(22, created='2026-09-02T00:00:00Z', body='Gate1RootView layout'),
        ]
        self.assertEqual([i['number'] for i in w.order_issues(issues)], [21, 20, 22])

    def test_choose_skips_and_fetches_comments_lazily(self):
        issues = [issue(1, labels=('ready', 'blocked')), issue(2, created='2026-09-01T00:00:00Z'),
                  issue(3, created='2026-09-02T00:00:00Z')]
        fetched = []
        comments = {2: [claim('2026-10-01T12:00:00Z')], 3: []}

        def comments_for(n):
            fetched.append(n)
            return comments[n]
        chosen, skipped = w.choose_issue(issues, comments_for, NOW)
        self.assertEqual(chosen['number'], 3)
        self.assertEqual(fetched, [2, 3])
        self.assertEqual([n for n, _ in skipped], [2])  # 1 is newer than 3, so never reached

    def test_choose_none(self):
        self.assertEqual(w.choose_issue([issue(1, labels=('ready', 'in-progress'))], lambda n: [], NOW)[0], None)

    def test_awaiting_owner_validation_is_skipped(self):
        ok, why = w.eligible(issue(1, labels=('ready', 'status: needs-human-validation')), [], NOW)
        self.assertFalse(ok)
        self.assertIn('needs-human-validation', why)


class FocusLinkTests(unittest.TestCase):
    def test_branch_title_and_closing_words_link_issues(self):
        self.assertEqual(w.linked_issues({'headRefName': 'ws/854-build30-fix-9okbzn', 'title': 'Keep narration'}), {854})
        self.assertEqual(w.linked_issues({'headRefName': 'codex/868-bound-edition-digest'}), {868})
        self.assertEqual(w.linked_issues({'headRefName': 'claude/following-score-lyp08z',
                                          'title': 'Following: order new items (#484)'}), {484})
        self.assertEqual(w.linked_issues({'headRefName': 'ws/c1-322-upgrade', 'body': 'Fixes #322. See #100.'}), {322})
        self.assertEqual(w.linked_issues({'headRefName': 'x', 'body': 'part of #538; closes #12'}), {538, 12})

    def test_unrelated_mentions_do_not_link(self):
        self.assertEqual(w.linked_issues({'headRefName': 'ws/c1-344-control', 'title': 'Control for #344',
                                          'body': 'Like #100 and PR #200'}), set())

    def test_in_focus(self):
        pr = {'headRefName': 'ws/858-one-copy-per-margin'}
        self.assertTrue(w.in_focus(pr, None))
        self.assertTrue(w.in_focus(pr, {858, 1}))
        self.assertFalse(w.in_focus(pr, {1}))
        self.assertFalse(w.in_focus(pr, set()))


# ---------------------------------------------------------------------------
# Fakes for the tick and the child
# ---------------------------------------------------------------------------

HEAD = 'abcdef0123456789abcdef0123456789abcdef0123'


def pull(labels=(), comments=None, **extra):
    return dict(number=73, title='Fix playback', body='body', state='OPEN', isDraft=False,
                baseRefName='next', headRefName='ws/73-playback', headRefOid=HEAD,
                headRepository={'name': w.REPO.split('/')[1]},
                headRepositoryOwner={'login': w.REPO.split('/')[0]}, isCrossRepository=False,
                files=[{'path': 'Packages/SessionKit/Sources/SessionKit/Playback.swift'}],
                labels=list(labels), comments=comments or [], createdAt='2026-09-30T00:00:00Z',
                **extra)


def lane(verdict='FAIL', head=HEAD[:7], detail='simulator build (fail)', at='2026-10-01T12:00:00Z'):
    return {'createdAt': at, 'body': f'Lane report pr73-r1 — {verdict}\n'
            f'commit {head} (tested merged with next at 1234567) · tier auto\nran: {detail}\n'
            'evidence: /tmp/lane/73 (on the Mac)'}


def audit(text='[P2] Preserve the anchor on resume', head=HEAD[:7], at='2026-10-01T12:00:00Z'):
    return {'createdAt': at, 'body': f'**Codex audit (Astra) on `{head}`**\n\n{text}\n\n---\nAudit footer'}


class FinishSelectionTests(unittest.TestCase):
    def eligible(self, pr):
        return w.finish_eligible(pr, NOW)[0]

    def test_only_newest_report_on_head(self):
        self.assertTrue(self.eligible(pull(comments=[lane()])))
        self.assertFalse(self.eligible(pull(comments=[lane(head='9876543')])))
        for verdict in ('PASS', 'INCONCLUSIVE'):
            self.assertFalse(self.eligible(pull(comments=[lane(), lane(verdict, at='2026-10-01T12:01:00Z')])))
        self.assertTrue(self.eligible(pull(comments=[lane(detail='host tests (--plan fast) — expected: verified. observed: exit 1')])))
        self.assertTrue(self.eligible(pull(comments=[lane(detail='PlaybackTests/testResume — expected: passes. observed: failed.')])))

    def test_runner_faults_and_unknown_failures_skipped(self):
        for detail in ('nothing', 'The lane itself failed: runner fault',
                       'Not in any app test plan: MissingTest',
                       'simulator build (fail)\nThis is the lane\'s fault, not the PR\'s',
                       'host tests (--plan fast) — expected: verified. observed: exit 1\nPermissionError: denied'):
            self.assertFalse(self.eligible(pull(comments=[lane(detail=detail)])), detail)

    def test_t3_compile_report_with_real_swift_diagnostic(self):
        report = lane(detail='PlaybackTests (0 passed; app plan, build and tests, 1m)\n'
                      'app: Process exit 65. evidence: /tmp/lane/manifest.json\n'
                      'app: /src/Playback.swift:12:8: error: cannot find anchor in scope')
        self.assertTrue(self.eligible(pull(comments=[report])))

    def test_needs_mac_and_exclusions(self):
        self.assertTrue(self.eligible(pull(labels=['needs-mac'])))
        for key, value in (('isDraft', True), ('baseRefName', 'main'), ('state', 'CLOSED'),
                           ('headRefName', 'main'), ('headRefName', 'next'),
                           ('isCrossRepository', True), ('headRepository', None),
                           ('headRepositoryOwner', {'login': 'someone-else'})):
            pr = pull(labels=['needs-mac'])
            pr[key] = value
            self.assertFalse(self.eligible(pr), key)
        self.assertFalse(w.finish_eligible(pull(labels=['needs-mac']), NOW, {73})[0])

    def test_lane_paths_use_the_scope_policy(self):
        for path in sorted(w._scope.LANE_FILES) + [p + 'example' for p in w._scope.LANE_PREFIXES]:
            pr = pull(labels=['needs-mac'])
            pr['files'] = [{'path': path}]
            self.assertFalse(self.eligible(pr), path)
        pr['files'] = [{'path': 'scripts/tests/test_lane_runner.py'}]
        self.assertTrue(self.eligible(pr))

    def test_two_finishing_rounds_per_24_hours(self):
        c = {'body': 'Thread "Codex worker 2" finishing #73', 'createdAt': '2026-10-01T01:00:00Z'}
        second = dict(c, createdAt='2026-10-01T02:00:00Z')
        self.assertTrue(self.eligible(pull(labels=['needs-mac'], comments=[c])))
        for trigger in (pull(labels=['needs-mac']), pull(comments=[lane()]), pull(comments=[audit()])):
            trigger['comments'] += [c, second]
            self.assertFalse(self.eligible(trigger))
            # Exactly 24 h old is outside the rolling window, even after the head changes.
            c['createdAt'] = '2026-09-30T13:00:00Z'
            self.assertTrue(self.eligible(trigger))
            c['createdAt'] = '2026-10-01T01:00:00Z'
        for at in ('', 'invalid'):
            self.assertFalse(self.eligible(pull(labels=['needs-mac'], comments=[dict(c, createdAt=at)])))

    def test_other_finishers_claims_hold_for_two_hours(self):
        for text in ('Finisher two taking this.', 'Mac finisher taking this PR.',
                     'Finisher one taking this.\n\nMerging next first.', '**Mac finisher taking this PR.**'):
            claim = {'body': text, 'createdAt': '2026-10-01T11:30:00Z'}
            for trigger in (pull(labels=['needs-mac']), pull(comments=[lane()]), pull(comments=[audit()])):
                trigger['comments'] += [claim]
                self.assertEqual(w.finish_eligible(trigger, NOW), (False, w.OTHER_FINISHER_REASON), text)
            # Exactly two hours old no longer holds.
            self.assertTrue(self.eligible(pull(labels=['needs-mac'], comments=[dict(claim, createdAt='2026-10-01T11:00:00Z')])))
            for at in ('', 'invalid'):
                self.assertFalse(self.eligible(pull(labels=['needs-mac'], comments=[dict(claim, createdAt=at)])))
        # Codex's own claim, a quoted claim mid-comment, and a hand-off to a finisher do not hold.
        for text in ('Finisher Codex taking this.\n\nThread "Codex worker 1" finishing #73',
                     'Note: "Finisher two taking this." was posted yesterday.',
                     'Handing to the Mac finisher: build fails.'):
            self.assertTrue(self.eligible(pull(labels=['needs-mac'], comments=[{'body': text, 'createdAt': '2026-10-01T12:30:00Z'}])), text)

    def test_newest_audit_must_name_head_and_open_with_findings(self):
        self.assertTrue(self.eligible(pull(comments=[audit()])))
        self.assertFalse(self.eligible(pull(comments=[audit(head='9876543')])))
        clean = audit('No blocking findings.\nMention of [P2] in footer', at='2026-10-01T12:01:00Z')
        self.assertFalse(self.eligible(pull(comments=[clean, audit()])))
        newer = audit(at='2026-10-01T12:02:00Z')
        self.assertTrue(self.eligible(pull(comments=[newer, clean])))
        self.assertFalse(self.eligible(pull(comments=[audit(), audit(head='9876543', at=newer['createdAt'])])))
        # A quoted header or SHA mentioned only in the body is not a head audit.
        for body in ('Quoted: ' + audit()['body'], audit(head='9876543')['body'] + '\n' + HEAD[:7]):
            self.assertFalse(self.eligible(pull(comments=[{'body': body}])))

    def test_lane_paths_eligible_only_for_current_head_audit_findings(self):
        for path in sorted(w._scope.LANE_FILES) + [p + 'example' for p in w._scope.LANE_PREFIXES]:
            pr = pull(comments=[lane('PASS'), audit()])
            pr['files'] = [{'path': path}]
            self.assertTrue(self.eligible(pr), path)
            for report in (audit(head='9876543'), audit('No blocking findings.')):
                pr['comments'] = [lane(), report]
                pr['labels'] = ['needs-mac']
                self.assertFalse(self.eligible(pr), path)

    def test_audit_candidate_still_respects_protected_prs(self):
        for key, value in (('isDraft', True), ('baseRefName', 'main'), ('state', 'CLOSED'),
                           ('isCrossRepository', True), ('headRefName', 'next')):
            pr = pull(comments=[audit()])
            pr[key] = value
            self.assertFalse(self.eligible(pr), key)
        self.assertFalse(w.finish_eligible(pull(comments=[audit()]), NOW, {73})[0])

    def test_latest_lane_request_controls_t3_requeue(self):
        request = {'body': '/lane T3\ntests: SpokenMarginsAppTests/PlaybackTests',
                   'createdAt': '2026-10-01T10:00:00Z'}
        self.assertEqual(w.finish_lane_request([request]), request['body'])
        newer = {'body': '/lane T2', 'createdAt': '2026-10-01T11:00:00Z'}
        self.assertIsNone(w.finish_lane_request([request, newer]))
        with self.assertRaises(RuntimeError):
            w.finish_lane_request([{'body': '/lane T3', 'createdAt': '2026-10-01T12:00:00Z'}])
        request['body'] = '  /lane T3\r\n  tests: Class/method, Other\r\n'
        self.assertEqual(w.finish_lane_request([request]), '/lane T3\n  tests: Class/method, Other')


class FinishChildTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='cw-finish-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        self.addCleanup(setattr, w, 'FOCUS_MILESTONE', w.FOCUS_MILESTONE)
        w.FOCUS_MILESTONE = ''  # no freeze; FreezeFinishTests turns it on from the Dial
        w.write_lock(self.home, 1, {'pid': os.getpid(), 'pr': 73})

    def test_finisher_records_one_run_with_round_and_pr(self):
        self.assertEqual(self.run_finish()[0], 'finished')
        rows = [json.loads(line) for line in (self.home / 'ledger/usage.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['job'], 'finisher')
        self.assertEqual(rows[0]['output_tokens'], 10)
        self.assertEqual(rows[0]['targets'][0]['pr'], 73)
        self.assertIn('finisher round 1', rows[0]['targets'][0]['trigger'])
        self.assertEqual(rows[0]['outcome']['kind'], 'PR armed')

    def run_finish(self, fast_rc=0, fail=(), codex_ok=True, rearmed=False, moved=False, conflict=False,
                   push_rc=0, arm_failure=False, no_request=False, needs_mac_only=False, empty=False,
                   audit_only=False, checked_text=None, stage_failure=False, evidence=()):
        data = pull(labels=['needs-mac', 'automerge'], comments=[lane(),
                    {'body': '/lane T3\ntests: SpokenMarginsAppTests/PlaybackTests',
                     'createdAt': '2026-10-01T11:00:00Z'}])
        if no_request:
            data['comments'] = [lane()]
        if needs_mac_only:
            data['comments'] = []
        if audit_only:
            data['labels'] = ['automerge']
            data['comments'] = [lane('PASS'), audit()]
            data['files'] = [{'path': 'ops/codex/sm_codex_testdesk.py'}]
        test = self

        class Run(FakeRun):
            def __call__(self, cmd, cwd=None, timeout=None):
                if cmd[0] == 'git' and 'diff' in cmd and '--check' in cmd and checked_text is not None:
                    self.calls.append(list(cmd))
                    # Use real Git diagnostics without changing any repository's index.
                    result = w.default_run(cmd[:cmd.index('diff')] +
                                           ['diff', '--no-index', '--check', '--', '/dev/null',
                                            str(Path(cwd) / 'Playback.swift')], cwd=cwd)
                    # --no-index returns 1 for a clean diff; --cached returns 0.
                    return w.Result(0 if result.returncode == 1 else result.returncode,
                                    result.stdout, result.stderr)
                if cmd[:2] == ['git', 'diff'] and '--name-only' in cmd and '-z' in cmd:
                    self.calls.append(list(cmd))
                    return w.Result(0, 'Playback.swift\0' if checked_text is not None else '')
                if cmd[:2] == ['git', 'add'] and stage_failure:
                    self.calls.append(list(cmd))
                    return w.default_run(cmd, cwd=cwd)
                if cmd[:2] == ['git', 'add'] and checked_text is not None:
                    self.staged_text = (Path(cwd) / 'Playback.swift').read_text()
                if cmd[:3] == ['gh', 'pr', 'view']:
                    self.calls.append(list(cmd))
                    return w.Result(0, json.dumps(data))
                if cmd[:3] == ['gh', 'issue', 'edit']:
                    if arm_failure and cmd[-2:] == ['--add-label', 'automerge']:
                        self.calls.append(list(cmd))
                        return w.Result(1, '', 'arm failed')
                    if '--remove-label' in cmd:
                        data['labels'] = [l for l in data['labels'] if l != cmd[cmd.index('--remove-label') + 1]]
                    if '--add-label' in cmd:
                        data['labels'].append(cmd[cmd.index('--add-label') + 1])
                if cmd[:2] == ['git', 'rev-parse']:
                    self.calls.append(list(cmd))
                    if empty and cmd[-1] == 'MERGE_HEAD':
                        return w.Result(1)
                    return w.Result(0, HEAD + '\n')
                if cmd[:2] == ['git', 'push']:
                    test.assertNotIn('automerge', data['labels'])
                    self.calls.append(list(cmd))
                    return w.Result(push_rc, '', 'non-fast-forward' if push_rc else '')
                if cmd[:3] == ['git', 'worktree', 'add']:
                    self.calls.append(list(cmd))
                    Path(cmd[-2]).mkdir(parents=True, exist_ok=True)
                    return w.Result(0)
                if cmd[:2] == ['git', 'merge'] and conflict:
                    self.calls.append(list(cmd))
                    return w.Result(1, 'CONFLICT (content): Merge conflict in Playback.swift')
                if cmd[:2] == ['git', 'diff'] and '--diff-filter=U' in cmd:
                    self.calls.append(list(cmd))
                    return w.Result(0, 'Playback.swift\n' if conflict else '')
                return super().__call__(cmd, cwd, timeout)

        run = Run(test, status='' if empty else ' M Playback.swift\n', fast_rc=fast_rc, fail=fail, evidence=evidence)
        codex = fake_codex({'commit-msg.txt': 'Fix resume\n\nThe test lost its anchor; preserve it.',
                            'pr-body.md': ('Finding is wrong: the anchor is already preserved.' if empty and audit_only
                                           else 'Preserved the playback anchor.')}, ok=codex_ok)

        def run_codex(*args):
            if stage_failure:
                wt = Path(args[0])
                for command in (['git', 'init', '--quiet'],
                                ['git', '-c', 'user.name=t', '-c', 'user.email=t@t',
                                 'commit', '--quiet', '--allow-empty', '-m', 'base']):
                    test.assertEqual(w.default_run(command, cwd=wt).returncode, 0)
                (wt / '.git' / 'index.lock').write_text('another Git process owns this index')
            if checked_text is not None:
                (Path(args[0]) / 'Playback.swift').write_text(checked_text)
            if rearmed:
                data['labels'].append('automerge')
            if moved:
                data['headRefOid'] = 'f' * 40
            return codex(*args)

        ops = w.Ops(home=self.home, repo_root=self.home, run=run, codex=run_codex,
                    now=lambda: NOW, alive=lambda pid: False, echo=False)
        outcome = w.run_finish_child(ops, 1, 73)
        self.assertFalse((self.home / 'slot-1.lock').exists())
        # A run whose changes couldn't be saved keeps its worktree for a human (#710).
        self.assertEqual(run.has('git', 'worktree', 'remove', '--force'), outcome != 'kept')
        self.assertFalse(run.has('git', 'branch', '-D'))
        for command in run.calls:
            if command[:2] == ['git', 'push']:
                self.assertFalse(any(a.startswith('--force') or a.startswith('+') or a == '-f' for a in command))
        return outcome, run, data, codex

    def test_success_disarms_before_work_pushes_then_rearms(self):
        outcome, run, data, codex = self.run_finish()
        self.assertEqual(outcome, 'finished')
        writes = [c for c in run.calls if c[:3] == ['gh', 'issue', 'edit']]
        self.assertEqual([c[-2:] for c in writes], [['--remove-label', 'automerge'],
                         ['--remove-label', 'needs-mac'], ['--add-label', 'lane:queued'],
                         ['--add-label', 'automerge']])
        idx = lambda prefix: next(i for i, c in enumerate(run.calls) if c[:len(prefix)] == prefix)
        self.assertLess(idx(['gh', 'issue', 'edit']), idx(['git', 'worktree', 'add']))
        self.assertLess(idx(['git', 'commit']), idx(['git', 'push']))
        self.assertLess(idx(['git', 'push']), run.calls.index(writes[-1]))
        push = next(c for c in run.calls if c[:2] == ['git', 'push'])
        self.assertEqual(push[-2:], ['origin', 'HEAD:refs/heads/ws/73-playback'])
        self.assertIn('/lane T3\ntests: SpokenMarginsAppTests/PlaybackTests', run.comments())
        self.assertIn('Thread "Codex worker 1" finishing #73', run.comments()[0])
        self.assertIn('Lane report pr73-r1 — FAIL', codex.prompt)
        self.assertIn('Evidence summary:', codex.prompt)
        self.assertIn('Preserved the playback anchor.', '\n'.join(run.comments()))
        commit = next(c for c in run.calls if c[:2] == ['git', 'commit'])
        self.assertTrue(Path(commit[-1]).read_text().startswith('Fix lane FAIL on #73'))

    def test_failed_fast_or_codex_never_pushes_and_leaves_needs_mac(self):
        for options in ({'fast_rc': 1}, {'codex_ok': False}, {'fail': ('scripts/setup-worktree.sh',)}):
            with self.subTest(options=options):
                outcome, run, data, _ = self.run_finish(**options)
                self.assertNotEqual(outcome, 'finished')
                self.assertFalse(run.has('git', 'push'))
                self.assertEqual(set(data['labels']), {'needs-mac'})
                self.assertIn('stopping:', run.comments()[-1])

    def test_finish_fast_plan_timeout_keeps_its_evidence_after_the_worktree_goes(self):
        # #707: observed on PR #644's finishing run.
        outcome, run, _, _ = self.run_finish(fast_rc=124, evidence=('manifest.json', 'runner-tests.log'))
        self.assertEqual(outcome, 'fast-failed')
        self.assertFalse(run.has('git', 'push'))
        run_dir, = (self.home / 'runs').glob('pr-73-*')
        for name in ('manifest.json', 'runner-tests.log'):
            self.assertEqual((run_dir / 'fast-evidence' / name).read_text(), f'partial {name}\n')
        self.assertIn(f'Evidence folder: {run_dir / "fast-evidence"}', (run_dir / 'fast-plan.txt').read_text())
        self.assertFalse((self.home / 'wt-1').exists())

    def test_lane_audit_fix_gets_findings_and_rearms_after_passing_push(self):
        outcome, run, data, codex = self.run_finish(audit_only=True)
        self.assertEqual(outcome, 'finished')
        self.assertIn(audit()['body'], codex.prompt)
        self.assertIn('For each audit finding', codex.prompt)
        self.assertIn('it fails without the fix', codex.prompt)
        self.assertIn('why the finding is wrong', codex.prompt)
        self.assertEqual(data['labels'], ['automerge'])
        push = next(i for i, c in enumerate(run.calls) if c[:2] == ['git', 'push'])
        arm = next(i for i, c in enumerate(run.calls) if c[-2:] == ['--add-label', 'automerge'])
        self.assertLess(push, arm)
        self.assertFalse(any(c.startswith('/lane') for c in run.comments()))
        commit = next(c for c in run.calls if c[:2] == ['git', 'commit'])
        self.assertTrue(Path(commit[-1]).read_text().startswith('Address Codex audit findings on #73'))

    def test_finisher_tests_matching_and_sanitizing_findings_by_class(self):
        _, _, _, codex = self.run_finish(audit_only=True)
        for text in ('table of neighbouring inputs before fixing', 'case', 'whitespace',
                     'Unicode normalization', 'punctuation', 'empty', 'very long',
                     'the same item from another source', 'lookalike items',
                     'Fix every row that fails in the same commit'):
            self.assertIn(text, codex.prompt)

    def test_audit_failed_fast_never_pushes_or_rearms(self):
        outcome, run, data, _ = self.run_finish(audit_only=True, fast_rc=1)
        self.assertEqual(outcome, 'fast-failed')
        self.assertFalse(run.has('git', 'push'))
        self.assertNotIn('automerge', data['labels'])

    def test_disputed_audit_without_changes_posts_explanation(self):
        outcome, run, data, _ = self.run_finish(audit_only=True, empty=True)
        self.assertEqual(outcome, 'empty')
        self.assertIn('Finding is wrong: the anchor is already preserved.', '\n'.join(run.comments()))
        self.assertFalse(run.has('git', 'push'))
        self.assertNotIn('automerge', data['labels'])

    def test_extra_blank_line_at_eof_is_trimmed_and_finished(self):
        outcome, run, _, _ = self.run_finish(checked_text='let anchor = 1\n\n')
        self.assertEqual(outcome, 'finished')
        self.assertEqual(run.staged_text, 'let anchor = 1\n')

    def test_other_whitespace_warnings_do_not_discard_a_finished_fix(self):
        outcome, run, _, _ = self.run_finish(checked_text='let anchor = 1  \n')
        self.assertEqual(outcome, 'finished')
        self.assertEqual(run.staged_text, 'let anchor = 1  \n')

    def test_conflict_markers_still_stop_before_fast_plan_or_push(self):
        outcome, run, _, _ = self.run_finish(
            checked_text='<<<<<<< HEAD\nlet anchor = 1\n=======\nlet anchor = 2\n>>>>>>> next\n')
        self.assertEqual(outcome, 'error')
        self.assertFalse(any('verify-tests.py' in ' '.join(c) for c in run.calls))
        self.assertFalse(run.has('git', 'push'))
        self.assertIn('leftover conflict marker', run.comments()[-1])

    def test_real_staging_failure_stops_before_validation_or_push(self):
        outcome, run, data, _ = self.run_finish(checked_text='let anchor = 1\n', stage_failure=True)
        # Staging failed, so nothing was saved: the worktree with Codex's edit is kept, not removed (#710).
        self.assertEqual(outcome, 'kept')
        self.assertFalse(any('verify-tests.py' in ' '.join(c) for c in run.calls))
        self.assertFalse(run.has('git', 'push'))
        self.assertNotIn('automerge', data['labels'])
        self.assertIn('index.lock', run.comments()[-1])
        kept = next((self.home / 'kept').iterdir())
        self.assertTrue(kept.name.startswith('pr-73-'))
        self.assertEqual((kept / 'Playback.swift').read_text(), 'let anchor = 1\n')
        self.assertIn(f'its worktree is at `{kept}`', run.comments()[-1])

    def test_rearmed_or_moved_pr_never_pushes(self):
        for options in ({'rearmed': True}, {'moved': True}):
            outcome, run, data, _ = self.run_finish(**options)
            self.assertNotEqual(outcome, 'finished')
            self.assertFalse(run.has('git', 'push'))
            self.assertEqual(set(data['labels']), {'needs-mac'})

    def test_merge_conflict_reaches_codex_without_rewriting_history(self):
        outcome, run, _, codex = self.run_finish(conflict=True)
        self.assertEqual(outcome, 'finished')
        self.assertIn('CONFLICT (content)', codex.prompt)
        self.assertTrue(run.has('git', 'merge', '--no-commit', '--no-ff', 'origin/next'))
        self.assertFalse(run.has('git', 'rebase'))

    def test_rejected_push_stops_without_force_retry(self):
        outcome, run, data, _ = self.run_finish(push_rc=1)
        self.assertEqual(outcome, 'error')
        self.assertEqual(len([c for c in run.calls if c[:2] == ['git', 'push']]), 1)
        self.assertEqual(set(data['labels']), {'needs-mac'})
        self.assertIn('non-fast-forward', run.comments()[-1])

    def test_partial_arming_failure_restores_labels_except_automerge(self):
        outcome, _, data, _ = self.run_finish(arm_failure=True)
        self.assertEqual(outcome, 'error')
        self.assertEqual(set(data['labels']), {'needs-mac'})

    def test_no_t3_request_does_not_queue_one(self):
        outcome, run, data, _ = self.run_finish(no_request=True)
        self.assertEqual(outcome, 'finished')
        self.assertEqual(set(data['labels']), {'automerge'})
        self.assertFalse(any(c.startswith('/lane') for c in run.comments()))

    def test_needs_mac_only_uses_merge_subject(self):
        outcome, run, _, _ = self.run_finish(needs_mac_only=True)
        self.assertEqual(outcome, 'finished')
        commit = next(c for c in run.calls if c[:2] == ['git', 'commit'])
        self.assertTrue(Path(commit[-1]).read_text().startswith('Merge next and resolve conflicts'))

    def test_empty_result_does_not_rearm_the_same_failure(self):
        outcome, run, data, _ = self.run_finish(empty=True)
        self.assertEqual(outcome, 'empty')
        self.assertFalse(run.has('git', 'commit'))
        self.assertFalse(run.has('git', 'push'))
        self.assertEqual(set(data['labels']), {'needs-mac'})

    def test_child_rechecks_eligibility_before_claiming(self):
        run = FakeRun(self)
        ops = w.Ops(home=self.home, repo_root=self.home, run=run, codex=fake_codex(),
                    now=lambda: NOW, alive=lambda pid: False, echo=False)
        pr = pull(labels=['needs-mac'])
        pr['isDraft'] = True
        ops.pull = lambda n: pr
        self.assertEqual(w.run_finish_child(ops, 1, 73), 'skipped')
        self.assertEqual(run.gh_writes(), [])
        self.assertFalse(run.has('git', 'worktree', 'add'))
        self.assertFalse((self.home / 'slot-1.lock').exists())

    def test_child_round_limit_comments_without_claim_or_label_changes(self):
        run = FakeRun(self)
        ops = w.Ops(home=self.home, repo_root=self.home, run=run, codex=fake_codex(),
                    now=lambda: NOW, alive=lambda pid: False, echo=False)
        pr = pull(comments=[audit(),
                  {'body': 'Thread "Codex worker 1" finishing #73', 'createdAt': '2026-10-01T10:00:00Z'},
                  {'body': 'Thread "Codex worker 2" finishing #73', 'createdAt': '2026-10-01T11:00:00Z'}])
        ops.pull = lambda n: pr
        self.assertEqual(w.run_finish_child(ops, 1, 73), 'skipped')
        self.assertEqual(len(run.gh_writes()), 1)
        self.assertIn(w.FINISH_LIMIT_MARK, run.comments()[0])
        self.assertFalse(run.has('git', 'worktree', 'add'))
        self.assertFalse((self.home / 'slot-1.lock').exists())


class FakeRun:
    """Records every command; answers by the first matching rule."""

    def __init__(self, test, wt=None, status='', fast_rc=0, issue_data=None, fail=(), diff_fails=False,
                 evidence=()):
        self.test, self.wt, self.status, self.fast_rc = test, wt, status, fast_rc
        self.evidence = evidence  # files the fake fast plan writes before it ends (#707)
        self.issue_data = issue_data or issue(42, title='Fix the thing')
        self.fail = fail
        self.diff_fails = diff_fails
        self.calls = []

    def __call__(self, cmd, cwd=None, timeout=None):
        cmd = [str(c) for c in cmd]
        self.calls.append(cmd)
        joined = ' '.join(cmd)
        for bad in self.fail:
            if cmd[0] == bad:
                return w.Result(1, '', f'{bad} failed')
        if cmd[:3] == ['gh', 'issue', 'view']:
            return w.Result(0, json.dumps(self.issue_data))
        if cmd[:3] == ['gh', 'pr', 'create']:
            return w.Result(0, 'https://github.com/uncomposed/spoken-margins-native/pull/777\n')
        if cmd[:2] == ['git', 'rev-parse']:
            return w.Result(1)
        if cmd[:2] == ['git', 'ls-remote']:
            return w.Result(2)
        if cmd[:3] == ['git', 'worktree', 'add']:
            Path(cmd[-2]).mkdir(parents=True, exist_ok=True)
            return w.Result(0)
        if cmd[:3] == ['git', 'worktree', 'remove']:
            shutil.rmtree(cmd[-1], ignore_errors=True)
            return w.Result(0)
        if cmd[:3] == ['git', 'worktree', 'move']:
            shutil.move(cmd[-2], cmd[-1])
            return w.Result(0)
        if cmd[:2] == ['git', 'status']:
            return w.Result(0, self.status)
        if cmd[:2] == ['git', 'diff']:
            if self.diff_fails and '--cached' in cmd:
                return w.Result(128, '', 'fatal: could not write the patch')
            output = next((c[len('--output='):] for c in cmd if c.startswith('--output=')), None)
            if output:  # save_diff: git writes the patch file itself
                Path(output).write_text('diff --git a/x b/x\n')
                return w.Result(0)
            return w.Result(0, 'diff --git a/x b/x\n')
        if 'verify-tests.py' in joined:
            # Like verify-tests: evidence goes to --output, else to a folder inside the worktree.
            out = (Path(cmd[cmd.index('--output') + 1]) if '--output' in cmd else
                   Path(cwd) / 'artifacts/test-runs/20261002-105028-876259-fast')
            if self.evidence:
                out.mkdir(parents=True)
                for name in self.evidence:
                    (out / name).write_text(f'partial {name}\n')
            return w.Result(self.fast_rc, f'fast plan output\nEvidence: {out / "manifest.json"}\n')
        return w.Result(0)

    def gh_writes(self):
        return [c for c in self.calls if c[:3] in (['gh', 'issue', 'comment'], ['gh', 'issue', 'edit'],
                                                   ['gh', 'pr', 'create'])]

    def comments(self):
        return [c[c.index('--body') + 1] for c in self.calls if c[:3] == ['gh', 'issue', 'comment']]

    def has(self, *prefix):
        return any(c[:len(prefix)] == list(prefix) for c in self.calls)


def fake_codex(files=None, ok=True, why='ok'):
    def codex(wt, answer, prompt, transcript):
        codex.prompt = prompt
        transcript.write_text('{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10}}\n')
        out = Path(wt) / w.OUT_DIR_NAME
        for name, text in (files or {}).items():
            (out / name).write_text(text)
        return ok, why
    codex.prompt = None
    return codex


class ChildTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='cw-'))
        w.write_lock(self.home, 1, {'pid': os.getpid(), 'issue': 42})
        self.addCleanup(setattr, w, 'FOCUS_MILESTONE', w.FOCUS_MILESTONE)
        w.FOCUS_MILESTONE = ''  # no freeze; FreezeChildTests turns it on from the Dial

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def child(self, run, codex):
        ops = w.Ops(home=self.home, repo_root=self.home, run=run, codex=codex, now=lambda: NOW,
                    alive=lambda pid: False, echo=False)
        return w.run_child(ops, 1, 42)

    def test_issue_run_records_usage_and_failure_after_model_once(self):
        run = FakeRun(self, status=' M x.swift\n')
        self.assertEqual(self.child(run, fake_codex(ok=False, why='Codex exit -9')), 'codex-failed')
        rows = [json.loads(line) for line in (self.home / 'ledger/usage.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['input_tokens'], 100)
        self.assertEqual(rows[0]['job'], 'issue')
        self.assertEqual(rows[0]['outcome']['reason'], 'Codex exit -9')

    def test_ledger_failure_does_not_change_issue_job_behavior(self):
        self.home.mkdir(exist_ok=True)
        (self.home / 'ledger').write_text('unwritable ledger directory')
        run = FakeRun(self, status=' M x.swift\n')
        self.assertEqual(self.child(run, fake_codex(ok=False, why='Codex exit -9')), 'codex-failed')
        self.assertTrue(any('Codex exit -9' in body for body in run.comments()))

    def assert_cleaned(self, run):
        self.assertTrue(run.has('git', 'worktree', 'remove', '--force'))
        self.assertTrue(run.has('git', 'branch', '-D', 'ws/42-codex-fix-the-thing'))
        self.assertFalse((self.home / 'slot-1.lock').exists())
        self.assertFalse((self.home / 'wt-1').exists())

    def assert_claimed(self, run):
        self.assertTrue(run.has('gh', 'issue', 'edit', '42', '-R', w.REPO, '--add-label', 'in-progress'))
        self.assertEqual(run.comments()[0],
                         'Claimed by project thread "Codex worker 1" at 2026-10-01 13:00 UTC. Model gpt-6.1-sol high.')
        add = next(c for c in run.calls if c[:3] == ['git', 'worktree', 'add'])
        self.assertEqual(add[-3:], ['ws/42-codex-fix-the-thing', str(self.home / 'wt-1'), 'origin/next'])

    def test_give_up(self):
        run = FakeRun(self, status=' M x.swift\n')
        self.assertEqual(self.child(run, fake_codex({'give-up.txt': 'needs a device\nmore'})), 'give-up')
        self.assert_claimed(run)
        self.assertEqual(run.comments()[-1], 'Thread "Codex worker 1" stopping: none · Codex gave up: needs a device')
        self.assertTrue(run.has('gh', 'issue', 'edit', '42', '-R', w.REPO, '--remove-label', 'in-progress'))
        self.assertFalse(run.has('git', 'commit'))
        self.assertFalse(run.has('git', 'push'))
        self.assert_cleaned(run)

    def test_give_up_saves_new_files_in_the_diff(self):
        # #64: plain `git diff` skipped untracked files, so new files were lost on give-up.
        run = FakeRun(self, status=' M x.swift\n?? NewGate.swift\n')
        self.assertEqual(self.child(run, fake_codex({'give-up.txt': 'stuck'})), 'give-up')
        idx = lambda pred: next(i for i, c in enumerate(run.calls) if pred(c))
        add = idx(lambda c: c[:3] == ['git', 'add', '-A'])
        self.assertIn(':(exclude).codex-out', run.calls[add])
        diff = idx(lambda c: c[:2] == ['git', 'diff'] and '--cached' in c)
        self.assertLess(add, diff)
        self.assertIn('--cached', run.calls[diff])
        self.assertIn('--binary', run.calls[diff])
        saved = list((self.home / 'runs').glob('42-*/codex.diff'))
        self.assertEqual([p.read_text() for p in saved], ['diff --git a/x b/x\n'])
        self.assert_cleaned(run)

    def test_a_diff_that_cannot_be_saved_keeps_the_worktree(self):
        # #710: saving the diff raised, and cleanup then removed the worktree with Codex's finished work.
        run = FakeRun(self, status='?? Fixture.pdf\n', diff_fails=True)
        self.assertEqual(self.child(run, fake_codex({'commit-msg.txt': 'x'})), 'kept')
        kept = next((self.home / 'kept').iterdir())
        self.assertTrue(kept.name.startswith('42-'))
        self.assertFalse(run.has('git', 'worktree', 'remove'))
        self.assertFalse(run.has('git', 'branch', '-D'))
        self.assertFalse(run.has('git', 'commit'))
        self.assertFalse((self.home / 'wt-1').exists())
        self.assertIn(f'its worktree is at `{kept}`', run.comments()[-1])
        self.assertTrue(run.has('gh', 'issue', 'edit', '42', '-R', w.REPO, '--remove-label', 'in-progress'))
        self.assertFalse((self.home / 'slot-1.lock').exists())

    def test_a_worktree_that_cannot_be_moved_says_the_slot_will_clear_it(self):
        class NoMove(FakeRun):
            def __call__(self, cmd, cwd=None, timeout=None):
                if [str(c) for c in cmd[:3]] == ['git', 'worktree', 'move']:
                    self.calls.append([str(c) for c in cmd])
                    return w.Result(1, '', 'fatal: cannot move')
                return super().__call__(cmd, cwd=cwd, timeout=timeout)
        run = NoMove(self, status='?? Fixture.pdf\n', diff_fails=True)
        with unittest.mock.patch.object(w.os, 'rename', side_effect=OSError('read-only')):
            self.assertEqual(self.child(run, fake_codex({'commit-msg.txt': 'x'})), 'kept')
        self.assertIn('the next run in this slot removes it', run.comments()[-1])
        self.assertTrue((self.home / 'wt-1').exists())
        self.assertFalse(run.has('git', 'worktree', 'remove'))

    def test_empty_diff(self):
        run = FakeRun(self, status='')
        self.assertEqual(self.child(run, fake_codex({'commit-msg.txt': 'x'})), 'empty')
        self.assertEqual(run.comments()[-1], 'Thread "Codex worker 1" stopping: none · Codex made no changes')
        self.assertTrue(run.has('gh', 'issue', 'edit', '42', '-R', w.REPO, '--remove-label', 'in-progress'))
        self.assertFalse(any('verify-tests.py' in ' '.join(c) for c in run.calls))
        self.assert_cleaned(run)

    def test_codex_failure_stops(self):
        run = FakeRun(self, status=' M x.swift\n')
        self.assertEqual(self.child(run, fake_codex(ok=False, why='Codex timed out after 60 min')), 'codex-failed')
        self.assertEqual(run.comments()[-1], 'Thread "Codex worker 1" stopping: none · Codex timed out after 60 min')
        self.assertFalse(run.has('git', 'push'))
        self.assert_cleaned(run)

    def test_fast_plan_fail_pushes_branch_without_pr(self):
        run = FakeRun(self, status=' M x.swift\n', fast_rc=1)
        self.assertEqual(self.child(run, fake_codex({'commit-msg.txt': 'Fix X\n\nWhy.'})), 'fast-failed')
        self.assertTrue(run.has('git', 'commit'))
        self.assertTrue(run.has('git', 'push', '--quiet', '-u', 'origin', 'ws/42-codex-fix-the-thing'))
        self.assertFalse(run.has('gh', 'pr', 'create'))
        self.assertEqual(run.comments()[-1], 'Thread "Codex worker 1" stopping: none · fast plan failed; '
                                             'branch `ws/42-codex-fix-the-thing` pushed for a human, no PR')
        self.assertTrue(run.has('gh', 'issue', 'edit', '42', '-R', w.REPO, '--remove-label', 'in-progress'))
        self.assert_cleaned(run)

    def test_success_commits_pushes_opens_pr_and_posts_stop_note(self):
        run = FakeRun(self, status=' M Packages/SessionKit/x.swift\n')
        codex = fake_codex({'commit-msg.txt': 'Keep X when Y\n\nX was lost because Y.',
                            'pr-body.md': 'Fixes the thing.'})
        self.assertEqual(self.child(run, codex), 'pr')
        self.assert_claimed(run)
        self.assertIn('Implement GitHub issue #42: Fix the thing', codex.prompt)
        self.assertIn('Read AGENTS.md', codex.prompt)
        # The wrapper itself ran the fast plan in the worktree.
        fast = next(c for c in run.calls if 'verify-tests.py' in ' '.join(c))
        run_dir, = (self.home / 'runs').glob('42-*')
        self.assertEqual(fast, ['.venv/bin/python', 'scripts/verify-tests.py', '--plan', 'fast',
                                '--output', str(run_dir / 'fast-evidence')])
        add = next(c for c in run.calls if c[:2] == ['git', 'add'])
        self.assertIn(':(exclude).codex-out', add)
        commit = next(c for c in run.calls if c[:2] == ['git', 'commit'])
        msg = Path(commit[-1]).read_text()
        self.assertTrue(msg.startswith('Keep X when Y\n\nX was lost because Y.'))
        self.assertTrue(msg.rstrip().endswith('Co-Authored-By: Codex gpt-6.1-sol <noreply@openai.com>'))
        pr = next(c for c in run.calls if c[:3] == ['gh', 'pr', 'create'])
        self.assertEqual(pr[pr.index('--base') + 1], 'next')
        self.assertEqual(pr[pr.index('--label') + 1], 'automerge')
        self.assertEqual(pr[pr.index('--title') + 1], 'Keep X when Y')
        body = Path(pr[pr.index('--body-file') + 1]).read_text()
        self.assertIn('Issue #42.', body)
        last = body.strip().splitlines()[-1]
        self.assertIn('Written by Codex gpt-6.1-sol (reasoning effort high)', last)
        self.assertIn('--plan fast', last)
        self.assertEqual(run.comments()[-1], 'Thread "Codex worker 1" stopping: PR #777 armed · done')
        self.assertFalse(run.has('gh', 'issue', 'edit', '42', '-R', w.REPO, '--remove-label', 'in-progress'))
        # Order: commit before push before PR before the stop note.
        idx = lambda pred: next(i for i, c in enumerate(run.calls) if pred(c))
        self.assertLess(idx(lambda c: c[:2] == ['git', 'commit']), idx(lambda c: c[:2] == ['git', 'push']))
        self.assertLess(idx(lambda c: c[:2] == ['git', 'push']), idx(lambda c: c[:3] == ['gh', 'pr', 'create']))
        self.assert_cleaned(run)

    def assert_evidence_kept(self, run_glob, names):
        run_dir, = (self.home / 'runs').glob(run_glob)
        for name in names:
            self.assertEqual((run_dir / 'fast-evidence' / name).read_text(), f'partial {name}\n')
        self.assertIn(f'Evidence folder: {run_dir / "fast-evidence"}', (run_dir / 'fast-plan.txt').read_text())

    def test_fast_plan_timeout_keeps_its_evidence_after_the_worktree_goes(self):
        # #707: the evidence was written inside the temporary worktree, and removing it deleted
        # the manifest and the timed-out child's log; only the console summary was left.
        run = FakeRun(self, status=' M x.swift\n', fast_rc=124, evidence=('manifest.json', 'runner-tests.log'))
        self.assertEqual(self.child(run, fake_codex({'commit-msg.txt': 'Fix X\n\nWhy.'})), 'fast-failed')
        self.assert_cleaned(run)
        self.assert_evidence_kept('42-*', ('manifest.json', 'runner-tests.log'))
        add = next(c for c in run.calls if c[:2] == ['git', 'add'])
        self.assertFalse(any('fast-evidence' in a for a in add))

    def test_a_plan_cut_off_before_its_manifest_keeps_the_partial_log(self):
        run = FakeRun(self, status=' M x.swift\n', fast_rc=124, evidence=('runner-tests.log',))
        self.assertEqual(self.child(run, fake_codex({'commit-msg.txt': 'Fix X\n\nWhy.'})), 'fast-failed')
        self.assert_cleaned(run)
        self.assert_evidence_kept('42-*', ('runner-tests.log',))

    def test_a_passing_plan_keeps_its_evidence_too(self):
        run = FakeRun(self, status=' M x.swift\n', evidence=('manifest.json', 'runner-tests.log'))
        codex = fake_codex({'commit-msg.txt': 'Keep X\n\nWhy.', 'pr-body.md': 'Fixes it.'})
        self.assertEqual(self.child(run, codex), 'pr')
        self.assert_cleaned(run)
        self.assert_evidence_kept('42-*', ('manifest.json', 'runner-tests.log'))

    def test_recheck_before_claim(self):
        run = FakeRun(self, issue_data=issue(42, labels=('ready', 'in-progress')))
        self.assertEqual(self.child(run, fake_codex()), 'skipped')
        self.assertEqual(run.gh_writes(), [])
        self.assertFalse(run.has('git', 'worktree', 'add'))
        self.assertFalse((self.home / 'slot-1.lock').exists())

    def test_wrapper_error_after_claim_posts_stop_note(self):
        run = FakeRun(self, fail=('scripts/setup-worktree.sh',))
        self.assertEqual(self.child(run, fake_codex()), 'error')
        self.assertTrue(run.comments()[-1].startswith('Thread "Codex worker 1" stopping: none · wrapper error'))
        self.assertTrue(run.has('gh', 'issue', 'edit', '42', '-R', w.REPO, '--remove-label', 'in-progress'))
        self.assert_cleaned(run)

    def test_taken_branch_name_gets_a_suffix(self):
        class Taken(FakeRun):
            def __call__(self, cmd, cwd=None, timeout=None):
                if cmd[:2] == ['git', 'ls-remote'] and cmd[-1] == 'ws/42-codex-fix-the-thing':
                    self.calls.append([str(c) for c in cmd])
                    return w.Result(0, 'abc\trefs/heads/ws/42-codex-fix-the-thing')
                return super().__call__(cmd, cwd, timeout)
        run = Taken(self, status='')
        self.child(run, fake_codex())
        add = next(c for c in run.calls if c[:3] == ['git', 'worktree', 'add'])
        self.assertEqual(add[-3], 'ws/42-codex-fix-the-thing-2')


class SaveDiffTests(unittest.TestCase):
    """The one test that runs real git, in a throwaway repo: the bug was git's own behaviour."""

    def test_saved_diff_has_new_files_and_skips_codex_out(self):
        if not shutil.which('git'):
            self.skipTest('git not installed')
        tmp = Path(tempfile.mkdtemp(prefix='cw-git-'))
        self.addCleanup(shutil.rmtree, tmp, True)
        wt = tmp / 'wt'
        wt.mkdir()
        git = lambda *a: w.default_run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *a], cwd=wt)
        git('init', '--quiet')
        (wt / 'old.swift').write_text('let a = 1\n')
        (wt / 'untouched.txt').write_bytes(b'untouched\n\n')
        (wt / 'deleted.txt').write_text('delete me\n')
        git('add', '-A')
        git('commit', '--quiet', '-m', 'base')
        (wt / 'old.swift').write_bytes(b'let a = 2\r\n \t\r\n\r\n')
        git('add', 'old.swift')  # Already staged changes must also be normalized.
        (wt / 'deleted.txt').unlink()
        (wt / 'Sources').mkdir()
        (wt / 'Sources' / 'PreparationChunkGate.swift').write_text('struct Gate {}\n\n')
        preserved = {'binary.dat': b'\0binary\n\n', 'no-final-newline.txt': b'keep this  '}
        for name, data in preserved.items():
            (wt / name).write_bytes(data)
        target = tmp / 'target.txt'
        target.write_text('symlink target\n\n')
        (wt / 'link.txt').symlink_to(target)
        (wt / w.OUT_DIR_NAME).mkdir()
        (wt / w.OUT_DIR_NAME / 'give-up.txt').write_text('stuck\n\n')
        ops = w.Ops(home=tmp, repo_root=tmp, now=lambda: NOW, alive=lambda pid: False, echo=False)
        w.save_diff(ops, wt, tmp / 'codex.diff')
        self.assertEqual((wt / 'old.swift').read_bytes(), b'let a = 2\r\n')
        self.assertEqual((wt / 'Sources' / 'PreparationChunkGate.swift').read_bytes(), b'struct Gate {}\n')
        self.assertEqual((wt / 'untouched.txt').read_bytes(), b'untouched\n\n')
        for name, data in preserved.items():
            self.assertEqual((wt / name).read_bytes(), data)
        self.assertTrue((wt / 'link.txt').is_symlink())
        self.assertEqual(target.read_bytes(), b'symlink target\n\n')
        self.assertEqual((wt / w.OUT_DIR_NAME / 'give-up.txt').read_bytes(), b'stuck\n\n')
        w.check_staged_changes(ops, wt)
        diff = (tmp / 'codex.diff').read_text()
        self.assertIn('+let a = 2', diff)
        self.assertIn('b/Sources/PreparationChunkGate.swift', diff)
        self.assertIn('+struct Gate {}', diff)
        self.assertNotIn('give-up.txt', diff)


    def test_saved_diff_keeps_bytes_that_are_not_utf8(self):
        # #710: a new PDF fixture with byte 0x93 and no NUL is a text diff to Git; decoding it as UTF-8 raised
        # and the finished run was lost. The saved patch must hold the original bytes and rebuild the file.
        if not shutil.which('git'):
            self.skipTest('git not installed')
        tmp = Path(tempfile.mkdtemp(prefix='cw-git-'))
        self.addCleanup(shutil.rmtree, tmp, True)
        wt = tmp / 'wt'
        wt.mkdir()
        git = lambda *a, cwd=wt: w.default_run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *a], cwd=cwd)
        git('init', '--quiet')
        (wt / 'README').write_text('base\n')
        git('add', '-A')
        git('commit', '--quiet', '-m', 'base')
        fixture = b'%PDF-1.4\n(\x93A short walk\x94) Tj\n%%EOF\n'
        (wt / 'Fixture.pdf').write_bytes(fixture)
        ops = w.Ops(home=tmp, repo_root=tmp, now=lambda: NOW, alive=lambda pid: False, echo=False)
        w.save_diff(ops, wt, tmp / 'codex.diff')
        patch = (tmp / 'codex.diff').read_bytes()
        self.assertIn(b'\x93A short walk\x94', patch)
        self.assertNotIn('\ufffd'.encode(), patch)
        fresh = tmp / 'fresh'
        self.assertEqual(git('clone', '--quiet', str(wt), str(fresh), cwd=tmp).returncode, 0)
        self.assertEqual(git('apply', str(tmp / 'codex.diff'), cwd=fresh).returncode, 0)
        self.assertEqual((fresh / 'Fixture.pdf').read_bytes(), fixture)

    def test_command_output_that_is_not_utf8_does_not_raise(self):
        res = w.default_run([sys.executable, '-c', 'import sys; sys.stdout.buffer.write(b"a\\x93b")'])
        self.assertEqual((res.returncode, res.stdout), (0, 'a\ufffdb'))


class StageChangesTests(unittest.TestCase):
    def test_non_utf8_is_preserved_and_nul_delimited_paths_are_trimmed(self):
        with tempfile.TemporaryDirectory(prefix='cw-stage-') as directory:
            wt = Path(directory)
            (wt / 'non-utf8.txt').write_bytes(b'\xff\n\n')
            (wt / 'file with\na newline.txt').write_bytes(b'text\n\n')

            def run(cmd, cwd=None, timeout=None):
                if '--name-only' in cmd:
                    return w.Result(0, 'non-utf8.txt\0')
                if cmd[:2] == ['git', 'ls-files']:
                    return w.Result(0, 'file with\na newline.txt\0')
                self.assertEqual(cmd, ['git', 'add', '-A', '--', '.', ':(exclude).codex-out'])
                return w.Result(0)

            w.stage_changes(w.Ops(home=wt, repo_root=wt, run=run, echo=False), wt)
            self.assertEqual((wt / 'non-utf8.txt').read_bytes(), b'\xff\n\n')
            self.assertEqual((wt / 'file with\na newline.txt').read_bytes(), b'text\n')

    def test_git_errors_remain_fatal(self):
        ops = w.Ops(run=lambda *args, **kwargs: w.Result(128, '', 'fatal: bad index'))
        with self.assertRaisesRegex(RuntimeError, 'fatal: bad index'):
            w.check_staged_changes(ops, Path('/unused'))


# ---------------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------------

class SandboxTests(unittest.TestCase):
    def test_every_worker_model_call_requests_usage_events(self):
        command = w.codex_command(Path('/tmp/worktree'), Path('/tmp/answer'), 'prompt')
        self.assertIn('--json', command)

    """#64 (2026-10-01): Codex gave up after 33 min because its sandbox couldn't run the fast plan."""

    def test_codex_may_write_the_lane_slots_and_the_clang_module_cache(self):
        cmd = w.codex_command(Path('/wt'), Path('/answer.md'), 'the prompt')
        self.assertEqual(cmd[cmd.index('-s') + 1], 'workspace-write')
        roots = next(c for c in cmd if c.startswith('sandbox_workspace_write.writable_roots='))
        roots = json.loads(roots.split('=', 1)[1])
        lane = os.environ.get('SM_LANE_STATE_DIR') or str(Path.home() / 'Library/Caches/SpokenMarginsLane')
        self.assertIn(str(Path(lane)), roots)
        self.assertIn(str(Path.home() / '.cache/clang'), roots)
        self.assertEqual(cmd[-1], 'the prompt')

    def test_the_wrapper_s_own_fast_plan_never_runs_in_sandbox_mode(self):
        # verify-tests skips runner-tests when CODEX_SANDBOX is set; the wrapper's run is the gate.
        from unittest import mock
        with mock.patch.dict(os.environ, {'CODEX_SANDBOX': 'seatbelt'}):
            res = w.default_run([sys.executable, '-c', 'import os; print(os.environ.get("CODEX_SANDBOX"))'])
        self.assertEqual(res.stdout.strip(), 'None')

    def test_prompt_names_the_sandbox_limits_and_the_wrapper_s_gate(self):
        prompt = w.build_prompt(64, 'Prepared audio', 'body')
        for text in ('cannot run `ps`', 'swift test --disable-sandbox', 'verified_in_codex_sandbox',
                     'outside your sandbox', 'not a reason to give up'):
            self.assertIn(text, prompt)
        self.assertNotIn('and make it pass', prompt)

    def test_sessionkit_dependencies_are_resolved_before_codex_starts(self):
        # The sandbox has no network, so SwiftPM there couldn't clone onnxruntime.
        run = FakeRun(self, status=' M x.swift\n')
        seen = {}

        def codex(wt, answer, prompt, transcript):
            seen['calls'] = list(run.calls)
            return True, 'ok'
        home = Path(tempfile.mkdtemp(prefix='cw-'))
        self.addCleanup(shutil.rmtree, home, True)
        w.write_lock(home, 1, {'pid': os.getpid(), 'issue': 42})
        ops = w.Ops(home=home, repo_root=home, run=run, codex=codex, now=lambda: NOW,
                    alive=lambda pid: False, echo=False)
        w.run_child(ops, 1, 42)
        self.assertIn(['swift', 'package', '--package-path', 'Packages/SessionKit', 'resolve'], seen['calls'])


class TickTests(unittest.TestCase):
    focus = ''  # the tick's own rules, without a milestone focus; FocusTickTests turns it on

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='cw-'))
        self._focus, w.FOCUS_MILESTONE = w.FOCUS_MILESTONE, self.focus

    def tearDown(self):
        w.FOCUS_MILESTONE = self._focus
        shutil.rmtree(self.home, ignore_errors=True)

    def ops(self, workers=2, used=10, free=100 * 2**30, alive=lambda pid: True, issues=None,
            body=None, resets_at=None, prs=None, milestone=None):
        body = body if body is not None else dial(codex_group(workers) if workers is not None else '')
        listing = issues if issues is not None else [issue(42, title='Fix the thing')]

        def run(cmd, cwd=None, timeout=None):
            cmd = [str(c) for c in cmd]
            if cmd[:3] == ['gh', 'pr', 'list']:
                return w.Result(0, json.dumps(prs or []))
            if cmd[:3] == ['gh', 'pr', 'view']:
                return w.Result(0, json.dumps(next(p for p in prs if p['number'] == int(cmd[3]))))
            if cmd[:3] == ['gh', 'issue', 'view'] and cmd[3] == str(w.DIAL_ISSUE):
                return w.Result(0, json.dumps({'body': body}))
            if cmd[:3] == ['gh', 'issue', 'list'] and '--milestone' in cmd:
                self.assertEqual(cmd[cmd.index('--milestone') + 1], w.FOCUS_MILESTONE)
                if milestone is None:
                    return w.Result(1, '', 'milestone not found')
                return w.Result(0, json.dumps([{'number': n} for n in milestone]))
            if cmd[:3] == ['gh', 'issue', 'list']:
                return w.Result(0, json.dumps(listing))
            if cmd[:3] == ['gh', 'issue', 'view']:
                n = int(cmd[3])
                return w.Result(0, json.dumps(next(i for i in listing if i['number'] == n)))
            raise AssertionError(f'unexpected command {cmd}')
        return w.Ops(home=self.home, repo_root=self.home, run=run, codex=None,
                     limits=lambda: limits_result(used, resets_at=resets_at) if used is not None else None,
                     now=lambda: NOW, alive=alive, free_bytes=lambda: free, echo=False)

    def spawner(self):
        started = []

        def spawn(ops, slot, number):
            started.append((slot, number))
            return 4242
        spawn.started = started
        return spawn

    def test_starts_one_child_and_writes_its_lock(self):
        spawn = self.spawner()
        d = w.tick(self.ops(), spawn=spawn)
        self.assertEqual(spawn.started, [(1, 42)])
        self.assertEqual(d['start'], (1, 42))
        self.assertEqual(json.loads((self.home / 'slot-1.lock').read_text())['pid'], 4242)

    def test_zero_workers_starts_nothing(self):
        spawn = self.spawner()
        d = w.tick(self.ops(workers=0), spawn=spawn)
        self.assertEqual(spawn.started, [])
        self.assertIn('0 Codex workers', d['why'])

    def test_finishing_pr_precedes_ready_issue_and_uses_shared_slot(self):
        spawn = self.spawner()
        d = w.tick(self.ops(prs=[pull(labels=['needs-mac'])]), spawn=spawn)
        self.assertEqual(spawn.started, [(1, 73)])
        self.assertEqual(d['pr'], 73)
        self.assertIsNone(d['issue'])
        info = json.loads((self.home / 'slot-1.lock').read_text())
        self.assertEqual(info['pr'], 73)
        self.assertNotIn('issue', info)
        # The same PR cannot be taken twice; the other slot may still work an issue.
        d = w.tick(self.ops(prs=[pull(labels=['needs-mac'])]), spawn=spawn)
        self.assertEqual(d['start'], (2, 42))

    def test_ineligible_pr_falls_back_to_issue(self):
        spawn = self.spawner()
        d = w.tick(self.ops(prs=[pull(comments=[lane('INCONCLUSIVE')])]), spawn=spawn)
        self.assertEqual(d['start'], (1, 42))

    def test_audit_lane_pr_precedes_ready_issue(self):
        pr = pull(comments=[lane('PASS'), audit()])
        pr['files'] = [{'path': 'ops/codex/sm_codex_testdesk.py'}]
        spawn = self.spawner()
        self.assertEqual(w.tick(self.ops(prs=[pr]), spawn=spawn)['pr'], 73)
        self.assertEqual(spawn.started, [(1, 73)])

    def test_round_limit_note_once_and_falls_back_to_issue(self):
        pr = pull(comments=[audit(),
                  {'body': 'Thread "Codex worker 1" finishing #73', 'createdAt': '2026-10-01T10:00:00Z'},
                  {'body': 'Thread "Codex worker 2" finishing #73', 'createdAt': '2026-10-01T11:00:00Z'}])
        ops = self.ops(prs=[pr])
        notes = []

        def comment(n, body):
            notes.append((n, body))
            pr['comments'].append({'body': body, 'createdAt': NOW.strftime('%Y-%m-%dT%H:%M:%SZ')})

        ops.comment = comment
        for _ in range(2):
            spawn = self.spawner()
            self.assertEqual(w.tick(ops, spawn=spawn)['issue'], 42)
            self.assertEqual(spawn.started, [(1, 42)])
            (self.home / 'slot-1.lock').unlink()
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0][0], 73)
        self.assertTrue(notes[0][1].startswith(w.FINISH_LIMIT_MARK))

    def test_round_limit_dry_run_posts_nothing(self):
        import contextlib
        import io
        pr = pull(comments=[audit(),
                  {'body': 'Thread "Codex worker 1" finishing #73', 'createdAt': '2026-10-01T10:00:00Z'},
                  {'body': 'Thread "Codex worker 2" finishing #73', 'createdAt': '2026-10-01T11:00:00Z'}])
        ops = self.ops(prs=[pr])
        ops.comment = lambda *args: self.fail('dry run wrote a comment')
        with contextlib.redirect_stdout(io.StringIO()):
            d = w.tick(ops, dry_run=True, spawn=self.spawner())
        self.assertIsNone(d['pr'])
        self.assertEqual(d['start'], (1, 42))

    def test_pr_jobs_obey_dial_and_pacing(self):
        for options in ({'workers': 0}, {'used': 95}):
            spawn = self.spawner()
            d = w.tick(self.ops(prs=[pull(labels=['needs-mac'])], **options), spawn=spawn)
            self.assertEqual(spawn.started, [])
            self.assertIsNone(d['start'])

    def test_spawn_and_cli_route_pr_to_finisher(self):
        from unittest import mock
        with mock.patch.object(w.subprocess, 'Popen') as popen:
            w.spawn_finish_child(self.ops(), 2, 73)
            command = popen.call_args.args[0]
            self.assertEqual(command[-4:], ['--slot', '2', '--pr', '73'])
        with mock.patch.object(w, 'Ops'), mock.patch.object(w, 'run_finish_child') as finish:
            self.assertEqual(w.main(['--slot', '2', '--pr', '73']), 0)
            self.assertEqual(finish.call_args.args[1:], (2, 73))

    def test_holds_start_nothing(self):
        for kw, word in (({'used': 95}, 'hold line'), ({'used': None}, 'could not be read'),
                         ({'free': 1}, 'GiB free')):
            spawn = self.spawner()
            d = w.tick(self.ops(**kw), spawn=spawn)
            self.assertEqual(spawn.started, [], kw)
            self.assertIn(word, d['why'])

    def test_tick_and_dry_run_use_and_report_codex_targets(self):
        import contextlib
        import io
        body = dial(codex_group(1) + '\n' + codex_pacing((90,), ('Fri noon',)))
        for dry_run in (True, False):
            with self.subTest(dry_run=dry_run):
                spawn = self.spawner()
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    d = w.tick(self.ops(used=60, body=body, resets_at=CODEX_RESET),
                               dry_run=dry_run, spawn=spawn)
                self.assertEqual(d['start'], (1, 42))
                self.assertEqual(spawn.started, [] if dry_run else [(1, 42)])
                out = buf.getvalue() if dry_run else (self.home / 'log.txt').read_text()
                for text in ('Codex stop line 90%', 'finish by Fri noon (2026-10-02 16:00 UTC)'):
                    self.assertIn(text, out)

    def test_tick_fallback_output_reports_shared_stop_and_codex_reset(self):
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            w.tick(self.ops(resets_at=CODEX_RESET), dry_run=True, spawn=self.spawner())
        self.assertIn('Dial Stop line 90%', buf.getvalue())
        self.assertIn('finish by Codex reset (2026-10-06 14:10 UTC)', buf.getvalue())

    def test_dry_run_reports_the_lower_stop_and_later_finish(self):
        import contextlib
        import io
        body = dial(codex_group(1) + '\n' + codex_pacing((80, 97), ('Fri noon', 'Sat 7 AM')))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            w.tick(self.ops(body=body, resets_at=CODEX_RESET), dry_run=True, spawn=self.spawner())
        self.assertIn('Codex stop line 80%', buf.getvalue())
        self.assertIn('finish by Sat 7 AM (2026-10-03 11:00 UTC)', buf.getvalue())

    def test_tick_uses_codex_hold_line(self):
        body = dial(codex_group(1) + '\n' + codex_pacing((70,), ('Fri noon',)))
        spawn = self.spawner()
        d = w.tick(self.ops(used=67, body=body), spawn=spawn)
        self.assertEqual(spawn.started, [])
        self.assertIn('hold line 67%', d['why'])

    def test_unreadable_dial_starts_nothing(self):
        ops = self.ops()

        def unreadable():
            raise OSError('unavailable')
        ops.dial_body = unreadable
        spawn = self.spawner()
        d = w.tick(ops, spawn=spawn)
        self.assertEqual((d['dial']['workers'], spawn.started), (0, []))
        self.assertIn('Dial read failed', d['dial']['problems'][0])

    def test_busy_slots_and_dead_lock_cleared(self):
        w.write_lock(self.home, 1, {'pid': 1, 'issue': 5})
        w.write_lock(self.home, 2, {'pid': 2, 'issue': 6})
        spawn = self.spawner()
        d = w.tick(self.ops(workers=2, alive=lambda pid: True), spawn=spawn)
        self.assertEqual((spawn.started, d['why']), ([], 'all 2 slots busy'))
        # Slot 2's pid dies: its lock goes and slot 2 is reused.
        d = w.tick(self.ops(workers=2, alive=lambda pid: pid != 2), spawn=spawn)
        self.assertEqual(spawn.started, [(2, 42)])

    def test_live_slot_issue_is_not_taken_twice(self):
        w.write_lock(self.home, 1, {'pid': 1, 'issue': 42})
        spawn = self.spawner()
        d = w.tick(self.ops(workers=2), spawn=spawn)
        self.assertEqual(spawn.started, [])
        self.assertEqual(d['why'], 'no eligible ready issue')

    def test_dry_run_changes_nothing(self):
        w.write_lock(self.home, 1, {'pid': 1, 'issue': 5})
        before = sorted(p.name for p in self.home.iterdir())
        spawn = self.spawner()
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            d = w.tick(self.ops(workers=2, alive=lambda pid: False), dry_run=True, spawn=spawn)
        self.assertEqual(spawn.started, [])
        self.assertEqual(d['start'], (1, 42))
        self.assertEqual(sorted(p.name for p in self.home.iterdir()), before)
        out = buf.getvalue()
        for word in ('Dial:', 'Codex usage:', 'Slots:', 'Chosen issue: #42'):
            self.assertIn(word, out)



class FocusTickTests(unittest.TestCase):
    """Build 30 freeze: only milestone issues, and only PRs linked to one."""
    focus = 'Build 30'
    setUp, tearDown, ops, spawner = TickTests.setUp, TickTests.tearDown, TickTests.ops, TickTests.spawner

    def test_takes_only_milestone_issues(self):
        issues = [issue(42, created='2026-09-01T00:00:00Z'), issue(43, created='2026-09-02T00:00:00Z')]
        spawn = self.spawner()
        d = w.tick(self.ops(issues=issues, milestone=[43, 99]), spawn=spawn)
        self.assertEqual(spawn.started, [(1, 43)])
        self.assertEqual(d['issue'], 43)

    def test_skips_frozen_pr_and_finishes_milestone_pr(self):
        frozen = pull(labels=['needs-mac'])  # ws/73-playback, not in the milestone
        focused = dict(frozen, number=74, headRefName='ws/866-build30-fix', createdAt='2026-10-05T00:00:00Z')
        spawn = self.spawner()
        d = w.tick(self.ops(prs=[frozen, focused], milestone=[866]), spawn=spawn)
        self.assertEqual(d['pr'], 74)
        self.assertEqual(spawn.started, [(1, 74)])

    def test_nothing_in_focus_idles(self):
        spawn = self.spawner()
        d = w.tick(self.ops(prs=[pull(labels=['needs-mac'])], milestone=[866]), spawn=spawn)
        self.assertEqual(spawn.started, [])
        self.assertIn('Build 30', d['why'])

    def test_unreadable_milestone_holds(self):
        spawn = self.spawner()
        d = w.tick(self.ops(milestone=None), spawn=spawn)
        self.assertEqual(spawn.started, [])
        self.assertIn('listing jobs failed', d['why'])



# ---------------------------------------------------------------------------
# Freeze from the Dial (#902)
# ---------------------------------------------------------------------------

def focus_group(*ticked: str, options=('Build 30', 'None (any ready issue)')) -> str:
    lines = ['**Codex focus** (during a freeze, Codex works only on this milestone and non-app work)']
    lines += [f"- [{'x' if o.split(' (')[0] in ticked else ' '}] {o}" for o in options]
    return '\n'.join(lines)


OPS_ONLY = '**Likely files.** `ops/codex/sm_codex_worker.py` (`label_skip`, `choose_issue`) and its tests.\n\n**Size.** S'
APP_WORK = '**Likely files.** `App/SpokenMarginsApp/Gate1AppModel.swift`, `scripts/x.py`\n\n**Size.** S'


class FreezeDialTests(unittest.TestCase):
    def setUp(self):
        self._focus, w.FOCUS_MILESTONE = w.FOCUS_MILESTONE, 'Build 30'
        self.addCleanup(setattr, w, 'FOCUS_MILESTONE', self._focus)

    def test_ticked_milestone(self):
        self.assertEqual(w.parse_codex_focus(focus_group('Build 30')), ('Build 30', []))
        group = focus_group('Build 31', options=('Build 31 (only its issues)', 'None'))
        self.assertEqual(w.parse_codex_focus(group), ('Build 31', []))

    def test_none_lifts_the_freeze(self):
        self.assertEqual(w.parse_codex_focus(focus_group('None')), ('', []))
        d = w.read_dial(dial(codex_group(1) + '\n\n' + focus_group('None')), lambda b: {'mode': 'paced', 'stop': 90})
        self.assertEqual(d['focus'], '')

    def test_no_group_uses_the_default(self):
        self.assertEqual(w.parse_codex_focus(dial(codex_group(1))), (None, []))
        d = w.read_dial(dial(codex_group(1)), lambda b: {'mode': 'paced', 'stop': 90})
        self.assertEqual(d['focus'], 'Build 30')
        w.FOCUS_MILESTONE = ''
        self.assertEqual(w.read_dial(dial(codex_group(1)), lambda b: {'mode': 'paced', 'stop': 90})['focus'], '')

    def test_muddled_group_stays_frozen(self):
        focus, problems = w.parse_codex_focus(focus_group())
        self.assertIsNone(focus)
        self.assertIn('no Codex focus box', problems[0])
        focus, problems = w.parse_codex_focus(focus_group('Build 30', 'None'))
        self.assertEqual(focus, 'Build 30')
        self.assertIn('2 Codex focus boxes', problems[0])

    def test_unreadable_dial_keeps_the_default_focus(self):
        self.assertEqual(w.read_dial('', None)['focus'], 'Build 30')
        self.assertEqual(w.read_dial(focus_group('None'), lambda b: 1 / 0)['focus'], '')


class AppCodeRiskTests(unittest.TestCase):
    """Neighbouring Likely files forms: each row is what an issue body actually says."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='cw-root-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        (self.root / 'AGENTS.md').write_text('x')
        for folder in ('ops', 'scripts', 'docs', '.github', 'App', 'Packages', 'Contracts'):
            (self.root / folder).mkdir()

    def risk(self, body):
        return w.app_code_risk(issue(1, body=body), self.root)

    def test_table(self):
        clear = [
            OPS_ONLY,
            '## Likely files\n- `scripts/lane-runner.py`\n- `docs/workstreams/test-lane.md`\n\n## Size\nS',
            'Likely files: ops/dial/dial_gate.py, ./scripts/verify-tests.py',
            '**Likely files.** `AGENTS.md`, `.github/workflows/lane.yml`, `scripts/lane*`',
        ]
        for body in clear:
            self.assertIsNone(self.risk(body), body)
        risky = {
            APP_WORK: 'app code (App/SpokenMarginsApp/Gate1AppModel.swift)',
            '**Likely files.** `Packages/SessionKit/Sources/SessionKit/Margin.swift`': 'app code (Packages/',
            '**Likely files.** `Contracts/schemas/packet.json`': 'app code (Contracts/',
            '**Likely files.** `Gate1AppModel.swift`': '`Gate1AppModel.swift` without a folder',
            '**Likely files.** the worker and its tests': 'name no paths',
            '**Outcome.** something': 'no Likely files',
            '': 'no Likely files',
            '**Likely files.** `SessionKit/Sources/SessionKit/Margin.swift`': 'not under a top-level folder',
            '**Likely files.** `SpokenMarginsApp/Gate1AppModel.swift`': 'not under a top-level folder',
            '**Likely files.** https://github.com/uncomposed/spoken-margins-native/blob/next/App/x.swift':
                'not under a top-level folder',
            '## Likely files\n- `ops/x.py`\n\n- `App/y.swift`\n\n## Size': 'app code (App/y.swift)',
        }
        for body, why in risky.items():
            self.assertIn(why, self.risk(body) or '', body)

    def test_pr_paths(self):
        self.assertTrue(w.freeze_allows({'files': [{'path': 'ops/x.py'}]}, {1}))
        self.assertFalse(w.freeze_allows({'files': [{'path': 'ops/x.py'}, {'path': 'App/y.swift'}]}, {1}))
        self.assertFalse(w.freeze_allows({'files': [{'path': 'ops/x.py'}], 'changedFiles': 2}, {1}))
        self.assertFalse(w.freeze_allows({'files': [{'path': f'ops/{n}.py'} for n in range(100)]}, {1}))
        self.assertTrue(w.freeze_allows({'headRefName': 'ws/1-x', 'files': [{'path': 'App/y.swift'}]}, {1}))
        self.assertTrue(w.freeze_allows({'files': [{'path': 'App/y.swift'}]}, None))
        self.assertTrue(w.freeze_allows({'headRefName': 'ws/2-x'}, {1}, paths=['docs/a.md']))
        self.assertFalse(w.freeze_allows({'headRefName': 'ws/2-x'}, {1}, paths=['Contracts/a.json']))
        # "part of" a milestone issue is not enough to arm an app diff; closing words are.
        self.assertFalse(w.freeze_allows({'headRefName': 'ws/2-x', 'body': 'Part of #1.'}, {1}, paths=['App/a']))
        self.assertTrue(w.freeze_allows({'headRefName': 'ws/2-x', 'body': 'Closes #1.'}, {1}, paths=['App/a']))


class FreezeTickTests(unittest.TestCase):
    """The Dial's freeze line: milestone first, then only issues and PRs that stay out of app code."""
    focus = 'Build 30'
    setUp, tearDown, spawner = TickTests.setUp, TickTests.tearDown, TickTests.spawner

    def ops(self, group, milestone=(), expect='Build 30', **kw):
        body = dial(codex_group(2) + ('\n\n' + group if group else ''))
        ops = TickTests.ops(self, body=body, milestone=list(milestone), **kw)
        inner = ops.run
        self.milestone_asks = []

        def run(cmd, cwd=None, timeout=None):
            cmd = [str(c) for c in cmd]
            if cmd[:3] == ['gh', 'issue', 'list'] and '--milestone' in cmd:
                self.milestone_asks.append(cmd[cmd.index('--milestone') + 1])
                self.assertEqual(self.milestone_asks[-1], expect)
                return w.Result(0, json.dumps([{'number': n} for n in milestone]))
            return inner(cmd, cwd, timeout)
        ops.run = run
        return ops

    def test_milestone_issue_beats_an_older_priority_issue_outside_it(self):
        issues = [issue(41, labels=('ready', 'priority'), created='2026-09-01T00:00:00Z', body=OPS_ONLY),
                  issue(43, created='2026-09-20T00:00:00Z', body=APP_WORK)]
        spawn = self.spawner()
        d = w.tick(self.ops(focus_group('Build 30'), milestone=[43], issues=issues), spawn=spawn)
        self.assertEqual(spawn.started, [(1, 43)])
        self.assertEqual(d['issue'], 43)

    def test_app_code_issue_outside_the_milestone_is_skipped_and_logged(self):
        spawn = self.spawner()
        d = w.tick(self.ops(focus_group('Build 30'), milestone=[99], issues=[issue(44, body=APP_WORK)]), spawn=spawn)
        self.assertEqual(spawn.started, [])
        self.assertIn('Build 30 freeze', d['why'])
        log = (self.home / 'log.txt').read_text()
        self.assertIn('skipped 1 ready issues outside it that may touch app code: #44', log)

    def test_ops_only_issue_outside_the_milestone_is_taken(self):
        issues = [issue(44, created='2026-09-01T00:00:00Z', body=APP_WORK),
                  issue(45, created='2026-09-02T00:00:00Z', body=OPS_ONLY)]
        (self.home / 'ops').mkdir()  # the tick checks Likely files against the checkout's folders
        spawn = self.spawner()
        d = w.tick(self.ops(focus_group('Build 30'), milestone=[99], issues=issues), spawn=spawn)
        self.assertEqual(spawn.started, [(1, 45)])
        self.assertEqual(d['issue'], 45)

    def test_ops_only_pr_outside_the_milestone_is_finished(self):
        app = pull(labels=['needs-mac'])  # ws/73-playback, SessionKit diff
        ops_pr = dict(app, number=75, headRefName='ws/75-lane-fix', createdAt='2026-10-02T00:00:00Z',
                      files=[{'path': 'ops/codex/sm_codex_worker.py'}])
        spawn = self.spawner()
        d = w.tick(self.ops(focus_group('Build 30'), milestone=[866], prs=[app, ops_pr]), spawn=spawn)
        self.assertEqual(d['pr'], 75)

    def test_files_are_listed_only_during_a_freeze(self):
        for group, wanted in ((focus_group('Build 30'), True), (focus_group('None'), False)):
            ops = self.ops(group, milestone=[42])
            inner, asked = ops.run, []

            def run(cmd, cwd=None, timeout=None, inner=inner, asked=asked):
                asked.append([str(c) for c in cmd])
                return inner(cmd, cwd, timeout)
            ops.run = run
            w.tick(ops, spawn=self.spawner())
            listing = next(c for c in asked if c[:3] == ['gh', 'pr', 'list'])
            self.assertEqual('files' in listing[-1].split(','), wanted)

    def test_dial_names_the_next_milestone(self):
        group = focus_group('Build 31', options=('Build 31', 'None'))
        spawn = self.spawner()
        d = w.tick(self.ops(group, milestone=[42], expect='Build 31'), spawn=spawn)
        self.assertEqual(self.milestone_asks, ['Build 31'])
        self.assertEqual(d['issue'], 42)

    def test_none_on_the_dial_lifts_the_freeze(self):
        spawn = self.spawner()
        d = w.tick(self.ops(focus_group('None'), issues=[issue(44, body=APP_WORK)]), spawn=spawn)
        self.assertEqual(self.milestone_asks, [])
        self.assertEqual(d['issue'], 44)

    def test_no_focus_group_keeps_the_default(self):
        spawn = self.spawner()
        d = w.tick(self.ops('', milestone=[99], issues=[issue(44, body=APP_WORK)]), spawn=spawn)
        self.assertEqual(self.milestone_asks, ['Build 30'])
        self.assertIsNone(d['issue'])


class FreezeChildRun(FakeRun):
    """FakeRun plus the Dial, the milestone and the PR's changed files."""

    def __init__(self, test, group, milestone, paths, **kw):
        super().__init__(test, **kw)
        self.group, self.milestone, self.paths = group, milestone, paths

    def __call__(self, cmd, cwd=None, timeout=None):
        cmd = [str(c) for c in cmd]
        if cmd[:4] == ['gh', 'issue', 'view', str(w.DIAL_ISSUE)]:
            self.calls.append(cmd)
            return w.Result(0, json.dumps({'body': dial(codex_group(1) + '\n\n' + self.group)}))
        if cmd[:3] == ['gh', 'issue', 'list'] and '--milestone' in cmd:
            self.calls.append(cmd)
            if self.milestone is None:
                return w.Result(1, '', 'HTTP 502')
            return w.Result(0, json.dumps([{'number': n} for n in self.milestone]))
        if cmd[:2] == ['git', 'diff'] and '--name-only' in cmd and 'origin/next...HEAD' in cmd:
            self.calls.append(cmd)
            # Like git: without --no-renames a move lists only its new path.
            paths = [p.split(' -> ')[-1] if '--no-renames' not in cmd else p.replace(' -> ', '\n')
                     for p in self.paths]
            return w.Result(0, ''.join(p + '\n' for p in paths))
        return super().__call__(cmd, cwd, timeout)


class FreezeChildTests(unittest.TestCase):
    setUp, tearDown, child = ChildTests.setUp, ChildTests.tearDown, ChildTests.child

    def open_pr(self, milestone, paths, group=None):
        run = FreezeChildRun(self, group or focus_group('Build 30'), milestone, paths, status=' M x\n')
        codex = fake_codex({'commit-msg.txt': 'Fix X\n\nWhy.', 'pr-body.md': 'Body.'})
        return self.child(run, codex), run

    def pr_labels(self, run):
        pr = next(c for c in run.calls if c[:3] == ['gh', 'pr', 'create'])
        return [pr[i + 1] for i, a in enumerate(pr) if a == '--label']

    def test_app_diff_outside_the_milestone_opens_unarmed(self):
        outcome, run = self.open_pr([99], ['App/SpokenMarginsApp/Gate1AppModel.swift', 'ops/x.py'])
        self.assertEqual(outcome, 'pr-unarmed')
        self.assertEqual(self.pr_labels(run), [])
        note = next(c for c in run.calls if c[:4] == ['gh', 'issue', 'comment', '777'])
        self.assertIn('Build 30 freeze is on', note[note.index('--body') + 1])
        self.assertIn('`App/SpokenMarginsApp/Gate1AppModel.swift`', note[note.index('--body') + 1])
        self.assertTrue(run.comments()[-1].startswith('Thread "Codex worker 1" stopping: PR #777 opened unarmed · '))

    def test_moving_a_file_out_of_app_counts_as_app_code(self):
        outcome, run = self.open_pr([99], ['App/Foo.swift -> ops/Foo.swift'])
        self.assertEqual((outcome, self.pr_labels(run)), ('pr-unarmed', []))

    def test_milestone_issue_is_armed_whatever_its_diff(self):
        outcome, run = self.open_pr([42], ['App/SpokenMarginsApp/Gate1AppModel.swift'])
        self.assertEqual((outcome, self.pr_labels(run)), ('pr', ['automerge']))

    def test_diff_outside_app_code_is_armed(self):
        outcome, run = self.open_pr([99], ['ops/codex/sm_codex_worker.py', 'docs/a.md'])
        self.assertEqual((outcome, self.pr_labels(run)), ('pr', ['automerge']))

    def test_unreadable_milestone_arms_only_a_diff_outside_app_code(self):
        outcome, run = self.open_pr(None, ['Packages/SessionKit/x.swift'])
        self.assertEqual((outcome, self.pr_labels(run)), ('pr-unarmed', []))

    def test_no_freeze_arms_as_before(self):
        outcome, run = self.open_pr([], ['App/x.swift'], group=focus_group('None'))
        self.assertEqual((outcome, self.pr_labels(run)), ('pr', ['automerge']))
        self.assertFalse(run.has('gh', 'issue', 'list'))


class FreezeFinishTests(unittest.TestCase):
    setUp, run_finish = FinishChildTests.setUp, FinishChildTests.run_finish

    def finish(self, milestone, paths):
        group = focus_group('Build 30')

        def patched_call(self_run, cmd, cwd=None, timeout=None):
            cmd = [str(c) for c in cmd]
            if cmd[:4] == ['gh', 'issue', 'view', str(w.DIAL_ISSUE)]:
                return w.Result(0, json.dumps({'body': dial(codex_group(1) + '\n\n' + group)}))
            if cmd[:3] == ['gh', 'issue', 'list'] and '--milestone' in cmd:
                return w.Result(0, json.dumps([{'number': n} for n in milestone]))
            if cmd[:2] == ['git', 'diff'] and 'origin/next...HEAD' in cmd:
                return w.Result(0, ''.join(p + '\n' for p in paths))
            return original(self_run, cmd, cwd, timeout)
        original = FakeRun.__call__
        with unittest.mock.patch.object(FakeRun, '__call__', patched_call):
            return self.run_finish()

    def test_finisher_does_not_rearm_a_frozen_pr(self):
        outcome, run, data, _ = self.finish([866], ['Packages/SessionKit/Sources/SessionKit/Playback.swift'])
        self.assertEqual(outcome, 'finished-unarmed')
        self.assertNotIn('automerge', data['labels'])
        self.assertFalse(any(c[-2:] == ['--add-label', 'automerge'] for c in run.calls))
        self.assertIn('Build 30 freeze is on', run.comments()[-1])
        rows = [json.loads(line) for line in (self.home / 'ledger/usage.jsonl').read_text().splitlines()]
        self.assertEqual(rows[0]['outcome']['kind'], 'PR not armed')

    def test_finisher_rearms_a_milestone_pr(self):
        outcome, run, data, _ = self.finish([73], ['Packages/SessionKit/Sources/SessionKit/Playback.swift'])
        self.assertEqual(outcome, 'finished')
        self.assertIn('automerge', data['labels'])


if __name__ == '__main__':
    unittest.main()
