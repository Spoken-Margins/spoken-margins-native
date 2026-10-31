#!/usr/bin/env python3
"""Enforce AGENTS.md's 250k hand-off line in Spoken Margins sessions (owner, 2026-10-09).

Why: in the week to 2026-10-09, 19 of 315 local sessions ran past 250k tokens of context and
held 75% of all Claude cache reads; one ran 3,745 turns, another nine days. The rule was written
down but nothing enforced it.

- PostToolUse, context >= 250k: tell the session (once, then every further 20k) to finish the push
  it is on (current PR open and armed), post its stop note, and end. It never stops mid-PR here.
- PreToolUse, context >= 300k: the backstop. Deny every tool except reading, git commands that
  save work (status, diff, log, add, commit, push) and posting a comment with gh, so the session
  can still save its work and write its stop note. Opening the PR and arming it stay allowed.

Owner-started sessions get more room (owner, 2026-10-17): "for the sessions that I spin up, I would
like the general priority to be getting things done." An Opus session he started hit the 300k
backstop overnight and about 9% of the weekly allowance expired unused at the reset. A session is
automatic when it is headless (sdk entrypoint) or its first message is a scheduled task, a project
thread wake, or a brief from the session that started it; automatic sessions keep 250k/300k.
Everything else is the owner's: nudge at 400k, backstop at 500k.

At the backstop, handing work on stays allowed too: starting or handing off to a fresh session,
messaging a session, the task list, and editing memory files, so a full session passes its queue
on instead of leaving it idle.

Per-session state files (the nudge position and the session kind) are pruned (#2750): a file untouched for
STATE_MAX_AGE_DAYS belongs to a session that ended, so it goes, at most once a day and only when the hook writes state.

Context = input + cache-read + cache-creation tokens of the latest assistant turn in the transcript.
Only acts when the session works in the spoken-margins-native repo or one of its worktrees.
"""
import json
import os
import re
import sys
import time

REPO_MARK = 'spoken-margins-native'
LIMITS = {'automatic': (250_000, 300_000), 'owner': (400_000, 500_000)}  # (nudge, backstop)
NUDGE_EVERY = 20_000
STATE_MAX_AGE_DAYS = 7
PRUNE_MARKER = '.pruned'
STATE_DIR = os.path.expanduser('~/.claude/hooks/state/context-handoff')
ALLOWED_AT_HARD = ('Read', 'Grep', 'Glob', 'ToolSearch', 'SendMessage',
                   'mcp__ccd_session__start_session', 'mcp__ccd_session__hand_off_to_session',
                   'mcp__ccd_turn__update_plan', 'mcp__ccd_turn__wrap_up')
MEMORY_DIR = os.path.expanduser('~/.claude/projects/')
AUTOMATIC_OPENERS = ('<scheduled-task', '<wake reason=', 'Background (from the session',
                     'Task (from the session')
ALLOWED_BASH = re.compile(
    r'^\s*(git\s+(status|diff|log|add|commit|push)\b|gh\s+(issue|pr)\s+comment\b|gh\s+pr\s+create\b'
    r'|/Users/colemiller/\.claude/bin/sm-gh\s+automerge\b)')


def bash_allowed(command):
    # Every part of a chained command must be allowed; a heredoc body after the first line is data.
    first_line = command.strip().splitlines()[0] if command.strip() else ''
    parts = [p for p in re.split(r'&&|\|\||;', first_line) if p.strip()]
    return bool(parts) and all(ALLOWED_BASH.match(p) for p in parts)


def latest_context(transcript_path):
    try:
        with open(transcript_path, 'rb') as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 400_000))
            lines = f.read().decode('utf-8', 'replace').splitlines()
    except OSError:
        return 0
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get('type') != 'assistant' or entry.get('isSidechain'):
            continue
        usage = (entry.get('message') or {}).get('usage')
        if usage:
            return (usage.get('input_tokens', 0) + usage.get('cache_read_input_tokens', 0)
                    + usage.get('cache_creation_input_tokens', 0))
    return 0


def classify(transcript_path):
    # The first real user message says who started the session; headless runs are automatic.
    try:
        with open(transcript_path, encoding='utf-8', errors='replace') as f:
            for n, line in enumerate(f):
                if n > 400:
                    break
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if (entry.get('entrypoint') or '').startswith('sdk'):
                    return 'automatic'
                if entry.get('type') != 'user' or entry.get('isMeta'):
                    continue
                content = (entry.get('message') or {}).get('content')
                if isinstance(content, list):
                    content = next((c.get('text') for c in content
                                    if isinstance(c, dict) and c.get('type') == 'text'), None)
                if not isinstance(content, str):
                    continue
                text = re.sub(r'(?s)<system-reminder>.*?</system-reminder>', '', content).strip()
                if not text:
                    continue
                return 'automatic' if text.startswith(AUTOMATIC_OPENERS) else 'owner'
    except OSError:
        pass
    return 'automatic'


