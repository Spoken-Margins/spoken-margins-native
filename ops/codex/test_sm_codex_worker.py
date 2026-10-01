"""Host tests for the Codex worker. Run: python3 -m unittest ops/codex/test_sm_codex_worker.py

No network, no real Codex, no real gh or git: every side effect goes through a fake.
"""
import datetime as dt
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_codex_worker as w  # noqa: E402

NOW = dt.datetime(2026, 10, 1, 13, 0, tzinfo=dt.timezone.utc)

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


# ---------------------------------------------------------------------------
# Fakes for the tick and the child
# ---------------------------------------------------------------------------

class FakeRun:
    """Records every command; answers by the first matching rule."""

    def __init__(self, test, wt=None, status='', fast_rc=0, issue_data=None, fail=()):
        self.test, self.wt, self.status, self.fast_rc = test, wt, status, fast_rc
        self.issue_data = issue_data or issue(42, title='Fix the thing')
        self.fail = fail
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
        if cmd[:2] == ['git', 'status']:
            return w.Result(0, self.status)
        if cmd[:2] == ['git', 'diff']:
            return w.Result(0, 'diff --git a/x b/x\n')
        if 'verify-tests.py' in joined:
            return w.Result(self.fast_rc, 'fast plan output')
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

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def child(self, run, codex):
        ops = w.Ops(home=self.home, repo_root=self.home, run=run, codex=codex, now=lambda: NOW,
                    alive=lambda pid: False, echo=False)
        return w.run_child(ops, 1, 42)

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
        self.assertEqual(fast, ['.venv/bin/python', 'scripts/verify-tests.py', '--plan', 'fast'])
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


# ---------------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------------

class SandboxTests(unittest.TestCase):
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
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='cw-'))

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def ops(self, workers=2, used=10, free=100 * 2**30, alive=lambda pid: True, issues=None):
        body = dial(codex_group(workers) if workers is not None else '')
        listing = issues if issues is not None else [issue(42, title='Fix the thing')]

        def run(cmd, cwd=None, timeout=None):
            cmd = [str(c) for c in cmd]
            if cmd[:3] == ['gh', 'issue', 'view'] and cmd[3] == str(w.DIAL_ISSUE):
                return w.Result(0, json.dumps({'body': body}))
            if cmd[:3] == ['gh', 'issue', 'list']:
                return w.Result(0, json.dumps(listing))
            if cmd[:3] == ['gh', 'issue', 'view']:
                n = int(cmd[3])
                return w.Result(0, json.dumps(next(i for i in listing if i['number'] == n)))
            raise AssertionError(f'unexpected command {cmd}')
        return w.Ops(home=self.home, repo_root=self.home, run=run, codex=None,
                     limits=lambda: limits_result(used) if used is not None else None,
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

    def test_holds_start_nothing(self):
        for kw, word in (({'used': 95}, 'hold line'), ({'used': None}, 'could not be read'),
                         ({'free': 1}, 'GiB free')):
            spawn = self.spawner()
            d = w.tick(self.ops(**kw), spawn=spawn)
            self.assertEqual(spawn.started, [], kw)
            self.assertIn(word, d['why'])

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


if __name__ == '__main__':
    unittest.main()
