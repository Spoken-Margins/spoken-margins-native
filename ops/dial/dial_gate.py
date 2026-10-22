#!/usr/bin/env python3
"""Dial gate (#589): decide, at no Claude cost, whether to wake the Spoken Margins project.

Runs on the VPS every 15 minutes (systemd timer). It reads Cole's tick boxes on the Dial
issue, the latest Claude usage the Mac tick posted on #337, the ready queue, and the
threads' fixed-format claim and stop notes. Only when work is allowed and a thread slot is
open (or the 3-hour fallback is due) does it POST
to the "Dial relay" routine's /fire endpoint; that routine posts into the project
conversation, which wakes the coordinator (verified 2026-09-30 in a test project).

Safety rules (owner, 2026-10-01):
- Every slip fails toward spending less: two ticks in a group take the more cautious one;
  an empty or muddled Mode reads Off.
- Paced mode needs a usage reading under 3 hours old; with the Mac offline it doesn't fire.
- At most one fire outstanding: no new fire until a thread claims an issue after the last
  one (or 3 hours pass), so fires can't pile up while the plan limit is hit.
- Slots are per provider (owner, 2026-10-14): the Threads box is Claude's slot count and the
  Codex workers box is Codex's. The Codex worker (deleted, #1853) left the same
  claim and stop notes under the title `Codex worker N`; the gate counts those against Codex,
  never against the Threads box, and its fire payload states Claude's number and Claude's count.
- Active threads (owner, 2026-10-01): a thread is active from its claim note until its stop
  note, or until it shows nothing on GitHub for 2 hours (a crashed thread leaves no note).
  If threads skip stop notes the gate under-fires; the 2-hour limit and the 3-hour fallback
  wake-up bound that.
- Machines never edit the issue body. The gate keeps one status comment, edited in place.

Stdlib only, Python 3.9+. `--dry-run` prints the decision and writes nothing.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = os.environ.get('SM_DIAL_REPO', 'Spoken-Margins/spoken-margins-native')
DIAL_ISSUE = int(os.environ.get('SM_DIAL_ISSUE', '589'))
STATUS_ISSUE = int(os.environ.get('SM_DIAL_STATUS_ISSUE', '337'))
CONFIG_DIR = Path(os.environ.get('SM_DIAL_CONFIG', '/etc/sm-dial'))
STATE_FILE = Path(os.environ.get('SM_DIAL_STATE', '/var/lib/sm-dial/state.json'))

MARGIN = 3                      # points below the stop line where new work holds
TREND_SLACK = 10                # Paced may run this many points ahead of the trend line (owner 2026-10-19)
RESET_WEEKDAY = int(os.environ.get('SM_DIAL_RESET_WEEKDAY', '5'))   # Saturday (Mon=0)
RESET_HOUR_UTC = int(os.environ.get('SM_DIAL_RESET_HOUR', '11'))    # 07:00 EDT
FINISH_BY = {'reset': 0, 'fri noon': 19, 'fri 7': 24}             # hours before the reset
USAGE_MAX_AGE = dt.timedelta(hours=3)
MIN_SPACING = dt.timedelta(minutes=15)   # between wake-ups
FALLBACK = dt.timedelta(hours=3)         # wake-up even when every slot looks full
THREAD_QUIET = dt.timedelta(hours=2)     # no stop note and nothing on GitHub: count it gone
THREAD_WINDOW = dt.timedelta(hours=24)   # how far back the gate reads claim and stop notes
QUIET_SHOWN = dt.timedelta(hours=6)      # the status comment lists stopped/quiet threads this long
ACK_TIMEOUT = dt.timedelta(hours=3)
STATUS_REFRESH = dt.timedelta(minutes=60)

# Whose comments the gate believes (#1822). This file is deployed alone, so the rule of scripts/comment_trust.py is
# copied here; test_dial_gate.py fails if the two drift. Anyone can comment once the repo is public: a stranger's
# "HALT" on #337 must not stop the project, and a stranger's claim note must not fill the Dial's slots.
TRUSTED_ASSOCIATIONS = ('OWNER', 'MEMBER', 'COLLABORATOR')
TRUSTED_BOTS = ('github-actions[bot]',)


def trusted(comment: dict) -> bool:
    return (comment.get('author_association') in TRUSTED_ASSOCIATIONS
            or (comment.get('user') or {}).get('login') in TRUSTED_BOTS)


STATUS_MARK = '<!-- dial-gate-status -->'
ACK_MARK = '<!-- dial-coordinator -->'
# The notes Cole put in the project instructions (2026-10-01). They must open the comment,
# so a quoted example inside other text doesn't count.
CLAIM_RE = re.compile(r'[*_\s]*Claimed by project thread "([^"]+)"')
STOP_RE = re.compile(r'[*_\s]*Thread "([^"]+)" stopping:\s*(.*)')

MODES = ('off', 'paced', 'cloud max')

# The Codex worker's notes used the title `Codex worker <slot>`; old notes on GitHub still carry it.
CODEX_TITLE_RE = re.compile(r'Codex worker \d+$', re.IGNORECASE)


def thread_provider(title: str) -> str:
    return 'codex' if CODEX_TITLE_RE.match(title.strip()) else 'claude'


# ---------- parsing (pure) ----------

def parse_dial(body: str) -> dict:
    """Read the tick boxes. Returns mode, threads, stop and a list of plain-word problems."""
    groups: dict[str, list[str]] = {}
    current = None
    for line in body.splitlines():
        heading = re.match(r'\s*\*\*(.+?)\*\*', line)
        if heading and not line.lstrip().startswith('-'):
            current = heading.group(1).strip().lower()
            groups.setdefault(current, [])
            continue
        if line.strip() == '---':
            current = None
            continue
        box = re.match(r'\s*[-*]\s*\[([ xX])\]\s*(.+)', line)
        if box and current and box.group(1).lower() == 'x':
            groups[current].append(box.group(2).strip().lower())

    problems = []
    mode_ticks = {m for m in MODES for t in groups.get('mode', []) if t.startswith(m)}
    if not mode_ticks:
        mode = 'off'
        problems.append('no Mode box is ticked, so it reads Off')
    elif 'off' in mode_ticks:
        mode = 'off'
        if len(mode_ticks) > 1:
            problems.append('Off and another Mode are both ticked, so it reads Off')
    elif mode_ticks == {'paced', 'cloud max'}:
        mode = 'paced'
        problems.append('Paced and Cloud max are both ticked, so it reads Paced (the cautious one)')
    else:
        mode = mode_ticks.pop()

    def numbers(group: str) -> list[int]:
        out = []
        for t in groups.get(group, []):
            m = re.match(r'(\d+)', t)
            if m:
                out.append(int(m.group(1)))
        return out

    threads_ticked = numbers('threads')
    threads = min(threads_ticked) if threads_ticked else 0
    if len(threads_ticked) > 1:
        problems.append(f'{len(threads_ticked)} Threads boxes are ticked, so it uses the lowest, {threads}')
    if not threads_ticked and mode != 'off':
        problems.append('no Threads box is ticked, so nothing new starts')

    stop_group = next((g for g in groups if g.startswith('stop line')), None)
    stops = numbers(stop_group) if stop_group else []
    stop = min(stops) if stops else None
    if len(stops) > 1:
        problems.append(f'{len(stops)} Stop line boxes are ticked, so it uses the lowest, {stop}%')
    if stop is None and mode == 'paced':
        problems.append('no Stop line box is ticked, so Paced starts nothing')
    refill_group = next((g for g in groups if g.startswith('refill when')), None)
    refills = []
    for t in groups.get(refill_group, []):
        if t.startswith('any'):
            refills.append(None)
        elif t.startswith('no '):
            refills.append(0)
        elif re.match(r'\d+', t):
            refills.append(int(re.match(r'\d+', t).group(0)))
    numeric = [r for r in refills if r is not None]
    refill_at = min(numeric) if numeric else None   # two ticks: the one that wakes less
    if len(refills) > 1:
        problems.append('two Refill when boxes are ticked, so it uses the one that wakes the project less')
    finish_group = next((g for g in groups if g.startswith('finish by')), None)
    early = [h for t in groups.get(finish_group, []) for key, h in FINISH_BY.items() if key in t]
    hours_early = min(early) if early else 0   # two ticks: the later deadline spends slower
    if len(early) > 1:
        problems.append('two Finish by boxes are ticked, so it uses the later one')
    return {'mode': mode, 'threads': threads, 'stop': stop, 'hours_early': hours_early,
            'refill_at': refill_at, 'problems': problems}


BREAKER_RE = re.compile(r'(HALT|RESUMED) \(usage breaker(?::\s*([A-Za-z, ]+?))?\)')
PROVIDERS = ('claude', 'codex')


def breaker_marks(text: str, scoped_only: bool = False) -> list[tuple[str, set[str]]]:
    """Breaker markers in a line, as (HALT|RESUMED, providers). `HALT (usage breaker: Codex)`
    covers Codex only; the older unscoped `HALT (usage breaker)` covers every provider."""
    marks = []
    for m in BREAKER_RE.finditer(text):
        if scoped_only and m.group(2) is None:
            continue
        named = {p.strip().lower() for p in (m.group(2) or '').split(',')} & set(PROVIDERS)
        marks.append((m.group(1), named or set(PROVIDERS)))
    return marks


def parse_usage(comments: list[dict]) -> dict:
    """Latest Claude weekly usage and the usage breaker from the Mac tick's comments on #337.

    The breaker is per provider (owner, 2026-10-09): a provider over its line halts only the
    work that runs on that provider. `halted` is the Claude state, the only one the Dial
    gate acts on; `halted_by` lists every halted provider. A marker opening a comment's first
    line (a Mac tick or a transition comment) sets or clears the providers it names, and an
    unscoped marker keeps its old meaning of all providers. A Mac tick's `advice for dispatch`
    line is read only for the scoped form, so an old-style tick can't hold the gate."""
    usage = None
    halted: set[str] = set()
    for c in filter(trusted, comments):  # oldest first
        body = c.get('body') or ''
        m = re.search(r'Claude (\d+)% used', body)
        if m:
            usage = {'percent': int(m.group(1)), 'at': parse_time(c['created_at'])}
        first = body.splitlines()[0] if body else ''
        is_tick = '(Mac tick' in first
        marks = []
        if is_tick or first.lstrip('*_ ').startswith(('HALT', 'RESUMED')):
            marks = breaker_marks(first)
        if is_tick:
            advice = re.search(r'advice for dispatch:\s*(.*)', body)
            if advice:
                marks += breaker_marks(advice.group(1), scoped_only=True)
        for kind, who in marks:
            halted = halted | who if kind == 'HALT' else halted - who
    return {'usage': usage, 'halted': 'claude' in halted, 'halted_by': sorted(halted)}