def prune_state(state_dir, now=None, max_age_days=STATE_MAX_AGE_DAYS):
    """Remove state files older than `max_age_days`, at most once a day. Returns how many it removed.

    Best effort: the hook must never fail because of housekeeping. Dot files (the throttle marker) and anything
    that is not a plain file are left alone."""
    now = time.time() if now is None else now
    marker = os.path.join(state_dir, PRUNE_MARKER)
    removed = 0
    try:
        if now - os.path.getmtime(marker) < 24 * 3600:
            return 0
    except OSError:
        pass
    try:
        for name in os.listdir(state_dir):
            path = os.path.join(state_dir, name)
            if name.startswith('.') or not os.path.isfile(path) or os.path.islink(path):
                continue
            try:
                if now - os.path.getmtime(path) > max_age_days * 24 * 3600:
                    os.remove(path)
                    removed += 1
            except OSError:
                continue
        with open(marker, 'w') as f:
            f.write(str(int(now)))
    except OSError:
        pass
    return removed


def ensure_state_dir():
    os.makedirs(STATE_DIR, exist_ok=True)
    prune_state(STATE_DIR)


def session_kind(event):
    ensure_state_dir()
    path = os.path.join(STATE_DIR, 'kind-' + re.sub(r'[^A-Za-z0-9_-]', '_', event.get('session_id') or 'unknown'))
    try:
        kind = open(path).read().strip()
        if kind in LIMITS:
            return kind
    except OSError:
        pass
    kind = classify(event.get('transcript_path') or '')
    with open(path, 'w') as f:
        f.write(kind)
    return kind


def memory_edit(tool, tool_input):
    path = os.path.abspath(tool_input.get('file_path') or '')
    return tool in ('Edit', 'Write') and path.startswith(MEMORY_DIR) and '/memory/' in path


def in_repo(event):
    places = [event.get('cwd') or '', os.environ.get('CLAUDE_PROJECT_DIR') or '',
              event.get('transcript_path') or '']
    return any(REPO_MARK in p for p in places)


def nudge_due(session_id, context):
    ensure_state_dir()
    path = os.path.join(STATE_DIR, re.sub(r'[^A-Za-z0-9_-]', '_', session_id or 'unknown'))
    try:
        last = int(open(path).read().strip() or 0)
    except (OSError, ValueError):
        last = 0
    if last and context < last + NUDGE_EVERY:
        return False
    with open(path, 'w') as f:
        f.write(str(context))
    return True


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    if not in_repo(event):
        return 0
    context = latest_context(event.get('transcript_path') or '')
    k = context // 1000
    name = event.get('hook_event_name')
    kind = session_kind(event) if context >= LIMITS['automatic'][0] else 'automatic'
    nudge_at, hard_at = LIMITS[kind]

    if name == 'PreToolUse' and context >= hard_at:
        tool = event.get('tool_name') or ''
        tool_input = event.get('tool_input') or {}
        command = tool_input.get('command') or ''
        if (tool in ALLOWED_AT_HARD or (tool == 'Bash' and bash_allowed(command))
                or memory_edit(tool, tool_input)):
            return 0
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': (
                f'Context is {k}k, past the {hard_at // 1000}k backstop for {kind} sessions (AGENTS.md '
                'hand-off rule). Allowed now: saving work (git status/diff/log/add/commit/push), opening '
                'or arming the PR (gh pr create, sm-gh automerge), posting a comment (gh issue|pr '
                'comment), editing memory files, and handing work on (start_session, '
                'hand_off_to_session, SendMessage, the task list). Commit and push what you have, '
                'start a fresh session with a full brief for every task still open so nothing sits '
                'idle, post your stop note, then end.'),
        }}))
        return 0

    if name == 'PostToolUse' and context >= nudge_at and nudge_due(event.get('session_id'), context):
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': (
                f'Context is {k}k, past the {nudge_at // 1000}k hand-off line for {kind} sessions in '
                'AGENTS.md. Finish the push you are on: get the current PR open and armed (do not '
                'stop mid-PR, do not start another issue). Hand every remaining task to a fresh '
                'session with a full brief (start_session), post your stop note, then end. At '
                f'{hard_at // 1000}k only saving work, comments and hand-offs will be allowed.'),
        }}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
