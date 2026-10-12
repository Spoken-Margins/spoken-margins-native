#!/usr/bin/env python3
"""Measured Claude usage from the Mac's own Claude Code transcripts. Read-only on the
transcripts; stdlib only, Python 3.9+.

Sources, checked on the Mac on 2026-10-12 with Claude Code 2.1.288 (#899):
- Desktop sessions (entrypoint `claude-desktop`) write `~/.claude/projects/<cwd slug>/<session>.jsonl`,
  and `<session>/subagents/agent-*.jsonl` for each sub-agent. Scheduled tasks (the Mac tick, the
  integration run) are desktop sessions whose first prompt starts `<scheduled-task name="…">`.
- Headless `claude -p` runs write a transcript only without `--no-session-persistence`. The audit
  job passes that flag; its usage comes from its own row in usage.jsonl. A headless transcript whose
  session id a wrapper row already holds is skipped, so it is never counted twice.
- Project threads that run in the cloud leave nothing on the Mac. They are not measured here.

One row per turn: a prompt in the main transcript (owner message, scheduled fire, loop wake-up)
up to the next one. Sub-agent requests join the turn whose time window holds them.
"""
from __future__ import annotations

import argparse
import bisect
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import sys

import usage

PROJECTS = Path.home() / '.claude' / 'projects'
LEDGER = usage.DEFAULT_DIR / 'claude-usage.jsonl'
RAW_FIELDS = ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens')
SCHEDULED = re.compile(r'^\s*<scheduled-task name="([^"]+)"')
# Folders sessions are opened on by convention (AGENTS.md, test-lane.md); recorded as the job's source.
FOLDER_JOBS = {'spoken-margins-native-test-desk': 'testdesk', 'spoken-margins-native-finisher': 'finisher'}
POSTING = re.compile(r'\bgh\s+(?:pr|issue)\s+(?:create|comment)\b')
GITHUB_URL = re.compile(r'https://github\.com/[\w.-]+/[\w.-]+/(issues|pull)/(\d+)(?:#issuecomment-\d+)?')
INTERRUPTED = '[Request interrupted by user'


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))


def events(path: Path, errors: list):
    try:
        with path.open(errors='replace') as source:
            for number, line in enumerate(source, 1):
                try:
                    event = json.loads(line)
                except ValueError:
                    errors.append(f'{path}:{number}: unreadable line skipped')
                    continue
                if isinstance(event, dict):
                    yield event
    except OSError as error:
        errors.append(f'{path}: {error}')


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(part.get('text') or '' for part in content
                         if isinstance(part, dict) and part.get('type') == 'text')
    return ''


def tool_result_text(part: dict) -> str:
    content = part.get('content')
    return content if isinstance(content, str) else text_of(content)


def is_prompt(event: dict) -> bool:
    """A new turn. Claude Code 2.1.28x stamps each one with `turnPosition`: owner messages, scheduled
    and loop fires, task notifications. Skill text, compaction summaries and tool results that follow
    carry the turn's `promptId` but no position. Older transcripts have neither; there a turn is a
    non-meta text message."""
    if event.get('type') != 'user' or event.get('isCompactSummary'):
        return False
    content = (event.get('message') or {}).get('content')
    if isinstance(content, list) and any(isinstance(p, dict) and p.get('type') == 'tool_result' for p in content):
        return False
    if 'turnPosition' in event or 'promptId' in event:
        return 'turnPosition' in event
    text = text_of(content)
    return not event.get('isMeta') and bool(text.strip()) and not text.startswith(INTERRUPTED)