def parse_ack(comments: list[dict]) -> dict | None:
    """The coordinator's acknowledgement: `Ack fire-<id> · running N`."""
    for c in reversed(list(filter(trusted, comments))):
        body = c.get('body') or ''
        if ACK_MARK in body:
            fire = re.search(r'Ack (fire-[0-9TZ]+)', body)
            running = re.search(r'running (\d+)', body)
            return {
                'fire': fire.group(1) if fire else None,
                'running': int(running.group(1)) if running else None,
                'at': parse_time(c.get('updated_at') or c['created_at']),
                'id': c['id'],
            }
    return None


def issue_number(c: dict) -> int | None:
    m = re.search(r'/issues/(\d+)$', c.get('issue_url') or '')
    return int(m.group(1)) if m else None


def parse_threads(comments: list[dict], events: list[dict], now: dt.datetime) -> list[dict]:
    """Project threads from their claim and stop notes (repo-wide issue comments, oldest
    first) plus signs of life: a comment that names the thread in quotes, or a push to the
    `ws/<issue>-` branch of the issue it claimed last. Other comments on its issues don't
    count (the owner's phone checks land on many at once), nor do pushes for its earlier
    issues (their PRs are armed; the finisher may push there). Each thread: title, issues
    (claimed since its last stop note), claims (all claim times), last_seen, stop_text,
    state ('active', 'stopped' or 'quiet')."""
    threads: dict[str, dict] = {}
    comments = [c for c in comments if trusted(c)]
    for c in comments:
        body = c.get('body') or ''
        at = parse_time(c['created_at'])
        m = CLAIM_RE.match(body)
        if m:
            t = threads.setdefault(m.group(1), {'title': m.group(1), 'provider': thread_provider(m.group(1)),
                                                'issues': [], 'claims': [], 'runs': [], 'started': at,
                                                'stopped_at': None, 'stop_text': None})
            if t['stopped_at']:   # a new run under the same title
                t['runs'].append({'title': t['title'], 'started': t['started'], 'ended': t['stopped_at'],
                                  'how': 'stop note'})
                t.update(issues=[], started=at, stopped_at=None, stop_text=None)
            t['claims'].append(at)
            t['last_claim'] = at
            n = issue_number(c)
            if n is not None and n not in t['issues']:
                t['issues'].append(n)
            continue
        m = STOP_RE.match(body)
        if m and m.group(1) in threads:
            threads[m.group(1)].update(stopped_at=at, stop_text=m.group(2).strip().splitlines()[0][:80])

    for t in threads.values():
        named = f'"{t["title"]}"'
        seen = [t['last_claim']]
        seen += [parse_time(c['created_at']) for c in comments if named in (c.get('body') or '')]
        branch = f"refs/heads/ws/{t['issues'][-1]}-" if t['issues'] else None
        for e in events:
            ref = (e.get('payload') or {}).get('ref') or ''
            if branch and e.get('type') == 'PushEvent' and ref.startswith(branch):
                seen.append(parse_time(e['created_at']))
        t['last_seen'] = max(seen)
        if t['stopped_at']:
            t['state'] = 'stopped'
        elif now - t['last_seen'] > THREAD_QUIET:
            t['state'] = 'quiet'
        else:
            t['state'] = 'active'
    return sorted(threads.values(), key=lambda t: t['last_claim'])


