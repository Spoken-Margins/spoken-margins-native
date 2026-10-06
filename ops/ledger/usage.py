"""Local, best-effort Codex usage ledger. Stdlib only, Python 3.9+.

One row per invocation, including batches. A locked pending journal allows the
next wrapper/report to recover a wrapper killed before it could append its row.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid

DEFAULT_DIR = Path.home() / 'SpokenMarginsOps' / 'ledger'
TOKEN_FIELDS = ('input_tokens', 'cached_input_tokens', 'output_tokens')


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


def read_usage(transcript: Path) -> dict:
    totals = {field: 0 for field in TOKEN_FIELDS}
    missing = set()
    turns = completed = 0
    failed = False
    try:
        with transcript.open(errors='replace') as source:
            for line in source:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue  # stderr warnings can share the stream
                if not isinstance(event, dict):
                    continue
                if event.get('type') == 'turn.started':
                    turns += 1
                if event.get('type') in ('turn.failed', 'error'):
                    failed = True
                if event.get('type') != 'turn.completed':
                    continue
                completed += 1
                values = event.get('usage') or {}
                for field in TOKEN_FIELDS:
                    value = values.get(field) if isinstance(values, dict) else None
                    if type(value) is int and value >= 0:
                        totals[field] += value
                    else:
                        missing.add(field)
    except OSError as error:
        return dict.fromkeys(TOKEN_FIELDS, None) | {
            'usage_complete': False, 'usage_missing_reason': f'transcript unreadable: {error}'}
    if not completed:
        return dict.fromkeys(TOKEN_FIELDS, None) | {
            'usage_complete': False, 'usage_missing_reason': 'no turn.completed usage event'}
    for field in missing:
        totals[field] = None
    complete = not missing and not failed and completed >= turns
    reason = ('usage fields missing/invalid: ' + ', '.join(sorted(missing)) if missing else
              'unfinished/failed turn; counts cover completed turns only' if not complete else None)
    return dict(totals, usage_complete=complete, usage_missing_reason=reason)


def signature(text: str) -> str:
    """Stable whitespace/commit spelling for comparing the same reported result."""
    return re.sub(r'\s+', ' ', re.sub(r'\b[0-9a-f]{7,40}\b', '<sha>', text)).strip()


def audit_outcome(section: str) -> dict:
    clean = section.lstrip().lower().startswith('no blocking findings')
    if clean:
        return {'kind': 'no blocking findings', 'finding_count': 0, 'findings': [],
                'signature': 'no blocking findings'}
    # Finding headings are the evidence keys, not an estimated count of bullets.
    findings = []
    blocking_section = True
    for line in section.splitlines():
        label = line.strip().strip('#* -:').casefold()
        if re.fullmatch(r'(?:previously accepted(?: findings)?|'
                        r'(?:suspected|unconfirmed)(?: sibling cases| siblings| cases| findings)?|'
                        r'possible sibling cases)(?:\s*\([^)]*\))?', label):
            blocking_section = False
            continue
        if re.fullmatch(r'(?:blocking|confirmed)(?: findings| bugs)?', label):
            blocking_section = True
            continue
        if not blocking_section:
            continue
        heading = re.match(r'^\s*(?:(?:[-*]|\d+[.)]|#{1,6})\s+)?(\*\*)?\[P[0-3]\]\s*', line)
        if not heading:
            continue
        tail = line[heading.end():]
        location_pattern = r'`([^`\s:]+):\d+(?:[–-]\d+)?`'
        location = re.search(location_pattern, tail)
        if heading.group(1) and '**' in tail:
            end = tail.index('**')
            title, remainder = tail[:end], tail[end + 2:]
        elif location:
            title, remainder = tail[:location.start()], tail[location.start():]
        else:
            title, remainder = tail, ''
        title = re.sub(r'\s+—\s*$', '', title).strip(' .*')
        location = re.search(location_pattern, remainder)
        if title:
            findings.append({'title': title, 'file': location.group(1) if location else None})
    return {'kind': 'findings', 'finding_count': len(findings) or None,
            'findings': findings, 'signature': json.dumps(sorted((f['title'], f['file']) for f in findings))
            if findings and all(f['file'] for f in findings) else signature(section)}


def safe_log(log, message: str) -> None:
    try:
        log('usage ledger: ' + message)
    except Exception:
        print('usage ledger: ' + message, file=sys.stderr)


def git_sha(run, cwd: Path, ref: str, log=print):
    try:
        value = run(['git', 'rev-parse', ref], cwd=cwd).stdout.strip()
        return value if re.fullmatch(r'[a-f0-9]{40}', value) else None
    except Exception as error:
        safe_log(log, f'could not read {ref}: {error}')
        return None


def append(directory: Path, row: dict) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'usage.jsonl').open('a+b') as ledger:
        fcntl.flock(ledger, fcntl.LOCK_EX)
        # Recovery can follow a kill between append and pending-file removal.
        ledger.seek(0)
        while True:
            position = ledger.tell()
            line = ledger.readline()
            if not line:
                break
            try:
                if json.loads(line).get('run_id') == row['run_id']:
                    if not line.endswith(b'\n'):
                        ledger.write(b'\n')
                        ledger.flush()
                        os.fsync(ledger.fileno())
                    return
            except (ValueError, AttributeError):
                if not line.endswith(b'\n'):
                    # An interrupted append can leave a torn last line. Preserve
                    # it locally, then recover the complete row from its journal.
                    (directory / f'torn-{uuid.uuid4().hex}.txt').write_bytes(line)
                    ledger.truncate(position)
                    break
                continue
        ledger.seek(0, os.SEEK_END)
        ledger.write((json.dumps(row, ensure_ascii=False) + '\n').encode('utf-8'))
        ledger.flush()
        os.fsync(ledger.fileno())


def recover(directory: Path = DEFAULT_DIR, log=print) -> None:
    """Complete abandoned journals; a live wrapper's lock always wins."""
    try:
        pending = list((directory / 'pending').glob('*.json'))
    except Exception as error:
        safe_log(log, f'could not list pending runs: {error}')
        return
    for path in pending:
        try:
            lock_path = path.with_suffix('.lock')
            with lock_path.open('a+') as source:
                try:
                    fcntl.flock(source, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                row = json.loads(path.read_text())
                row.update(read_usage(Path(row['transcript'])))
                if not row.get('finished_at'):
                    row.update(finished_at=now(),
                               outcome={'kind': 'failed', 'reason': 'wrapper interrupted before finalization'})
                    if 'wall_time_seconds' not in row:
                        row.update(wall_time_seconds=None,
                                   wall_time_missing_reason='wrapper interrupted; end time unknown')
                append(directory, row)
                path.unlink()
                lock_path.unlink(missing_ok=True)
        except FileNotFoundError:
            pass  # another recoverer finished it
        except Exception as error:
            safe_log(log, f'could not recover {path}: {error}')


class Run:
    def __init__(self, directory: Path, job: str, model: str, effort: str,
                 transcript: Path, targets: list | None = None, log=print):
        self.directory, self.log = directory, log
        self.source = None
        self.start = time.monotonic()
        self.row = dict(schema_version=1, run_id=uuid.uuid4().hex, time=now(),
                        job=job, model=model, reasoning_effort=effort,
                        transcript=str(transcript.resolve()), targets=targets or [],
                        outcome={'kind': 'failed', 'reason': 'wrapper interrupted before finalization'},
                        comment_url=None, finished_at=None)
        self.path = directory / 'pending' / (self.row['run_id'] + '.json')
        try:
            recover(directory, log)
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.source = self.path.with_suffix('.lock').open('x+')
            fcntl.flock(self.source, fcntl.LOCK_EX)
            self.checkpoint()
        except Exception as error:
            safe_log(log, f'could not start record: {error}')

    def checkpoint(self, **values) -> None:
        self.row.update(values)
        if self.source:
            try:
                temporary = self.path.with_suffix('.tmp')
                with temporary.open('w') as journal:
                    json.dump(self.row, journal)
                    journal.flush()
                    os.fsync(journal.fileno())
                temporary.replace(self.path)
            except Exception as error:
                safe_log(self.log, f'could not checkpoint: {error}')

    def model_finished(self) -> None:
        self.checkpoint(wall_time_seconds=round(time.monotonic() - self.start, 3))

    def finish(self, outcome: dict | None = None, **values) -> None:
        self.row.update(read_usage(Path(self.row['transcript'])))
        if self.row.get('model_result', {}).get('ok') is False:
            outcome = {'kind': 'failed', 'reason': self.row['model_result']['reason'],
                       'wrapper_outcome': outcome or self.row['outcome']}
        self.row.setdefault('wall_time_seconds', round(time.monotonic() - self.start, 3))
        self.checkpoint(finished_at=now(), outcome=outcome or self.row['outcome'], **values)
        try:
            append(self.directory, self.row)
            if self.source:
                self.path.unlink(missing_ok=True)
                self.path.with_suffix('.lock').unlink(missing_ok=True)
        except Exception as error:
            safe_log(self.log, f'could not append run {self.row["run_id"]}: {error}')
        finally:
            self.close()

    def close(self) -> None:
        if self.source:
            self.source.close()
            self.source = None