class Session:
    """One main transcript plus its sub-agents, split into turns."""

    def __init__(self, main: Path, subagents: list, errors: list):
        self.id, self.errors, self.folder = main.stem, errors, main.parent.name
        self.entrypoint = self.cwd = self.first_prompt = None
        self.turns = []        # dicts, in order
        self.requests = {}     # (requestId, message id) -> request
        self.commands = {}     # tool_use id -> command
        self.client, self.client_final = None, False  # Claude Code's own running total (cost-state)
        self.read(main, sidechain=False)
        self.starts = [turn['time'] or '' for turn in self.turns]
        for path in subagents:
            self.read(path, sidechain=True)

    def turn_at(self, when: str):
        index = bisect.bisect_right(self.starts, when) - 1
        return self.turns[index] if index >= 0 else None

    def new_turn(self, event: dict) -> dict:
        turn = {'time': event.get('timestamp'), 'keys': [], 'compactions': 0, 'retries': 0,
                'api_failed': False, 'interrupted': False, 'last_stop': None, 'links': set()}
        self.turns.append(turn)
        return turn

    def read(self, path: Path, sidechain: bool) -> None:
        turn = None
        for event in events(path, self.errors):
            kind = event.get('type')
            if kind == 'cost-state' and not sidechain:
                self.client, self.client_final = event, True
                continue
            if not sidechain:
                self.entrypoint = self.entrypoint or event.get('entrypoint')
                self.cwd = self.cwd or event.get('cwd')
                if is_prompt(event):
                    self.first_prompt = self.first_prompt or text_of(event['message']['content'])
                    turn = self.new_turn(event)
                    continue
            elif event.get('timestamp'):
                # A sub-agent request stamped before the first prompt still belongs to the session.
                turn = self.turn_at(event['timestamp']) or (self.turns[0] if self.turns else None)
            if turn is None:
                if kind == 'assistant' and not sidechain:
                    turn = self.new_turn(event)  # usage before any prompt still counts
                else:
                    continue
            if kind == 'system' and not sidechain:
                if event.get('subtype') == 'compact_boundary':
                    turn['compactions'] += 1
                elif event.get('subtype') == 'api_error':
                    turn['retries'] += 1
            elif kind == 'user':
                content = (event.get('message') or {}).get('content')
                if INTERRUPTED in text_of(content) and not sidechain:
                    turn['interrupted'] = True
                for part in content if isinstance(content, list) else []:
                    if isinstance(part, dict) and part.get('type') == 'tool_result' and POSTING.search(self.commands.get(part.get('tool_use_id'), '')):
                        for match in GITHUB_URL.finditer(tool_result_text(part)):
                            turn['links'].add(match.group(0))
            elif kind == 'assistant':
                self.assistant(event, turn, sidechain)

    def assistant(self, event: dict, turn: dict, sidechain: bool) -> None:
        message = event.get('message') or {}
        for part in message.get('content') or []:
            if isinstance(part, dict) and part.get('type') == 'tool_use':
                command = (part.get('input') or {}).get('command')
                if isinstance(command, str):
                    self.commands[part.get('id')] = command
        if message.get('model') == '<synthetic>':
            # Written by Claude Code, not the API: no usage. An API failure that ended the turn.
            if not sidechain and (event.get('isApiErrorMessage') or text_of(message.get('content')).startswith('API Error')):
                turn['api_failed'] = True
            return
        values = message.get('usage')
        if not isinstance(values, dict):
            return
        key = (event.get('requestId'), message.get('id'))
        if key == (None, None):
            key = ('line', event.get('uuid'))
        previous = self.requests.get(key)
        # Each content block repeats the request's usage; a streamed block can carry a partial
        # output count. Keep one entry per request, with the largest output count.
        if previous is None:
            turn['keys'].append(key)
        elif not (isinstance(values.get('output_tokens'), int) and
                  values['output_tokens'] > (previous['usage'].get('output_tokens') or 0)):
            values = previous['usage']
        self.requests[key] = {'usage': values, 'model': message.get('model'), 'sidechain': sidechain}
        if not sidechain:
            turn['last_stop'] = message.get('stop_reason')
            self.client_final = False

    def job(self) -> tuple:
        scheduled = SCHEDULED.match(self.first_prompt or '')
        if scheduled:
            return 'scheduled:' + scheduled.group(1), 'scheduled-task tag in the first prompt'
        if (self.entrypoint or '').startswith('sdk'):
            return 'headless', 'entrypoint ' + self.entrypoint
        # The transcript folder is named after the folder the session was opened on; cwd can move later.
        for name, job in FOLDER_JOBS.items():
            if self.folder.endswith('-' + name) or Path(self.cwd or '').name == name:
                return job, 'session folder ' + name
        return 'desktop-other', 'no scheduled tag or known folder'

    def rows(self) -> list:
        job, job_source = self.job()
        project = 'spoken-margins' if re.search(r'spoken-margins|SpokenMarginsOps', self.cwd or '') else 'other'
        rows = []
        for index, turn in enumerate(self.turns):
            raw = dict.fromkeys(RAW_FIELDS, 0)
            raw.update(cache_creation_5m_input_tokens=0, cache_creation_1h_input_tokens=0)
            missing, models, subagent_requests = set(), {}, 0
            for key in turn['keys']:
                request = self.requests[key]
                values = request['usage']
                models[request['model']] = models.get(request['model'], 0) + 1
                subagent_requests += request['sidechain']
                for field in RAW_FIELDS:
                    value = values.get(field)
                    if type(value) is int and value >= 0:
                        raw[field] += value
                    else:
                        missing.add(field)
                split = values.get('cache_creation') if isinstance(values.get('cache_creation'), dict) else {}
                raw['cache_creation_5m_input_tokens'] += split.get('ephemeral_5m_input_tokens') or 0
                raw['cache_creation_1h_input_tokens'] += split.get('ephemeral_1h_input_tokens') or 0
            # A turn can end on a tool call (a project thread's terminal reply tool), so a later
            # prompt in the same session also closes it. Only the session's last turn can be open:
            # still running, or stopped with no final answer.
            ended = (turn['last_stop'] in ('end_turn', 'stop_sequence') or not turn['keys']
                     or index + 1 < len(self.turns))
            outcome = ('interrupted' if turn['interrupted'] else 'failed' if turn['api_failed'] else
                       'completed' if ended else 'unfinished')
            reasons = []
            if missing:
                reasons.append('usage fields missing/invalid: ' + ', '.join(sorted(missing)))
            if turn['compactions']:
                reasons.append(f"{turn['compactions']} compaction call(s); their usage is not in the transcript")
            if outcome != 'completed':
                reasons.append(f'turn {outcome}; counts cover the requests that were written')
            counted = {
                # As in usage.read_usage: input is the three input counts added; cached input is the cache read.
                'input_tokens': None if missing & {'input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'}
                else raw['input_tokens'] + raw['cache_creation_input_tokens'] + raw['cache_read_input_tokens'],
                'cached_input_tokens': None if 'cache_read_input_tokens' in missing else raw['cache_read_input_tokens'],
                'output_tokens': None if 'output_tokens' in missing else raw['output_tokens']}
            links = sorted(turn['links'])
            targets = sorted({(m.group(1), int(m.group(2))) for m in map(GITHUB_URL.match, links)})
            rows.append(dict(
                schema_version=1, kind='turn', provider='anthropic', source='claude-transcript',
                run_id=f'claude:{self.id}:{index}', session_id=self.id, turn=index, time=turn['time'],
                job=job, job_source=job_source, project=project, entrypoint=self.entrypoint, cwd=self.cwd,
                models=models, requests=len(turn['keys']), subagent_requests=subagent_requests,
                api_retries=turn['retries'], compactions=turn['compactions'], raw_usage=raw, **counted,
                usage_complete=not reasons, usage_missing_reason='; '.join(reasons) or None,
                outcome={'kind': outcome}, outcome_links=links,
                targets=[{'pr' if kind == 'pull' else 'issue': number} for kind, number in targets],
                attribution_missing_reason=None if targets else 'no comment or PR posted by gh in this turn'))
        return rows

    def check(self) -> dict:
        """The session's transcript totals beside Claude Code's own running total (its last
        `cost-state` line). Claude Code also counts calls it doesn't write to the transcript (title and
        side queries, compaction), so the transcript share of its total is the measured coverage."""
        transcript = dict.fromkeys(RAW_FIELDS, 0)
        for request in self.requests.values():
            for field in RAW_FIELDS:
                value = request['usage'].get(field)
                transcript[field] += value if type(value) is int and value >= 0 else 0
        client = None
        if self.client and isinstance(self.client.get('modelUsage'), dict):
            names = {'input_tokens': 'inputTokens', 'cache_creation_input_tokens': 'cacheCreationInputTokens',
                     'cache_read_input_tokens': 'cacheReadInputTokens', 'output_tokens': 'outputTokens'}
            models = self.client['modelUsage']
            client = {field: sum(int((m or {}).get(name) or 0) for m in models.values())
                      for field, name in names.items()}
            client['models'] = sorted(models)
        job, _ = self.job()
        return dict(schema_version=1, kind='session-check', provider='anthropic', source='claude-transcript',
                    run_id=f'claude-session:{self.id}', session_id=self.id, job=job,
                    time=self.turns[-1]['time'] if self.turns else None,
                    transcript=transcript, transcript_models=sorted({r['model'] for r in self.requests.values()
                                                                     if r['model']}),
                    client_reported=client,
                    # A request written after Claude Code's last running total isn't in it yet.
                    # Sub-agent files carry no such marker, so their late requests can't be told apart.
                    client_total_is_final=bool(client) and self.client_final)