def finished_runs(threads: list[dict], now: dt.datetime) -> list[dict]:
    """How long each finished thread run lasted, from its first claim to its stop note, or
    to its last sign of life if it went quiet. Used to tune the spacing (owner, 2026-10-01)."""
    threads = of_provider(threads)   # spacing is tuned on Claude's runs
    runs = [r for t in threads for r in t['runs']]
    for t in threads:
        if t['state'] == 'stopped':
            runs.append({'title': t['title'], 'started': t['started'], 'ended': t['stopped_at'], 'how': 'stop note'})
        elif t['state'] == 'quiet':
            runs.append({'title': t['title'], 'started': t['started'], 'ended': t['last_seen'], 'how': 'went quiet'})
    for r in runs:
        r['minutes'] = int((r['ended'] - r['started']).total_seconds() // 60)
    return sorted(runs, key=lambda r: r['ended'])


def of_provider(threads: list[dict], provider: str = 'claude') -> list[dict]:
    return [t for t in threads if t.get('provider', thread_provider(t['title'])) == provider]


def active_count(threads: list[dict], provider: str = 'claude') -> int:
    """Active threads of one provider. The Threads box is Claude's slot count, so the default
    leaves the Codex workers out; they are counted against the Codex workers box."""
    return sum(t['state'] == 'active' for t in of_provider(threads, provider))


def claims_since(threads: list[dict], when: dt.datetime, provider: str = 'claude') -> int:
    return sum(at >= when for t in of_provider(threads, provider) for at in t['claims'])


def parse_time(s: str) -> dt.datetime:
    return dt.datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def next_reset(now: dt.datetime) -> dt.datetime:
    days = (RESET_WEEKDAY - now.weekday()) % 7
    reset = (now + dt.timedelta(days=days)).replace(hour=RESET_HOUR_UTC, minute=0, second=0, microsecond=0)
    return reset if reset > now else reset + dt.timedelta(days=7)


def trend_line(now: dt.datetime, stop: int, hours_early: int) -> float:
    """Where weekly usage should be by now: 0% at the week's start, rising straight to the
    stop line at the finish-by time."""
    reset = next_reset(now)
    start = reset - dt.timedelta(days=7)
    finish = reset - dt.timedelta(hours=hours_early)
    share = (now - start) / (finish - start)
    return stop * max(0.0, min(1.0, share))


# ---------- decision (pure) ----------

def decide(now, dial, usage_info, ready_count, ack, state, active) -> dict:
    """Return {'fire': bool, 'why': str, 'hold': str|None}."""
    mode, threads, stop = dial['mode'], dial['threads'], dial['stop']
    if mode == 'off' or threads == 0:
        return {'fire': False, 'why': 'Off: nothing new starts.', 'hold': None}

    hold = None
    if mode == 'paced':
        u = usage_info['usage']
        if stop is None:
            return {'fire': False, 'why': 'Paced, but no stop line is ticked.', 'hold': None}
        if usage_info['halted']:
            hold = 'the Mac tick says HALT (usage breaker: Claude)'
        elif u is None:
            hold = 'no usage report from the Mac found'
        elif now - u['at'] > USAGE_MAX_AGE:
            hold = f"the Mac's usage report is {hours(now - u['at'])} old (Mac offline?), so Paced waits"
        elif u['percent'] >= stop - MARGIN:
            hold = f"usage {u['percent']}% has reached the hold line {stop - MARGIN}% (stop line {stop}% minus {MARGIN})"
        elif u['percent'] > trend_line(now, stop, dial.get('hours_early', 0)) + TREND_SLACK:
            line = trend_line(now, stop, dial.get('hours_early', 0))
            hold = (f"usage {u['percent']}% is more than {TREND_SLACK} points ahead of the trend "
                    f"({line:.0f}% by now), so Paced waits for the line to catch up")
        if hold:
            return {'fire': False, 'why': f'Holding: {hold}.', 'hold': hold}

    if ready_count == 0:
        return {'fire': False, 'why': 'Nothing in the ready queue.', 'hold': None}

    last_fire = state.get('last_fire')
    last_at = parse_time(state['last_fire_at']) if state.get('last_fire_at') else None
    if last_fire and (not ack or ack['fire'] != last_fire):
        if last_at and now - last_at < ACK_TIMEOUT:
            return {'fire': False, 'why': f'Waiting for the coordinator to acknowledge {last_fire} '
                                          f'(sent {hours(now - last_at)} ago).', 'hold': None}
    if last_at and now - last_at < MIN_SPACING:
        return {'fire': False, 'why': f'Last wake-up was {hours(now - last_at)} ago; '
                                      f'wake-ups are at least 15 min apart.', 'hold': None}
    refill_at = dial.get('refill_at')
    wake_at = threads - 1 if refill_at is None else min(refill_at, threads - 1)
    if active > wake_at:
        if last_at and now - last_at < FALLBACK:
            why = (f'{active} of {threads} threads are active, so no slot is open' if wake_at == threads - 1 else
                   f"{active} of {threads} threads are active; the Dial wakes the project at "
                   f"{wake_at} thread{'' if wake_at == 1 else 's'} left")
            return {'fire': False, 'why': f'{why}; a fallback wake-up comes 3 hours after the last one.', 'hold': None}
        return {'fire': True, 'why': f'{active} of {threads} threads look active, but the last wake-up '
                                     f'was 3 hours ago or more: fallback wake-up.', 'hold': None}
    return {'fire': True, 'why': f'Waking the project: {active} of {threads} threads are active.', 'hold': None}


def fire_text(fire_id: str, claude_slots: int, active: list[dict]) -> str:
    """The payload the Dial relay posts. It states Claude's slot number and Claude's active
    count; Codex workers have their own slots and are not in either number."""
    running = '; '.join(f'"{th["title"]}"' for th in active) or 'none'
    return (f'Dial {fire_id}: Cole\'s Dial (#{DIAL_ISSUE}) allows up to {claude_slots} Claude threads '
            f'(Codex workers have their own slots and are not counted). '
            f'{len(active)} Claude threads look active from their claim and stop notes ({running}). '
            f'Keep {claude_slots} Claude threads going from the ready queue.')


def hours(delta: dt.timedelta) -> str:
    minutes = int(delta.total_seconds() // 60)
    return f'{minutes} min' if minutes < 90 else f'{minutes / 60:.1f} h'


def status_text(now, dial, usage_info, ready_count, ack, state, decision, threads) -> str:
    eastern = dt.timezone(dt.timedelta(hours=-4))  # EDT; the gate only reports times
    t = lambda d: d.astimezone(eastern).strftime('%a %H:%M')
    u = usage_info['usage']
    lines = [STATUS_MARK, f"**Dial gate**, read {t(now)} (Eastern)", '']
    stop = f"stop line {dial['stop']}% (holds at {dial['stop'] - MARGIN}%)" if dial['stop'] else 'no stop line'
    refill = ('when any slot opens' if dial.get('refill_at') is None or dial['refill_at'] >= dial['threads'] - 1
              else f"at {dial['refill_at']} thread{'' if dial['refill_at'] == 1 else 's'} left")
    lines.append(f"- I read: **{dial['mode'].capitalize()}**, {dial['threads']} threads, refill {refill}, {stop}.")
    for p in dial['problems']:
        lines.append(f'- Note: {p}.')
    lines.append(f"- Usage: {u['percent']}% from the Mac at {t(u['at'])}." if u else '- Usage: no report from the Mac.')
    if dial['mode'] == 'paced' and dial['stop'] and u:
        line = trend_line(now, dial['stop'], dial.get('hours_early', 0))
        finish = next_reset(now) - dt.timedelta(hours=dial.get('hours_early', 0))
        gap = u['percent'] - line
        lines.append(f"- Trend: about {line:.0f}% by now, reaching {dial['stop']}% by {t(finish)}; "
                     f"usage is {abs(gap):.0f} points {'ahead' if gap >= 0 else 'behind'} "
                     f"(Paced holds if more than {TREND_SLACK} ahead).")
    if usage_info.get('halted_by'):
        mine = 'Claude' if usage_info['halted'] else 'not Claude'
        lines.append(f"- Usage breaker: {' and '.join(p.capitalize() for p in usage_info['halted_by'])} halted "
                     f"({mine}, so this gate {'holds' if usage_info['halted'] else 'is unaffected'}).")
    lines.append(f'- Ready issues: {ready_count}.')
    issues = lambda th: ', '.join(f'#{n}' for n in th['issues']) or 'no issue'
    codex = [th for th in of_provider(threads, 'codex') if th['state'] == 'active']
    threads = of_provider(threads)   # the Threads box counts Claude only
    active = [th for th in threads if th['state'] == 'active']
    lines.append(f"- Active threads: {len(active)} of {dial['threads']} (Claude)" + (':' if active else '.'))
    for th in active:
        lines.append(f"  - \"{th['title']}\" on {issues(th)}, last seen {t(th['last_seen'])}")
    if codex:
        lines.append(f"- Codex workers active: {len(codex)} (their own slots on the Dial, not counted above): " +
                     '; '.join(f"\"{th['title']}\" on {issues(th)}" for th in codex) + '.')
    recent = lambda th, at: now - at <= QUIET_SHOWN
    quiet = [th for th in threads if th['state'] == 'quiet' and recent(th, th['last_seen'])]
    if quiet:
        lines.append('- Gone quiet with no stop note (nothing on GitHub for 2 hours): ' + '; '.join(
            f"\"{th['title']}\" on {issues(th)}, last seen {t(th['last_seen'])}" for th in quiet) + '.')
    stopped = [th for th in threads if th['state'] == 'stopped' and recent(th, th['stopped_at'])]
    if stopped:
        lines.append('- Stopped: ' + '; '.join(
            f"\"{th['title']}\" at {t(th['stopped_at'])} ({th['stop_text']})" for th in stopped) + '.')
    if state.get('last_fire'):
        acked = 'acknowledged' if ack and ack['fire'] == state['last_fire'] else 'not acknowledged yet'
        if acked == 'acknowledged' and ack.get('via') == 'claims':
            n = ack['started']
            acked = f"acknowledged by {n} issue claim{'' if n == 1 else 's'} since"
        running = f", {ack['running']} running" if ack and ack['running'] is not None and acked == 'acknowledged' else ''
        lines.append(f"- Last wake-up: {t(parse_time(state['last_fire_at']))}, {acked}{running}.")
    runs = [r for r in finished_runs(threads, now) if now - r['ended'] <= dt.timedelta(hours=24)]
    # Only runs with a stop note have a real length; a quiet run's end is a guess.
    timed = sorted(r['minutes'] for r in runs if r['how'] == 'stop note')
    quiet = len(runs) - len(timed)
    if timed:
        mid = len(timed) // 2
        median = timed[mid] if len(timed) % 2 else (timed[mid - 1] + timed[mid]) / 2
        lines.append(f"- Thread runs ended in the last 24 h: {len(timed)} with a stop note, median {median:.0f} min, "
                     f"longest {timed[-1]} min" + (f"; {quiet} more went quiet (length unknown)." if quiet else '.'))
    elif quiet:
        lines.append(f'- Thread runs ended in the last 24 h: {quiet}, all went quiet with no stop note (length unknown).')
    lines.append(f"- Now: {decision['why']}")
    return '\n'.join(lines)


# ---------- I/O ----------

def gh(method: str, path: str, token: str, body: dict | None = None):
    req = urllib.request.Request(
        f'https://api.github.com/{path}', method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'sm-dial-gate'})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b'null')


