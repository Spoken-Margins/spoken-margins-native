#!/usr/bin/env python3
"""Codex worker: finish PRs, then take `ready` issues, paced by the Dial (#589).

launchd runs this every 10 minutes with no arguments (a "tick"). A tick never waits on Codex:
it reads the Dial, Codex usage, free disk and the live slots, and when a slot is free and
pacing allows it spawns ONE detached child (`--slot N --pr M` or `--issue M`) and exits.

PR finishing goes first: needs-mac, a code lane FAIL, or Codex audit findings on the head.
Drafts and forks are excluded; lane changes qualify only for audit findings. At most two
finishing rounds per PR per 24 h. The child disarms
automerge, merges next without rewriting history, runs Codex and the host fast plan, and
only on a pass pushes normally and re-arms (repeating the newest T3 request if present).
A stopped finisher leaves the PR's labels as found, except automerge stays removed.

The child claims the issue, makes a worktree on `ws/<issue>-codex-<slug>` from fresh
origin/next, runs `codex exec` (workspace-write, 60-minute cap), re-runs the fast plan
itself, and only on a pass commits, pushes and opens an `automerge` PR into next. Every
other outcome posts a stop note and frees the issue. Worktree and lock always go.

Holds (every slip fails toward spending less):
- Dial: no `**Codex workers**` group, no tick, Mode Off, or dial_gate not importable -> 0.
  Two ticks -> the lower.
- Codex usage at or above its stop line minus 3, or more than 5 points ahead of a
  straight line from the Codex window's start to its finish-by target. Without Codex
  pacing ticks, use the Dial's stop line and Codex's reset.
- The usage read fails, or no stop line is ticked.
- Less than 30 GiB free disk.

Usage:
  /usr/bin/python3 ops/codex/sm_codex_worker.py [--dry-run]
  /usr/bin/python3 ops/codex/sm_codex_worker.py --slot N --issue M     (the child; launched by a tick)
  /usr/bin/python3 ops/codex/sm_codex_worker.py --slot N --pr M        (finish an existing PR)

Stdlib only, Python 3.9+. `gh` and `git` must be on PATH. Log: ~/SpokenMarginsOps/codex-worker/log.txt
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import importlib.util
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Optional
from zoneinfo import ZoneInfo

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO = os.environ.get('SM_CODEX_WORKER_REPO', 'uncomposed/spoken-margins-native')
DIAL_ISSUE = int(os.environ.get('SM_DIAL_ISSUE', '589'))
BASE_BRANCH = 'next'
REPO_ROOT = Path(__file__).resolve().parents[2]          # ops/codex/ -> repo root
HOME_DIR = Path(os.environ.get('SM_CODEX_WORKER_HOME',
                               str(Path.home() / 'SpokenMarginsOps' / 'codex-worker')))

CODEX = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'
MODEL = 'gpt-6.1-sol'
EFFORT = 'high'
CODEX_TIMEOUT_S = 60 * 60
FAST_PLAN_TIMEOUT_S = 45 * 60
FAST_EVIDENCE_DIR = 'fast-evidence'  # in the run folder, outside the worktree (#707)
LIMITS_TIMEOUT_S = 30

MAX_WORKERS = 3
MARGIN = 3                 # points below the stop line where new work holds (as the Dial gate)
TREND_SLACK = 5            # points ahead of the trend line allowed (as the Dial gate)
MIN_FREE_GIB = 30
CODEX_STOPS = (70, 80, 90, 97)
CODEX_FINISHES = {'Fri noon': (4, 12), 'Sat 7 AM': (5, 7), 'Codex reset': None}
CLAIM_WINDOW = dt.timedelta(hours=24)

EXCLUDED_LABELS = {'in-progress', 'where:mac', 'regression', 'blocked'}
CLAIM_MARK = 'Claimed by project thread "'
# Issues whose body points at SessionKit or host tests go first: Codex can verify those itself.
HOST_HINT_RE = re.compile(
    r'Packages/SessionKit|\bSessionKit[A-Za-z]*/|\bSessionKit(Audio|Persistence|Sharing)?Tests\b'
    r'|\bhost[- ]?test|--plan fast|\bswift test\b',
    re.I)
OUT_DIR_NAME = '.codex-out'
# Codex's workspace-write sandbox writes only the worktree and temp folders. The fast plan also takes a
# Mac-wide host-test slot in the lane's folder (as scripts/lane_slots.state_dir()), and swift test writes
# the clang module cache. Without these, #64's run (2026-10-01) failed before any test ran.
SANDBOX_WRITABLE_ROOTS = [
    Path(os.environ.get('SM_LANE_STATE_DIR') or Path.home() / 'Library' / 'Caches' / 'SpokenMarginsLane'),
    Path.home() / '.cache' / 'clang',
]


# ---------------------------------------------------------------------------
# Dial (pure)
# ---------------------------------------------------------------------------

def load_parse_dial() -> Optional[Callable[[str], dict]]:
    """dial_gate.parse_dial from ops/dial, or None. Only mode and stop are used, so a newer
    parse_dial with more fields (e.g. refill_at from #603) works unchanged."""
    try:
        here = str(REPO_ROOT / 'ops' / 'dial')
        if here not in sys.path:
            sys.path.insert(0, here)
        from dial_gate import parse_dial  # type: ignore
        return parse_dial
    except Exception:
        return None


def parse_codex_workers(body: str) -> tuple[int, list[str]]:
    """The ticked number in the `**Codex workers**` group: none or no group -> 0, two -> the lower."""
    current = None
    ticked: list[int] = []
    found = False
    for line in body.splitlines():
        heading = re.match(r'\s*\*\*(.+?)\*\*', line)
        if heading and not line.lstrip().startswith('-'):
            current = heading.group(1).strip().lower()
            found = found or current.startswith('codex workers')
            continue
        if line.strip() == '---':
            current = None
            continue
        box = re.match(r'\s*[-*]\s*\[([ xX])\]\s*(\d+)', line)
        if box and current and current.startswith('codex workers') and box.group(1).lower() == 'x':
            ticked.append(int(box.group(2)))
    problems = []
    if not found:
        problems.append('no Codex workers group on the Dial, so it reads 0')
        return 0, problems
    if not ticked:
        problems.append('no Codex workers box is ticked, so it reads 0')
        return 0, problems
    n = min(ticked)
    if len(ticked) > 1:
        problems.append(f'{len(ticked)} Codex workers boxes are ticked, so it uses the lowest, {n}')
    if n > MAX_WORKERS:
        problems.append(f'{n} Codex workers is above the cap, so it uses {MAX_WORKERS}')
        n = MAX_WORKERS
    return n, problems


def codex_pacing(body: str, shared_stop: Optional[int]) -> dict:
    """Read only Codex's pacing groups; empty groups retain the old defaults."""
    groups: dict[str, list[str]] = {'codex stop line': [], 'codex finish by': []}
    current = None
    for line in body.splitlines():
        heading = re.match(r'\s*\*\*(.+?)\*\*', line)
        if heading and not line.lstrip().startswith('-'):
            name = heading.group(1).strip().lower()
            current = next((g for g in groups if name.startswith(g)), None)
            continue
        if line.strip() == '---':
            current = None
            continue
        box = re.match(r'\s*[-*]\s*\[([ xX])\]\s*(.*)', line)
        if box and current and box.group(1).lower() == 'x':
            groups[current].append(box.group(2).strip().lower())

    problems = []
    stop, source = shared_stop, 'Dial Stop line'
    stops = groups['codex stop line']
    if stops:
        source = 'Codex stop line'
        values = {f'{n}%': n for n in CODEX_STOPS}
        if any(t not in values for t in stops):
            stop = None
            problems.append('muddled Codex stop line box, so nothing new starts')
        else:
            stop = min(values[t] for t in stops)
            if len(stops) > 1:
                problems.append(f'{len(stops)} Codex stop line boxes are ticked, so it uses the lowest, {stop}%')

    finishes = []
    for t in groups['codex finish by']:
        label = next((name for name in CODEX_FINISHES if t == name.lower()), None)
        if label is None:
            problems.append('muddled Codex finish by box, so it includes Codex reset (the cautious choice)')
        finishes.append(label or 'Codex reset')
    if len(finishes) > 1:
        problems.append('multiple Codex finish by boxes are ticked, so it uses the later time')
    return {'stop': stop, 'stop_source': source, 'finish_by': tuple(finishes) or ('Codex reset',),
            'problems': problems}


def read_dial(body: str, parse_dial: Optional[Callable[[str], dict]]) -> dict:
    """Mode, workers, Codex pacing targets and problems. Unreadable means zero workers."""
    workers, problems = parse_codex_workers(body)
    off = {'mode': 'off', 'stop': None, 'stop_source': 'Dial Stop line',
           'finish_by': ('Codex reset',), 'workers': 0}
    if parse_dial is None:
        return {**off,
                'problems': problems + ['ops/dial/dial_gate.py could not be imported, so it reads Off']}
    try:
        d = parse_dial(body)
        mode, stop = d.get('mode', 'off'), d.get('stop')
    except Exception as exc:  # a muddled Dial must not start work
        return {**off,
                'problems': problems + [f'parse_dial failed ({exc}), so it reads Off']}
    if mode == 'off':
        workers = 0
    pacing = codex_pacing(body, stop)
    return {**pacing, 'mode': mode, 'workers': workers, 'problems': problems + pacing['problems']}


# ---------------------------------------------------------------------------
# Pacing (pure)
# ---------------------------------------------------------------------------

def parse_rate_limits(result: Optional[dict]) -> Optional[dict]:
    """From an `account/rateLimits/read` result: the primary window plus the worst usedPercent
    across windows. None when the primary window or its fields are missing."""
    if not isinstance(result, dict):
        return None
    rl = result.get('rateLimits') or {}
    primary = rl.get('primary') or {}
    used = primary.get('usedPercent')
    mins = primary.get('windowDurationMins')
    resets = primary.get('resetsAt')
    if used is None or not mins or not resets:
        return None
    worst = max(float(w.get('usedPercent') or 0) for w in (rl.get('primary'), rl.get('secondary')) if w)
    return {'used': float(used), 'window_mins': int(mins), 'resets_at': int(resets), 'worst': worst}


def finish_target(limits: dict, finish_by: tuple[str, ...] = ('Codex reset',)) -> tuple[str, float]:
    """Resolve Eastern deadlines after the window's start; multiple ticks take the latest."""
    reset = limits['resets_at']
    start = reset - limits['window_mins'] * 60
    local_start = dt.datetime.fromtimestamp(start, ZoneInfo('America/New_York'))
    targets = []
    for label in finish_by:
        schedule = CODEX_FINISHES[label]
        if schedule is None:
            end = reset
        else:
            weekday, hour = schedule
            finish = local_start.replace(hour=hour, minute=0, second=0, microsecond=0)
            finish += dt.timedelta(days=(weekday - local_start.weekday()) % 7)
            if finish.timestamp() <= start:
                finish += dt.timedelta(days=7)
            end = finish.timestamp()
        targets.append((label, end))
    return max(targets, key=lambda target: target[1])


def trend_line(now_ts: float, limits: dict, stop: float,
               finish_by: tuple[str, ...] = ('Codex reset',)) -> float:
    """0 at the window's start, the stop line at finish-by and thereafter."""
    start = limits['resets_at'] - limits['window_mins'] * 60
    _, end = finish_target(limits, finish_by)
    share = (now_ts - start) / (end - start)
    return stop * max(0.0, min(1.0, share))


def pacing_hold(now_ts: float, stop: Optional[int], limits: Optional[dict],
                free_bytes: Optional[int], finish_by: tuple[str, ...] = ('Codex reset',)) -> Optional[str]:
    """The reason to hold, or None to go."""
    if free_bytes is not None and free_bytes < MIN_FREE_GIB * 2**30:
        return f'only {free_bytes / 2**30:.0f} GiB free disk (needs {MIN_FREE_GIB})'
    if limits is None:
        return 'Codex usage could not be read'
    if stop is None:
        return 'no Stop line is ticked on the Dial'
    if limits['worst'] >= stop - MARGIN:
        return (f"Codex usage {limits['worst']:.0f}% has reached the hold line {stop - MARGIN}% "
                f"(stop line {stop}% minus {MARGIN})")
    line = trend_line(now_ts, limits, stop, finish_by)
    if limits['used'] > line + TREND_SLACK:
        return (f"Codex usage {limits['used']:.0f}% is more than {TREND_SLACK} points ahead of the "
                f"trend ({line:.0f}% by now)")
    return None


# ---------------------------------------------------------------------------
# Slots (files, injectable pid check)
# ---------------------------------------------------------------------------

def pid_alive(pid: int) -> bool:
    """The pid exists and is this script (guards against a reused pid after a reboot)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    except OSError:
        return False
    try:
        cmd = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True,
                             text=True, timeout=10).stdout
    except Exception:
        return True
    return 'sm_codex_worker' in cmd


def scan_slots(home: Path, alive: Callable[[int], bool] = pid_alive) -> tuple[dict, list]:
    """(live {slot: info}, dead [(slot, path, info)]) from slot-N.lock files."""
    live: dict[int, dict] = {}
    dead: list = []
    if not home.is_dir():
        return live, dead
    for p in sorted(home.glob('slot-*.lock')):
        m = re.match(r'slot-(\d+)\.lock$', p.name)
        if not m:
            continue
        slot = int(m.group(1))
        try:
            info = json.loads(p.read_text())
            pid = int(info['pid'])
        except (OSError, ValueError, KeyError, TypeError):
            dead.append((slot, p, {}))
            continue
        if alive(pid):
            live[slot] = info
        else:
            dead.append((slot, p, info))
    return live, dead


def free_slot(live: dict, workers: int) -> Optional[int]:
    if len(live) >= workers:
        return None
    return next((n for n in range(1, workers + 1) if n not in live), None)


def write_lock(home: Path, slot: int, info: dict) -> Path:
    path = home / f'slot-{slot}.lock'
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(info))
    tmp.replace(path)
    return path


# ---------------------------------------------------------------------------
# Issue choice (pure)
# ---------------------------------------------------------------------------

def parse_time(s: str) -> dt.datetime:
    return dt.datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def label_names(issue: dict) -> set:
    return {(lab.get('name') if isinstance(lab, dict) else str(lab)) for lab in issue.get('labels') or []}


def label_skip(issue: dict, held: set = frozenset()) -> Optional[str]:
    """Why the labels (or a live slot) rule this issue out, or None."""
    if issue.get('state') and issue['state'].upper() != 'OPEN':
        return 'not open'
    names = label_names(issue)
    if 'ready' not in names:
        return 'not labelled ready'
    bad = sorted(names & EXCLUDED_LABELS)
    if bad:
        return 'labelled ' + ', '.join(bad)
    if issue.get('number') in held:
        return 'held by a live Codex slot'
    return None


def recent_claim(comments: list, now: dt.datetime) -> bool:
    for c in comments or []:
        if CLAIM_MARK not in (c.get('body') or ''):
            continue
        at = c.get('createdAt') or c.get('created_at')
        try:
            if at and now - parse_time(at) < CLAIM_WINDOW:
                return True
        except ValueError:
            return True  # can't tell when: assume recent
    return False


def eligible(issue: dict, comments: list, now: dt.datetime, held: set = frozenset()) -> tuple[bool, str]:
    why = label_skip(issue, held)
    if why:
        return False, why
    if recent_claim(comments, now):
        return False, 'claimed by a thread in the last 24 h'
    return True, 'eligible'


def host_testable(issue: dict) -> bool:
    return bool(HOST_HINT_RE.search((issue.get('title') or '') + '\n' + (issue.get('body') or '')))


def order_issues(issues: list) -> list:
    """Labelled `priority` first, then host-testable (SessionKit), then oldest first."""
    return sorted(issues, key=lambda i: ('priority' not in label_names(i), not host_testable(i),
                                         i.get('createdAt') or '', i.get('number') or 0))


def choose_issue(issues: list, comments_for: Callable[[int], list], now: dt.datetime,
                 held: set = frozenset()) -> tuple[Optional[dict], list]:
    """(chosen issue or None, [(number, reason)] for those passed over). Comments are fetched lazily."""
    skipped = []
    for issue in order_issues(issues):
        why = label_skip(issue, held)
        if why:
            skipped.append((issue.get('number'), why))
            continue
        ok, why = eligible(issue, comments_for(issue['number']), now, held)
        if ok:
            return issue, skipped
        skipped.append((issue.get('number'), why))
    return None, skipped


# PR finishing stays in the ops worker; use the lane's path policy rather than a second copy.
_scope_spec = importlib.util.spec_from_file_location('worker_test_scope', REPO_ROOT / 'scripts/test-scope.py')
_scope = importlib.util.module_from_spec(_scope_spec)
_scope_spec.loader.exec_module(_scope)
LANE_REPORT_RE = re.compile(r'^Lane report \S+ — (PASS|FAIL|INCONCLUSIVE)\b')
FINISH_MARK_RE = re.compile(r'Thread "Codex worker \d+" finishing #\d+')
AUDIT_REPORT_RE = re.compile(r'^\*\*Codex audit \(Astra\) on `([0-9a-f]{7,40})`\*\*\s*$')
MAX_FINISH_ROUNDS = 2
FINISH_LIMIT_REASON = 'two finishing rounds in the last 24 h; leaving this PR for a human'
FINISH_LIMIT_MARK = 'Codex finisher round limit reached.'
RUNNER_FAULT_RE = re.compile(
    r"runner fault|lane error|lane itself failed|lane's fault|not this PR|not the PR|"
    r'PermissionError|Operation not permitted|No space left on device|device (?:lost|vanished)', re.I)
CODE_FAILURE_RE = re.compile(
    r'\b(?:simulator|device) build \(fail\)|'
    r'host tests \(--plan fast\).*observed: exit [1-9]\d*|'
    r'expected: passes\. observed: failed|'
    r'\.(?:swift|m|mm|c|h):\d+:\d+: error:|failed: (?:SwiftCompile|SwiftEmitModule|CompileSwift|Ld)\b', re.I)


def comment_time(comment: dict) -> str:
    return comment.get('createdAt') or comment.get('created_at') or ''


def newest_lane_report(comments: list) -> Optional[dict]:
    reports = [c for c in comments if LANE_REPORT_RE.match((c.get('body') or '').strip())]
    return max(reports, key=comment_time, default=None)


def failing_head_report(pr: dict) -> Optional[dict]:
    report = newest_lane_report(pr.get('comments') or [])
    if not report:
        return None
    body = report['body'].strip()
    sha = re.search(r'\bcommit `?([0-9a-f]{7,40})\b', body)
    head = pr.get('headRefOid') or ''
    if (LANE_REPORT_RE.match(body).group(1) != 'FAIL' or not sha or not head.startswith(sha.group(1))
            or RUNNER_FAULT_RE.search(body) or not CODE_FAILURE_RE.search(body)):
        return None
    return report


def audit_findings_on_head(pr: dict) -> Optional[dict]:
    """Newest Astra audit only: its header must name the head and its verdict must not be clean."""
    reports = [c for c in pr.get('comments') or []
               if AUDIT_REPORT_RE.match((c.get('body') or '').strip().split('\n', 1)[0])]
    report = max(reports, key=comment_time, default=None)
    if not report:
        return None
    header, _, verdict = report['body'].strip().partition('\n')
    head = pr.get('headRefOid') or ''
    if not head.startswith(AUDIT_REPORT_RE.match(header).group(1)):
        return None
    if verdict.lstrip().startswith('No blocking findings'):
        return None
    return report


def recent_finish_rounds(comments: list, now: dt.datetime) -> int:
    """Count starts, including failed rounds and earlier heads. Undated starts hold spending."""
    rounds = 0
    for c in comments:
        if not FINISH_MARK_RE.search(c.get('body') or ''):
            continue
        try:
            if not comment_time(c):
                return MAX_FINISH_ROUNDS
            if now - parse_time(comment_time(c)) < CLAIM_WINDOW:
                rounds += 1
        except ValueError:
            return MAX_FINISH_ROUNDS
    return rounds


def finish_eligible(pr: dict, now: dt.datetime, held: set = frozenset()) -> tuple[bool, str]:
    if pr.get('state') != 'OPEN' or pr.get('baseRefName') != BASE_BRANCH or pr.get('isDraft'):
        return False, 'not an open non-draft PR into next'
    owner = (pr.get('headRepositoryOwner') or {}).get('login')
    repo = (pr.get('headRepository') or {}).get('name')
    if pr.get('isCrossRepository') or f'{owner}/{repo}'.lower() != REPO.lower():
        return False, 'branch is not in this repo'
    if pr.get('headRefName') in ('main', BASE_BRANCH):
        return False, 'protected branch belongs to the owner'
    if pr['number'] in held:
        return False, 'held by a live Codex slot'
    audit = audit_findings_on_head(pr)
    if not audit and any(_scope.is_lane_path(f['path']) for f in pr.get('files') or []):
        return False, 'touches lane machinery'
    if audit or 'needs-mac' in label_names(pr) or failing_head_report(pr):
        if recent_finish_rounds(pr.get('comments') or [], now) >= MAX_FINISH_ROUNDS:
            return False, FINISH_LIMIT_REASON
        return True, ('Codex audit findings on head' if audit else
                      'needs-mac' if 'needs-mac' in label_names(pr) else 'lane FAIL on head')
    return False, 'no needs-mac, code failure or Codex audit findings on head'


def choose_finish(prs: list, details_for: Callable[[int], dict], now: dt.datetime,
                  held: set = frozenset(),
                  on_limit: Optional[Callable[[dict], None]] = None) -> tuple[Optional[dict], list]:
    skipped = []
    for pr in sorted(prs, key=lambda p: (p.get('createdAt') or '', p['number'])):
        if pr.get('isDraft') or pr['number'] in held:
            continue
        pr = details_for(pr['number'])
        ok, why = finish_eligible(pr, now, held)
        if ok:
            return pr, skipped
        if why == FINISH_LIMIT_REASON and on_limit:
            on_limit(pr)
        skipped.append((pr['number'], why))
    return None, skipped


def finish_lane_request(comments: list) -> Optional[str]:
    requests = [c for c in comments if re.search(r'^\s*/lane\s+T\d\b', c.get('body') or '', re.M)]
    newest = max(requests, key=comment_time, default=None)
    if not newest or not re.search(r'^\s*/lane\s+T3\b', newest['body'], re.M):
        return None
    tests = re.search(r'^[ \t]*tests[ \t]*:[^\r\n]*', newest['body'], re.M)
    if not tests or not tests.group(0).split(':', 1)[1].strip():
        raise RuntimeError('newest T3 request has no tests: line; cannot safely requeue')
    return '/lane T3\n' + tests.group(0)


# ---------------------------------------------------------------------------
# Text (pure)
# ---------------------------------------------------------------------------

def slugify(title: str, limit: int = 40) -> str:
    slug = re.sub(r'[^a-z0-9]+', '-', (title or '').lower()).strip('-')
    return slug[:limit].rstrip('-') or 'issue'


def utc_stamp(now: dt.datetime) -> str:
    return now.astimezone(dt.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')


def claim_text(slot: int, now: dt.datetime) -> str:
    return f'Claimed by project thread "Codex worker {slot}" at {utc_stamp(now)}. Model {MODEL} {EFFORT}.'


def stop_text(slot: int, result: str, reason: str) -> str:
    return f'Thread "Codex worker {slot}" stopping: {result} · {reason}'


def build_prompt(number: int, title: str, body: str) -> str:
    return '\n'.join([
        f'You are working in a git worktree of Spoken Margins (branch from origin/{BASE_BRANCH}).',
        'Read AGENTS.md first and follow it, except where this prompt says otherwise.',
        '',
        f'Implement GitHub issue #{number}: {title}',
        '',
        'Issue body:',
        (body or '(empty)').strip(),
        '',
        'Rules for this run:',
        '- Keep the change small and host-testable. Put logic in Packages/SessionKit first; '
        'do not grow App/SpokenMarginsApp/Gate1AppModel.swift.',
        '- Write a regression test that fails without the fix, and check that it does.',
        '- Your sandbox cannot run `ps`, has no network, and cannot encode, play or speak real audio. '
        'SessionKit\'s dependencies are already resolved. Run SessionKit tests directly with '
        '`swift test --disable-sandbox --filter <Name>` in Packages/SessionKit (SwiftPM cannot start '
        'its own sandbox inside yours).',
        '- Run `.venv/bin/python scripts/verify-tests.py --plan fast` and make every step it runs pass. '
        'In your sandbox it skips `runner-tests` (the lane boot tests need `ps`), reports the known '
        'real-audio tests without failing on them, and ends with status `verified_in_codex_sandbox`. '
        'If you change anything under scripts/, also run that file\'s tests: '
        '`.venv/bin/python -m unittest discover -s scripts/tests -p \'test_<name>.py\'`.',
        '- After you finish, the wrapper runs the full fast plan itself, outside your sandbox, before any '
        'PR opens; that run is the gate. A failure caused only by the sandbox (no `ps`, no network, no '
        'real audio, no writes outside the worktree and temp folders) is not a reason to give up or to '
        'build shims or wrappers: finish the change and name the failure in pr-body.md.',
        '- Do not boot simulators or run xcodebuild.',
        '- Do not commit, branch, stash or run any other git command that changes state. '
        'Leave your changes uncommitted in the working tree.',
        f'- When done, write `{OUT_DIR_NAME}/commit-msg.txt` (a subject line under 72 characters, '
        'a blank line, then what was wrong and why the change fixes it) and '
        f'`{OUT_DIR_NAME}/pr-body.md` (what changed, how it was verified, what is not verified).',
        f'- If you cannot finish, write `{OUT_DIR_NAME}/give-up.txt` with the reason in one line, '
        'and stop.',
    ])


def pr_body(raw: str, number: int, slot: int) -> str:
    body = (raw or '').strip() or f'Implements #{number}.'
    if f'#{number}' not in body:
        body = f'Issue #{number}.\n\n{body}'
    return (f'{body}\n\nStatus: implemented (host fast plan passed; no simulator or device check).\n\n'
            f'Written by Codex {MODEL} (reasoning effort {EFFORT}) in Codex worker {slot}, and verified by '
            f'the wrapper\'s own run of `scripts/verify-tests.py --plan fast` before this PR opened.\n')


def commit_message(raw: str, number: int, title: str) -> str:
    msg = (raw or '').strip()
    if not msg:
        msg = f'{title} (#{number})\n\nCodex wrote no commit message; see the PR description.'
    return f'{msg}\n\nCo-Authored-By: Codex {MODEL} <noreply@openai.com>\n'


# ---------------------------------------------------------------------------
# Side effects (injectable)
# ---------------------------------------------------------------------------

class Result:
    def __init__(self, returncode: int, stdout: str = '', stderr: str = ''):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def kill_tree(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=20)
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass


def default_run(cmd: list, cwd: Optional[Path] = None, timeout: Optional[float] = 300) -> Result:
    """Run a command in its own process group; on timeout kill the group and return 124.

    Never with CODEX_SANDBOX: with it, verify-tests skips runner-tests, and this runs the gate."""
    env = {k: v for k, v in os.environ.items() if k != 'CODEX_SANDBOX'}
    proc = subprocess.Popen([str(c) for c in cmd], cwd=str(cwd) if cwd else None, env=env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_tree(proc)
        out, err = proc.communicate()
        return Result(124, out or '', (err or '') + f'\ntimed out after {timeout}s')
    return Result(proc.returncode, out, err)


def codex_command(worktree: Path, answer: Path, prompt: str) -> list:
    roots = json.dumps([str(p) for p in SANDBOX_WRITABLE_ROOTS])  # a JSON string list is a TOML array
    return [CODEX, 'exec', '-m', MODEL, '-c', f'model_reasoning_effort="{EFFORT}"',
            '-s', 'workspace-write', '-c', f'sandbox_workspace_write.writable_roots={roots}',
            '-C', str(worktree), '-o', str(answer), prompt]


def default_codex(worktree: Path, answer: Path, prompt: str, transcript: Path) -> tuple[bool, str]:
    cmd = codex_command(worktree, answer, prompt)
    with open(os.devnull, 'rb') as devnull, open(transcript, 'wb') as tfh:
        proc = subprocess.Popen(cmd, stdin=devnull, stdout=tfh, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=CODEX_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            return False, f'Codex timed out after {CODEX_TIMEOUT_S // 60} min'
    if rc != 0:
        tail = transcript.read_text(errors='replace').strip().splitlines()[-1:] or ['']
        return False, f'Codex exit {rc}: {tail[0][:160]}'
    return True, 'ok'


def read_codex_limits(timeout: float = LIMITS_TIMEOUT_S) -> Optional[dict]:
    """`account/rateLimits/read` over `codex app-server` (as ops/codex/codex_limits.py). None on failure."""
    try:
        p = subprocess.Popen([CODEX, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    except OSError:
        return None

    def send(o):
        p.stdin.write(json.dumps(o) + '\n')
        p.stdin.flush()

    def recv(want):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([p.stdout], [], [], 1)
            if r:
                line = p.stdout.readline()
                if not line:
                    return None
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get('id') == want:
                    return m
        return None

    try:
        send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'sm-codex-worker', 'version': '0.1'}}})
        if recv(1) is None:
            return None
        send({'method': 'initialized'})
        send({'id': 2, 'method': 'account/rateLimits/read'})
        r = recv(2)
        return r.get('result') if r and 'result' in r else None
    except Exception:
        return None
    finally:
        kill_tree(p)


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


class Ops:
    """Everything with a side effect, so tests can swap each piece."""

    def __init__(self, home: Path = HOME_DIR, repo_root: Path = REPO_ROOT,
                 run: Callable = default_run, codex: Callable = default_codex,
                 limits: Callable = read_codex_limits, now: Callable = now_utc,
                 alive: Callable = pid_alive, free_bytes: Optional[Callable] = None,
                 echo: bool = True):
        self.home, self.repo_root = home, repo_root
        self.run, self.codex, self.limits, self.now, self.alive = run, codex, limits, now, alive
        self.free_bytes = free_bytes or (lambda: shutil.disk_usage(str(Path.home())).free)
        self.echo = echo

    def log(self, msg: str) -> None:
        line = f"{dt.datetime.now().astimezone().isoformat(timespec='seconds')} {msg}"
        self.home.mkdir(parents=True, exist_ok=True)
        with open(self.home / 'log.txt', 'a', encoding='utf-8') as fh:
            fh.write(line + '\n')
        if self.echo:
            print(line, flush=True)

    def must(self, cmd: list, cwd: Optional[Path] = None, timeout: Optional[float] = 300) -> Result:
        res = self.run(cmd, cwd=cwd, timeout=timeout)
        if res.returncode != 0:
            raise RuntimeError(f"{' '.join(str(c) for c in cmd[:3])} failed: {(res.stderr or res.stdout).strip()[:300]}")
        return res

    def gh_json(self, args: list):
        return json.loads(self.must(['gh'] + args, cwd=self.repo_root).stdout or 'null')

    def dial_body(self) -> str:
        return self.gh_json(['issue', 'view', str(DIAL_ISSUE), '-R', REPO, '--json', 'body'])['body'] or ''

    def ready_issues(self) -> list:
        return self.gh_json(['issue', 'list', '-R', REPO, '--state', 'open', '--label', 'ready',
                             '--limit', '200', '--json', 'number,title,body,labels,createdAt'])

    def issue(self, number: int) -> dict:
        return self.gh_json(['issue', 'view', str(number), '-R', REPO,
                             '--json', 'number,title,body,labels,state,createdAt,comments'])

    def open_prs(self) -> list:
        return self.gh_json(['pr', 'list', '-R', REPO, '--state', 'open', '--base', BASE_BRANCH,
                             '--limit', '200', '--json', 'number,isDraft,createdAt'])

    def pull(self, number: int) -> dict:
        return self.gh_json(['pr', 'view', str(number), '-R', REPO, '--json',
                             'number,title,body,labels,state,isDraft,baseRefName,headRefName,headRefOid,'
                             'headRepository,headRepositoryOwner,isCrossRepository,files,comments,createdAt'])

    def comment(self, number: int, body: str) -> None:
        self.must(['gh', 'issue', 'comment', str(number), '-R', REPO, '--body', body], cwd=self.repo_root)

    def label(self, number: int, add: Optional[str] = None, remove: Optional[str] = None) -> None:
        cmd = ['gh', 'issue', 'edit', str(number), '-R', REPO]
        if add:
            cmd += ['--add-label', add]
        if remove:
            cmd += ['--remove-label', remove]
        self.must(cmd, cwd=self.repo_root)


# ---------------------------------------------------------------------------
# Tick (the launchd run)
# ---------------------------------------------------------------------------

def note_finish_limit(ops: Ops, pr: dict, now: dt.datetime) -> None:
    """Post once per rolling window, without changing labels or spending another round."""
    for c in pr.get('comments') or []:
        if not (c.get('body') or '').startswith(FINISH_LIMIT_MARK):
            continue
        try:
            if not comment_time(c) or now - parse_time(comment_time(c)) < CLAIM_WINDOW:
                return
        except ValueError:
            return
    try:
        ops.comment(pr['number'], f'{FINISH_LIMIT_MARK} Two rounds started in the last 24 h. '
                    'Leaving this PR for a human; no further finisher round until the window clears.')
    except Exception as exc:
        ops.log(f"PR #{pr['number']}: could not post finisher limit note: {exc}")


def tick(ops: Ops, dry_run: bool = False, spawn: Optional[Callable] = None) -> dict:
    """Decide and maybe start one child. Returns the decision for logging and tests."""
    now = ops.now()
    say = print if dry_run else ops.log
    tag = 'dry-run ' if dry_run else ''
    decision: dict = {'start': None}

    try:
        dial = read_dial(ops.dial_body(), load_parse_dial())
    except Exception as exc:
        dial = {**read_dial('', None), 'problems': [f'Dial read failed ({exc})']}
    decision['dial'] = dial
    limits = parse_rate_limits(ops.limits())
    decision['limits'] = limits
    try:
        free = ops.free_bytes()
    except OSError:
        free = 0
    live, dead = scan_slots(ops.home, ops.alive)
    decision['live'] = sorted(live)

    stop = f"{dial['stop_source']} {dial['stop']}%" if dial['stop'] else f"no readable {dial['stop_source']}"
    if limits:
        label, finish_ts = finish_target(limits, dial['finish_by'])
        finish = f"{label} ({utc_stamp(dt.datetime.fromtimestamp(finish_ts, dt.timezone.utc))})"
    else:
        finish = ' / '.join(dial['finish_by']) + ' (time unavailable without usage window)'
    say(f"Dial: mode {dial['mode']}, {stop}, finish by {finish}, Codex workers {dial['workers']}")
    for p in dial['problems']:
        say(f'  note: {p}')
    if dry_run:
        if limits:
            resets = dt.datetime.fromtimestamp(limits['resets_at'], dt.timezone.utc)
            line = trend_line(now.timestamp(), limits, dial['stop'], dial['finish_by']) if dial['stop'] else None
            trend = f', trend {line:.0f}%' if line is not None else ''
            print(f"Codex usage: {limits['used']:.0f}% of a {limits['window_mins'] // 60} h window "
                  f"resetting {utc_stamp(resets)} (worst window {limits['worst']:.0f}%){trend}")
        else:
            print('Codex usage: could not be read')
        print(f'Disk free: {free / 2**30:.0f} GiB')
        print(f"Slots: live {sorted(live) or 'none'}; dead locks {[s for s, _, _ in dead] or 'none'}")
    else:
        for slot, path, info in dead:
            kind = 'pr' if info.get('pr') else 'issue'
            ops.log(f"slot {slot}: lock of dead pid {info.get('pid', '?')} ({kind} #{info.get(kind, '?')}) "
                    'cleared; check its labels by hand')
            path.unlink(missing_ok=True)

    hold = pacing_hold(now.timestamp(), dial['stop'], limits, free, dial['finish_by'])
    slot = free_slot(live, dial['workers'])
    if dial['workers'] == 0:
        decision['why'] = 'Dial allows 0 Codex workers'
    elif slot is None:
        decision['why'] = f"all {dial['workers']} slots busy"
    elif hold:
        decision['why'] = f'holding: {hold}'
    else:
        decision['why'] = None

    issue = pr = None
    if decision['why'] is None or dry_run:
        try:
            held_prs = {int(i['pr']) for i in live.values() if i.get('pr')}
            pr, skipped = choose_finish(ops.open_prs(), ops.pull, now, held_prs,
                                       on_limit=None if dry_run else lambda p: note_finish_limit(ops, p, now))
            held = {int(i.get('issue')) for i in live.values() if i.get('issue')}
            if pr is None:
                issue, issue_skipped = choose_issue(ops.ready_issues(), lambda n: ops.issue(n).get('comments') or [],
                                                    now, held)
                skipped += issue_skipped
            decision['pr'] = pr['number'] if pr else None
            decision['issue'] = issue['number'] if issue else None
            if dry_run:
                print(f"Chosen PR to finish: #{pr['number']} {pr['title']}" if pr else 'Chosen PR to finish: none')
                print(f"Chosen issue: #{issue['number']} {issue['title']}" if issue else 'Chosen issue: none')
                for n, why in skipped:
                    print(f'  passed over #{n}: {why}')
        except Exception as exc:
            if decision['why'] is None:
                decision['why'] = f'listing jobs failed ({exc})'
        if decision['why'] is None and issue is None and pr is None:
            decision['why'] = 'no eligible ready issue'

    if decision['why']:
        say(f"{tag}idle: {decision['why']}")
        return decision
    job, kind = (pr, 'pr') if pr else (issue, 'issue')
    if dry_run:
        print(f"Would start slot {slot} on {kind} #{job['number']}; dry run, nothing started")
        decision['start'] = (slot, job['number'])
        return decision

    spawner = spawn or (spawn_finish_child if pr else spawn_child)
    pid = spawner(ops, slot, job['number'])
    write_lock(ops.home, slot, {'pid': pid, kind: job['number'], 'started': utc_stamp(now)})
    ops.log(f"started slot {slot} (pid {pid}) on {kind} #{job['number']} {job['title']}")
    decision['start'] = (slot, job['number'])
    return decision


def spawn_child(ops: Ops, slot: int, number: int, kind: str = 'issue') -> int:
    ops.home.mkdir(parents=True, exist_ok=True)
    out = open(ops.home / f'slot-{slot}.out', 'ab')
    proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--slot', str(slot),
                             f'--{kind}', str(number)],
                            cwd=str(ops.repo_root), stdin=subprocess.DEVNULL, stdout=out,
                            stderr=subprocess.STDOUT, start_new_session=True)
    return proc.pid


def spawn_finish_child(ops: Ops, slot: int, number: int) -> int:
    return spawn_child(ops, slot, number, kind='pr')


# ---------------------------------------------------------------------------
# Child (one issue, one slot)
# ---------------------------------------------------------------------------

def branch_free(ops: Ops, name: str) -> bool:
    local = ops.run(['git', 'rev-parse', '--verify', '--quiet', f'refs/heads/{name}'], cwd=ops.repo_root)
    if local.returncode == 0:
        return False
    remote = ops.run(['git', 'ls-remote', '--exit-code', '--heads', 'origin', name], cwd=ops.repo_root)
    return remote.returncode != 0


def pick_branch(ops: Ops, number: int, title: str) -> str:
    base = f'ws/{number}-codex-{slugify(title)}'
    for n in range(1, 10):
        name = base if n == 1 else f'{base}-{n}'
        if branch_free(ops, name):
            return name
    raise RuntimeError(f'no free branch name for {base}')


def stage_changes(ops: Ops, wt: Path) -> None:
    """Trim trailing blank lines in changed text files before staging, including new files."""
    paths = ['--', '.', f':(exclude){OUT_DIR_NAME}']
    tracked = ops.must(['git', 'diff', '--name-only', '-z', 'HEAD', *paths], cwd=wt).stdout
    untracked = ops.must(['git', 'ls-files', '--others', '--exclude-standard', '-z', *paths], cwd=wt).stdout
    for name in sorted(set((tracked + untracked).split('\0')) - {''}):
        path = wt / name
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if b'\0' in data:
            continue
        try:
            data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        lines = data.splitlines(keepends=True)
        while lines and not lines[-1].strip(b' \t\r\n'):
            lines.pop()
        trimmed = b''.join(lines)
        if trimmed != data:
            path.write_bytes(trimmed)
    ops.must(['git', 'add', '-A', *paths], cwd=wt)


def check_staged_changes(ops: Ops, wt: Path) -> None:
    """Reject conflict markers and Git errors, but never reject whitespace warnings."""
    ops.must(['git', '-c', 'core.whitespace=-blank-at-eol,-blank-at-eof,-space-before-tab,'
              '-indent-with-non-tab,-tab-in-indent', 'diff', '--cached', '--check'], cwd=wt)


def run_fast_plan(ops: Ops, wt: Path, run_dir: Path) -> Result:
    """The wrapper's own --plan fast in the worktree, its evidence written to the run folder.

    Without --output, verify-tests writes its manifest and step logs under the worktree's
    artifacts/, and removing the worktree deleted them, even after a timeout (#707). The run
    folder is outside the worktree, so the evidence is never staged and survives cleanup, and
    each step's log is there from the moment the step starts."""
    evidence = run_dir / FAST_EVIDENCE_DIR
    fast = ops.run(['.venv/bin/python', 'scripts/verify-tests.py', '--plan', 'fast', '--output', str(evidence)],
                   cwd=wt, timeout=FAST_PLAN_TIMEOUT_S)
    (run_dir / 'fast-plan.txt').write_text((fast.stdout or '') + (fast.stderr or '')
                                           + f'\nEvidence folder: {evidence}\n')
    return fast


def save_diff(ops: Ops, wt: Path, dest: Path) -> None:
    """Save everything Codex changed, new files included, before the worktree is removed.

    Plain `git diff` leaves out untracked files, so a give-up or failed run lost every file Codex
    created (#64). Staging first is safe: the commit step stages the same paths again.
    """
    stage_changes(ops, wt)
    diff = ops.run(['git', 'diff', '--cached', '--binary'], cwd=wt).stdout
    dest.write_text(diff or '')


def run_child(ops: Ops, slot: int, number: int) -> str:
    """Claim, run Codex, verify, and open the PR or stop. Returns the outcome word."""
    lock = ops.home / f'slot-{slot}.lock'
    wt = ops.home / f'wt-{slot}'
    now = ops.now()
    run_dir = ops.home / 'runs' / f"{number}-{now.strftime('%Y%m%dT%H%M%SZ')}"
    thread = f'Codex worker {slot}'
    claimed = stopped = wt_added = False
    branch = None

    def stop(result: str, reason: str, keep_label: bool = False) -> None:
        # Best effort on both: a failed comment must not leave the issue labelled in-progress.
        nonlocal stopped
        stopped = True
        ops.log(f'#{number} slot {slot}: stopping: {result} · {reason}')
        try:
            ops.comment(number, stop_text(slot, result, reason))
        except Exception as exc:
            ops.log(f'#{number} slot {slot}: could not post the stop note: {exc}')
        if not keep_label:
            try:
                ops.label(number, remove='in-progress')
            except Exception as exc:
                ops.log(f'#{number} slot {slot}: could not remove in-progress: {exc}')

    try:
        run_dir.mkdir(parents=True, exist_ok=True)
        issue = ops.issue(number)
        ok, why = eligible(issue, issue.get('comments') or [], now)
        if not ok:
            ops.log(f'#{number} slot {slot}: not claimed on re-check: {why}')
            return 'skipped'
        ops.label(number, add='in-progress')
        ops.comment(number, claim_text(slot, now))
        claimed = True
        ops.log(f'#{number} slot {slot}: claimed as "{thread}"')

        ops.must(['git', 'fetch', '--quiet', 'origin', BASE_BRANCH], cwd=ops.repo_root, timeout=600)
        if wt.exists():
            ops.run(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
            shutil.rmtree(wt, ignore_errors=True)
            ops.run(['git', 'worktree', 'prune'], cwd=ops.repo_root)
        branch = pick_branch(ops, number, issue.get('title') or '')
        ops.must(['git', 'worktree', 'add', '--quiet', '-b', branch, str(wt), f'origin/{BASE_BRANCH}'],
                 cwd=ops.repo_root, timeout=600)
        wt_added = True
        ops.must(['scripts/setup-worktree.sh'], cwd=wt)
        # Codex's sandbox has no network, so SwiftPM there can't clone SessionKit's dependencies.
        ops.must(['swift', 'package', '--package-path', 'Packages/SessionKit', 'resolve'], cwd=wt, timeout=600)
        out = wt / OUT_DIR_NAME
        out.mkdir(exist_ok=True)

        t0 = time.time()
        prompt = build_prompt(number, issue.get('title') or '', issue.get('body') or '')
        codex_ok, codex_why = ops.codex(wt, run_dir / 'answer.md', prompt, run_dir / 'transcript.txt')
        ops.log(f'#{number} slot {slot}: Codex finished in {int(time.time() - t0) // 60} min: {codex_why}')

        changes = ops.run(['git', 'status', '--porcelain', '--', '.', f':(exclude){OUT_DIR_NAME}'], cwd=wt).stdout
        if changes.strip():
            save_diff(ops, wt, run_dir / 'codex.diff')
        give_up = out / 'give-up.txt'
        if give_up.exists():
            reason = (give_up.read_text(errors='replace').strip().splitlines() or ['Codex gave up'])[0]
            stop('none', f'Codex gave up: {reason[:300]}')
            return 'give-up'
        if not codex_ok:
            stop('none', codex_why)
            return 'codex-failed'
        if not changes.strip():
            stop('none', 'Codex made no changes')
            return 'empty'

        fast = run_fast_plan(ops, wt, run_dir)

        msg_file = run_dir / 'commit-msg.txt'
        raw_msg = (out / 'commit-msg.txt').read_text(errors='replace') if (out / 'commit-msg.txt').exists() else ''
        msg_file.write_text(commit_message(raw_msg, number, issue.get('title') or ''))
        stage_changes(ops, wt)
        ops.must(['git', 'commit', '--quiet', '-F', str(msg_file)], cwd=wt)

        if fast.returncode != 0:
            ops.must(['git', 'push', '--quiet', '-u', 'origin', branch], cwd=wt, timeout=600)
            stop('none', f'fast plan failed; branch `{branch}` pushed for a human, no PR')
            return 'fast-failed'

        ops.must(['git', 'push', '--quiet', '-u', 'origin', branch], cwd=wt, timeout=600)
        raw_body = (out / 'pr-body.md').read_text(errors='replace') if (out / 'pr-body.md').exists() else ''
        body_file = run_dir / 'pr-body.md'
        body_file.write_text(pr_body(raw_body, number, slot))
        title = msg_file.read_text().splitlines()[0].strip()[:120]
        created = ops.must(['gh', 'pr', 'create', '-R', REPO, '--base', BASE_BRANCH, '--head', branch,
                            '--title', title, '--body-file', str(body_file), '--label', 'automerge'], cwd=wt)
        m = re.search(r'/pull/(\d+)', created.stdout or '')
        pr = m.group(1) if m else '?'
        stop(f'PR #{pr} armed', 'done', keep_label=True)
        return 'pr'
    except Exception as exc:
        ops.log(f'#{number} slot {slot}: wrapper error: {exc}')
        if claimed and not stopped:
            stop('none', f'wrapper error: {str(exc)[:200]}')
        return 'error'
    finally:
        if wt_added:
            ops.run(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
        if branch:
            ops.run(['git', 'branch', '-D', branch], cwd=ops.repo_root)
        try:
            info = json.loads(lock.read_text())
            if int(info.get('pid', -1)) in (os.getpid(), -1) or not ops.alive(int(info['pid'])):
                lock.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            pass


# ---------------------------------------------------------------------------
# Child (finish one PR in a shared slot)
# ---------------------------------------------------------------------------

def run_finish_child(ops: Ops, slot: int, number: int) -> str:
    """Finish an existing PR. Never push failed work, rewrite history, or push while armed."""
    wt = ops.home / f'wt-{slot}'
    lock = ops.home / f'slot-{slot}.lock'
    now = ops.now()
    run_dir = ops.home / 'runs' / f"pr-{number}-{now.strftime('%Y%m%dT%H%M%SZ')}"
    claimed = wt_added = False
    original_labels = set()

    def stop(reason: str) -> None:
        # Keep every original label except automerge, even if arming failed partway through.
        try:
            ops.label(number, remove='automerge')
            current = label_names(ops.pull(number))
            for label in original_labels - current - {'automerge'}:
                ops.label(number, add=label)
            if 'lane:queued' not in original_labels and 'lane:queued' in current:
                ops.label(number, remove='lane:queued')
        except Exception as exc:
            ops.log(f'PR #{number}: could not restore stop labels: {exc}')
        try:
            ops.comment(number, stop_text(slot, 'PR not armed', reason[:500]))
        except Exception as exc:
            ops.log(f'PR #{number}: could not post stop note: {exc}')

    try:
        run_dir.mkdir(parents=True, exist_ok=True)
        pr = ops.pull(number)
        ok, why = finish_eligible(pr, now)
        if not ok:
            if why == FINISH_LIMIT_REASON:
                note_finish_limit(ops, pr, now)
            ops.log(f'PR #{number}: not claimed on re-check: {why}')
            return 'skipped'
        original_labels = label_names(pr)
        ops.comment(number, f'Thread "Codex worker {slot}" finishing #{number}')
        claimed = True
        ops.label(number, remove='automerge')
        if 'automerge' in label_names(ops.pull(number)):
            raise RuntimeError('automerge still present after disarming')

        branch, head = pr['headRefName'], pr['headRefOid']
        # Explicit tracking refs, so a checkout configured to fetch only next still gets the PR.
        ops.must(['git', 'fetch', '--quiet', 'origin',
                  f'refs/heads/{BASE_BRANCH}:refs/remotes/origin/{BASE_BRANCH}',
                  f'refs/heads/{branch}:refs/remotes/origin/{branch}'], cwd=ops.repo_root, timeout=600)
        if wt.exists():
            ops.must(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
        # A detached checkout avoids moving/deleting an author's local branch. The push names its ref.
        ops.must(['git', 'worktree', 'add', '--quiet', '--detach', str(wt), f'origin/{branch}'],
                 cwd=ops.repo_root, timeout=600)
        wt_added = True
        if ops.must(['git', 'rev-parse', 'HEAD'], cwd=wt).stdout.strip() != head:
            raise RuntimeError('PR head changed before checkout; no push')
        ops.must(['scripts/setup-worktree.sh'], cwd=wt)
        ops.must(['swift', 'package', '--package-path', 'Packages/SessionKit', 'resolve'], cwd=wt, timeout=600)
        merge = ops.run(['git', 'merge', '--no-commit', '--no-ff', f'origin/{BASE_BRANCH}'], cwd=wt, timeout=600)
        conflicts = ops.must(['git', 'diff', '--name-only', '--diff-filter=U'], cwd=wt).stdout.strip()
        if merge.returncode != 0 and not conflicts:
            raise RuntimeError(f'merge failed without resolvable conflicts: {merge.stderr or merge.stdout}')
        report = failing_head_report(pr) or newest_lane_report(pr.get('comments') or [])
        report_text = report['body'] if report else '(no lane report)'
        audit = audit_findings_on_head(pr)
        audit_text = audit['body'] if audit else '(no Codex audit findings on head)'
        summary = '\n'.join(line for line in report_text.splitlines()
                            if 'evidence:' in line or 'observed:' in line or line.startswith('ran:'))
        summary += f'\nMerge next output:\n{merge.stdout}\n{merge.stderr}\nConflicts:\n{conflicts or "none"}'
        context = (f"Finish PR #{number}: {pr['title']}\n\n{pr.get('body') or ''}\n\n"
                   f'Lane report:\n{report_text}\n\nEvidence summary:\n{summary}\n\n'
                   f'Codex audit findings:\n{audit_text}\n\n'
                   'For each audit finding, fix it with a regression test that you run first to show '
                   'it fails without the fix, or explain with evidence why the finding is wrong in '
                   '.codex-out/pr-body.md. The wrapper posts that explanation as a PR comment, even '
                   'if no code change is needed. Do not post comments yourself. '
                   'Fix the reported code failure or resolve the merge conflicts. The wrapper has merged '
                   'origin/next with --no-commit; leave resolved files uncommitted. Do not run git merge, '
                   'rebase, reset, push, or change labels. Explain the cause and fix in the output files.')
        prompt = build_prompt(number, pr['title'], context).replace(
            f'Implement GitHub issue #{number}:', f'Finish existing GitHub PR #{number}:', 1).replace(
                f'(branch from origin/{BASE_BRANCH})', '(PR head with origin/next merged, uncommitted)', 1).replace(
                'Issue body:', 'PR context:', 1)
        out = wt / OUT_DIR_NAME
        out.mkdir(exist_ok=True)
        codex_ok, codex_why = ops.codex(wt, run_dir / 'answer.md', prompt, run_dir / 'transcript.txt')
        changes = ops.must(['git', 'status', '--porcelain', '--', '.', f':(exclude){OUT_DIR_NAME}'], cwd=wt).stdout
        if changes.strip():
            save_diff(ops, wt, run_dir / 'codex.diff')
        if (out / 'give-up.txt').exists():
            reason = (out / 'give-up.txt').read_text(errors='replace').strip().splitlines()
            stop(f'Codex gave up: {reason[0] if reason else "no reason"}')
            return 'give-up'
        if not codex_ok:
            stop(codex_why)
            return 'codex-failed'
        merge_pending = ops.run(['git', 'rev-parse', '--verify', '--quiet', 'MERGE_HEAD'], cwd=wt).returncode == 0
        if not changes.strip() and not merge_pending:
            if audit and (out / 'pr-body.md').exists():
                explanation = (out / 'pr-body.md').read_text(errors='replace').strip()
                if explanation:
                    ops.comment(number, f'Thread "Codex worker {slot}" response to audit on `{head[:7]}`.\n\n'
                                + explanation)
            stop('Codex made no changes and next is already merged; no push')
            return 'empty'
        # Staging the resolutions does not hide accidentally retained conflict markers.
        check_staged_changes(ops, wt)
        fast = run_fast_plan(ops, wt, run_dir)
        if fast.returncode != 0:
            stop('fast plan failed; no commit or push. Evidence kept in ' + str(run_dir / 'fast-plan.txt'))
            return 'fast-failed'

        raw_msg = (out / 'commit-msg.txt').read_text(errors='replace') if (out / 'commit-msg.txt').exists() else ''
        if not raw_msg.strip() or not (out / 'pr-body.md').exists():
            raise RuntimeError('Codex did not leave a cause/fix and change summary; no push')
        subject = (f'Address Codex audit findings on #{number}' if audit else
                   f'Fix lane FAIL on #{number}' if failing_head_report(pr) else 'Merge next and resolve conflicts')
        msg = run_dir / 'commit-msg.txt'
        msg.write_text(commit_message(f'{subject}\n\n{raw_msg.strip()}', number, pr['title']))
        stage_changes(ops, wt)
        check_staged_changes(ops, wt)
        ops.must(['git', 'commit', '--quiet', '-F', str(msg)], cwd=wt)
        fresh = ops.pull(number)
        if (fresh['state'] != 'OPEN' or fresh.get('isDraft') or fresh['baseRefName'] != BASE_BRANCH
                or fresh['headRefOid'] != head or fresh['headRefName'] != branch):
            raise RuntimeError('PR changed during finishing; no push')
        if 'automerge' in label_names(fresh):
            raise RuntimeError('PR was re-armed during finishing; no push')
        request = finish_lane_request(fresh.get('comments') or [])
        # No force options, no ref rewrite. A concurrent author's push makes this fail normally.
        ops.must(['git', 'push', '--quiet', 'origin', f'HEAD:refs/heads/{branch}'], cwd=wt, timeout=600)
        summary = (out / 'pr-body.md').read_text(errors='replace').strip()
        ops.comment(number, f'Thread "Codex worker {slot}" finished #{number}.\n\n{summary}\n\n'
                    'Wrapper --plan fast passed. No simulator or device check.')
        ops.label(number, remove='needs-mac')
        # Queue T3 before arming so an automerge run sees the pending request immediately.
        if request:
            ops.comment(number, request)
            ops.label(number, add='lane:queued')
        ops.label(number, add='automerge')
        return 'finished'
    except Exception as exc:
        ops.log(f'PR #{number} slot {slot}: wrapper error: {exc}')
        if claimed:
            stop(f'wrapper error: {exc}')
        return 'error'
    finally:
        if wt_added:
            ops.run(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
        try:
            info = json.loads(lock.read_text())
            if int(info.get('pid', -1)) in (os.getpid(), -1) or not ops.alive(int(info['pid'])):
                lock.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            pass


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--dry-run', action='store_true', help='print the decision; change nothing')
    ap.add_argument('--slot', type=int, help='(child) slot number')
    ap.add_argument('--issue', type=int, help='(child) issue number')
    ap.add_argument('--pr', type=int, help='(child) PR to finish')
    args = ap.parse_args(argv)
    ops = Ops()

    if args.slot is not None or args.issue is not None or args.pr is not None:
        if args.slot is None or (args.issue is None) == (args.pr is None):
            ap.error('--slot needs exactly one of --issue or --pr')
        if args.pr is not None:
            run_finish_child(ops, args.slot, args.pr)
        else:
            run_child(ops, args.slot, args.issue)
        return 0

    if args.dry_run:
        tick(ops, dry_run=True)
        return 0

    ops.home.mkdir(parents=True, exist_ok=True)
    lock_fh = open(ops.home / 'tick.lock', 'w')
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        ops.log('skipped: another tick holds the lock')
        return 0
    try:
        tick(ops)
    except Exception as exc:
        ops.log(f'tick error: {exc}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