def tokens(values: dict) -> int:
    """Input (all three input counts) plus output, the ledger's token convention."""
    return sum(values[field] for field in RAW_FIELDS)


def coverage(rows: list) -> dict:
    """How much of Claude Code's own total the transcripts hold, over sessions where it is final."""
    checks = [row for row in rows if row.get('kind') == 'session-check']
    final = [row for row in checks if row.get('client_total_is_final')]
    written = sum(tokens(row['transcript']) for row in final)
    reported = sum(tokens(row['client_reported']) for row in final)
    return {'sessions': len(checks), 'sessions_compared': len(final),
            'transcript_tokens': written, 'client_reported_tokens': reported,
            'transcript_share': round(written / reported, 4) if reported else None,
            'client_only_models': sorted({model_name(m) for row in final for m in row['client_reported']['models']}
                                         - {model_name(m) for row in final for m in row['transcript_models']})}


def model_name(value: str) -> str:
    return re.sub(r'\[[^\]]*\]$', '', value)  # Claude Code's total names the 1M variant `<model>[1m]`


def wrapper_sessions(ledger: Path) -> set:
    """Session ids that wrapper rows (usage.jsonl) already count."""
    found = set()
    if ledger.exists():
        with ledger.open(errors='replace') as source:
            for line in source:
                try:
                    found.update(json.loads(line).get('session_ids') or [])
                except (ValueError, AttributeError):
                    continue
    return found