def gh_pages(path: str, token: str, max_pages: int = 20) -> list:
    """GET every page of a list endpoint (follows the Link header)."""
    url, out = f'https://api.github.com/{path}', []
    for _ in range(max_pages):
        req = urllib.request.Request(url, headers={
            'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'sm-dial-gate'})
        with urllib.request.urlopen(req, timeout=30) as resp:
            out += json.loads(resp.read() or b'[]')
            nxt = re.search(r'<([^>]+)>;\s*rel="next"', resp.headers.get('Link') or '')
        if not nxt:
            break
        url = nxt.group(1)
    return out


def fire_relay(url: str, token: str, text: str) -> dict:
    req = urllib.request.Request(
        url, method='POST', data=json.dumps({'text': text}).encode(),
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json',
                 'anthropic-beta': 'experimental-cc-routine-2026-04-01',
                 'anthropic-version': '2023-06-01', 'User-Agent': 'sm-dial-gate'})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b'null')


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_FILE)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--dry-run', action='store_true', help='print the decision; write and fire nothing')
    args = ap.parse_args(argv)

    token = os.environ.get('SM_DIAL_GITHUB_TOKEN') or (CONFIG_DIR / 'github-token').read_text().strip()
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    state = load_state()

    dial_body = gh('GET', f'repos/{REPO}/issues/{DIAL_ISSUE}', token)['body'] or ''
    dial = parse_dial(dial_body)
    since = (now - dt.timedelta(hours=12)).strftime('%Y-%m-%dT%H:%M:%SZ')
    tick_comments = gh('GET', f'repos/{REPO}/issues/{STATUS_ISSUE}/comments?since={since}&per_page=100', token)
    usage_info = parse_usage(tick_comments)
    ready = gh('GET', f'search/issues?q=repo:{REPO}+is:issue+is:open+label:ready&per_page=1', token)['total_count']
    dial_comments = gh('GET', f'repos/{REPO}/issues/{DIAL_ISSUE}/comments?per_page=100', token)
    ack = parse_ack(dial_comments)
    # Newest first, then reversed: the repo gets over 2,000 comments a week (2026-10-01), so
    # an oldest-first read hit the page cap before the latest notes. A thread is quiet after
    # 2 hours without a sign of life, so 24 hours (inside the week) is plenty.
    since = max(next_reset(now) - dt.timedelta(days=7), now - THREAD_WINDOW).strftime('%Y-%m-%dT%H:%M:%SZ')
    all_comments = gh_pages(f'repos/{REPO}/issues/comments?since={since}&sort=created'
                            f'&direction=desc&per_page=100', token)[::-1]
    events = gh_pages(f'repos/{REPO}/events?per_page=100', token, max_pages=3)
    threads = parse_threads(all_comments, events, now)
    # The coordinator's own comment can be blocked by its permission check (seen
    # 2026-10-01), so a thread claiming an issue after the fire also counts as the
    # acknowledgement.
    if state.get('last_fire') and not (ack and ack['fire'] == state['last_fire']):
        claimed = claims_since(threads, parse_time(state['last_fire_at']))
        if claimed:
            ack = {'fire': state['last_fire'], 'running': None, 'started': claimed,
                   'at': now, 'id': None, 'via': 'claims'}

    active = [th for th in of_provider(threads) if th['state'] == 'active']   # Claude only
    decision = decide(now, dial, usage_info, ready, ack, state, len(active))

    if decision['fire'] and not args.dry_run:
        fire_id = 'fire-' + now.strftime('%Y%m%dT%H%MZ')
        text = fire_text(fire_id, dial['threads'], active)
        url = (CONFIG_DIR / 'relay-url').read_text().strip()
        try:
            fire_relay(url, (CONFIG_DIR / 'relay-token').read_text().strip(), text)
            state.update(last_fire=fire_id, last_fire_at=now.strftime('%Y-%m-%dT%H:%M:%SZ'))
        except urllib.error.URLError as e:
            decision = {**decision, 'fire': False, 'why': f'Tried to wake the project, but the relay failed ({e}).'}

    text = status_text(now, dial, usage_info, ready, ack, state, decision, threads)
    if args.dry_run:
        print(text)
        print(f"\n(dry run: fire={decision['fire']}; nothing written)")
        return 0

    # Edit the one status comment only when what it says changed, or hourly so its
    # "read at" time shows the gate is alive. Edits don't notify anyone.
    existing = next((c for c in dial_comments if STATUS_MARK in (c.get('body') or '') and trusted(c)), None)
    material = text.split('\n', 2)[2]  # everything after the "read at" line
    changed = material != state.get('status_material')
    stale = not state.get('status_at') or now - parse_time(state['status_at']) >= STATUS_REFRESH
    if existing is None:
        gh('POST', f'repos/{REPO}/issues/{DIAL_ISSUE}/comments', token, {'body': text})
    elif changed or stale:
        gh('PATCH', f"repos/{REPO}/issues/comments/{existing['id']}", token, {'body': text})
    if existing is None or changed or stale:
        state.update(status_material=material, status_at=now.strftime('%Y-%m-%dT%H:%M:%SZ'))
    save_state(state)
    return 0


if __name__ == '__main__':
    sys.exit(main())