def collect(projects: Path = PROJECTS, since: dt.datetime | None = None,
            wrapped: set = frozenset(), errors: list | None = None) -> list:
    """Rows for every session touched since `since`. A bad file is reported in `errors`, never raised."""
    errors = [] if errors is None else errors
    cutoff = since.timestamp() if since else 0
    rows = []
    for main in sorted(projects.glob('*/*.jsonl')):
        try:
            subagents = sorted((main.parent / main.stem / 'subagents').glob('*.jsonl'))
            if max([main.stat().st_mtime] + [p.stat().st_mtime for p in subagents]) < cutoff:
                continue
            session = Session(main, subagents, errors)
            if session.id in wrapped:
                continue
            turns = [row for row in session.rows()
                     if not since or row['time'] and parse_time(row['time']) >= since]
            rows.extend(turns + [session.check()] if turns else [])
        except Exception as error:  # one bad session never stops the rest
            errors.append(f'{main}: {type(error).__name__}: {error}')
    return rows


def store(path: Path, rows: list) -> None:
    """Merge rows into the ledger by run_id; a turn still running is replaced on the next pass."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with (path.parent / (path.name + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        merged = {}
        if path.exists():
            with path.open(errors='replace') as source:
                for line in source:
                    try:
                        row = json.loads(line)
                        merged[row['run_id']] = row
                    except (ValueError, KeyError, TypeError):
                        continue
        merged.update((row['run_id'], row) for row in rows)
        temporary = path.with_suffix('.tmp')
        with temporary.open('w') as target:
            for row in sorted(merged.values(), key=lambda r: (r.get('time') or '', r['run_id'])):
                target.write(json.dumps(row, ensure_ascii=False) + '\n')
            target.flush()
            os.fsync(target.fileno())
        temporary.replace(path)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--since', help='Only turns started on or after this date (YYYY-MM-DD, UTC)')
    parser.add_argument('--projects', type=Path, default=PROJECTS)
    parser.add_argument('--ledger', type=Path, default=LEDGER)
    parser.add_argument('--wrapper-ledger', type=Path, default=usage.DEFAULT_DIR / 'usage.jsonl')
    parser.add_argument('--dry-run', action='store_true', help='Print a summary; write nothing')
    args = parser.parse_args(argv)
    since = dt.datetime.fromisoformat(args.since).replace(tzinfo=dt.timezone.utc) if args.since else None
    errors = []
    rows = collect(args.projects, since, wrapper_sessions(args.wrapper_ledger), errors)
    for error in errors:
        print('claude usage: ' + error, file=sys.stderr)
    turns = [row for row in rows if row['kind'] == 'turn']
    jobs = {}
    for row in turns:
        jobs.setdefault(row['job'], []).append(row)
    print(json.dumps({'turns': len(turns), 'sessions': len({r['session_id'] for r in turns}),
                      'unreadable': len(errors), 'coverage': coverage(rows), 'by_job': {
                          job: {'turns': len(group), 'incomplete': sum(not r['usage_complete'] for r in group)}
                          for job, group in sorted(jobs.items())}}, indent=2))
    if not args.dry_run:
        try:
            store(args.ledger, rows)
        except OSError as error:
            print(f'claude usage: could not write {args.ledger}: {error}', file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
