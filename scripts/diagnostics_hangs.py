"""Every main-thread hang, kill and memory reading from the owner's Diagnostics exports, in one table (#2259).

Part of the systemic audit of reads larger than the screen needs (#2256). The static scanner (#2257) says which code
looks risky; this says which code actually froze the owner's phone, so the ranking weighs real pain.

What an export is: a flat JSON object. `playbackEvents` is a JSON string holding `{"events": [...]}`, the last 300
events. `main.hang` events carry `durationMs`, `screen`, `operation`, `status` and `lastTap`; `app.previous_exit`
carries what MetricKit said about how the previous run ended; the top-level `memoryFootprint` is a ` | `-separated
list of `MM-dd HH:mm:ssZ <reason> <target> <N>MB [free <N>MB]` readings. Exports overlap in time, so events and
readings are deduplicated before counting.

The exports are only read, never moved or changed. The full tables go to `artifacts/` (git-ignored, they stay
local); the summary is Markdown meant to be posted on #2256. Standard output carries only counts and paths.

    python3 scripts/diagnostics_hangs.py                      # every export in ~/Downloads
    python3 scripts/diagnostics_hangs.py a.json b.json --out artifacts/diagnostics-hangs
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_OUT = REPO / 'artifacts' / 'diagnostics-hangs'
# Both naming forms seen: the app's own `Spoken Margins diagnostics 0.1 (35) b039c32 2026-10-20 1027.json` and the
# underscored form a share sheet or upload makes of it.
EXPORT_GLOBS = ('Spoken Margins diagnostics*.json', 'Spoken_Margins_diagnostics*.json')
# The first commit with the always-on hang probe (#2099, #2111). A build without it can't record `main.hang`.
HANG_PROBE_FILE = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/HangTelemetry.swift'
CONTEXT_EVENTS = 3
TOP_PAIRS = 5
# Fields worth showing when an event is quoted as context for a hang or a kill.
CONTEXT_FIELDS = ('command', 'status', 'to', 'reason', 'outcome', 'state', 'durationMs', 'screen', 'operation')
MEMORY_READING = re.compile(
    r'^(?P<when>\d\d-\d\d \d\d:\d\d:\d\dZ) (?P<reason>\S+) (?P<target>\S+) (?P<mb>\d+)MB(?: free (?P<free>\d+)MB)?$')


@dataclass
class Export:
    path: Path
    build: str
    sha: str
    exported_at: str
    events: list[dict]
    memory: str
    last_run_start: str = ''
    # The export's own one-line summary (#2096, #2580): hangs, tap-to-state p95 and `budget=ok|broken(...)`. Builds
    # before it have none.
    responsiveness: str = ''


@dataclass
class Event:
    time: str
    kind: str
    fields: dict
    elapsed_ms: int
    exports: list[Export] = field(default_factory=list)


def instant(text: str) -> datetime:
    """An export's ISO time (`2026-10-20T15:27:11Z`, with or without milliseconds) as a comparable datetime."""
    try:
        return datetime.fromisoformat(text.replace('Z', '+00:00'))
    except ValueError:
        return datetime.fromisoformat('0001-01-01T00:00:00+00:00')


def find_exports(folder: Path) -> list[Path]:
    found = {p for pattern in EXPORT_GLOBS for p in folder.glob(pattern)}
    return sorted(found)


def parse_build(text: str) -> tuple[str, str]:
    """`0.1 (35) · b039c32` gives ('35', 'b039c32')."""
    number = re.search(r'\((\d+)\)', text or '')
    sha = re.search(r'\b([0-9a-f]{7,40})\b', (text or '').split('·')[-1])
    return (number.group(1) if number else '?', sha.group(1) if sha else '?')


def load_export(path: Path) -> Export:
    data = json.loads(path.read_text(encoding='utf-8'))
    build, sha = parse_build(data.get('developerBuild', ''))
    raw = data.get('playbackEvents') or '{}'
    events = (json.loads(raw) if isinstance(raw, str) else raw).get('events', [])
    export = Export(path, build, sha, data.get('exportedAt', ''), events, data.get('memoryFootprint', '') or '',
                    responsiveness=data.get('responsiveness', '') or '')
    # The run that was live when the export was made is the export's own build for sure. Runs are told apart by
    # `elapsedMs` (time since launch) going down.
    start = ''
    previous = None
    for event in sorted(events, key=lambda e: e.get('time', '')):
        elapsed = int(event.get('elapsedMs') or 0)
        if previous is None or elapsed < previous:
            start = event.get('time', '')
        previous = elapsed
    export.last_run_start = start
    return export


def merge_events(exports: list[Export]) -> list[Event]:
    """One `Event` per distinct (time, kind, fields), however many exports carry it, in time order."""
    merged: dict[tuple, Event] = {}
    for export in exports:
        for raw in export.events:
            fields = {k: str(v) for k, v in (raw.get('fields') or {}).items()}
            key = (raw.get('time', ''), raw.get('kind', ''), json.dumps(fields, sort_keys=True))
            event = merged.get(key)
            if event is None:
                event = merged[key] = Event(key[0], key[1], fields, int(raw.get('elapsedMs') or 0))
            event.exports.append(export)
    return sorted(merged.values(), key=lambda e: (e.time, e.elapsed_ms))


def attribute_build(event: Event, exports: list[Export]) -> tuple[str, str, bool]:
    """The build an event most likely ran on: that of the earliest export holding it.

    Sure when the event is in that export's live run, or when an export of the same build was made before the
    event (so that build was already installed). Otherwise an older build may have logged it before an update.
    """
    first = min(event.exports, key=lambda e: e.exported_at)
    sure = instant(event.time) >= instant(first.last_run_start) or any(
        other.sha == first.sha and other.exported_at and instant(other.exported_at) < instant(event.time)
        for other in exports)
    return first.build, first.sha, sure


def has_hang_probe(sha: str, repo: Path = REPO) -> str:
    """'yes' or 'no' when git knows the commit, else 'unknown'."""
    if not re.fullmatch(r'[0-9a-f]{7,40}', sha or ''):
        return 'unknown'
    try:
        known = subprocess.run(['git', '-C', str(repo), 'cat-file', '-e', f'{sha}^{{commit}}'],
                               capture_output=True, timeout=20)
        if known.returncode != 0:
            return 'unknown'
        present = subprocess.run(['git', '-C', str(repo), 'cat-file', '-e', f'{sha}:{HANG_PROBE_FILE}'],
                                 capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return 'unknown'
    return 'yes' if present.returncode == 0 else 'no'


def budget_word(line: str) -> str:
    """`ok` or `broken(hang,tap)` from an export's `responsiveness` line; a dash when the build has none."""
    match = re.search(r'\bbudget=(\S+)', line or '')
    return match.group(1) if match else '–'


def describe(event: Event) -> str:
    shown = [f'{k}={event.fields[k]}' for k in CONTEXT_FIELDS if k in event.fields]
    return event.kind + (f'({", ".join(shown)})' if shown else '')


def hang_rows(events: list[Event], exports: list[Export]) -> list[dict]:
    rows = []
    for index, event in enumerate(events):
        if event.kind != 'main.hang':
            continue
        build, sha, sure = attribute_build(event, exports)
        before = events[max(0, index - CONTEXT_EVENTS):index]
        rows.append({
            'build': build, 'sha': sha, 'build_sure': 'yes' if sure else 'no', 'time': event.time,
            'screen': event.fields.get('screen', '?'), 'operation': event.fields.get('operation', '?'),
            'durationMs': int(event.fields.get('durationMs') or 0), 'status': event.fields.get('status', '?'),
            'lastTap': event.fields.get('lastTap', ''), 'lastTapAgoMs': event.fields.get('lastTapAgoMs', ''),
            'skipped': event.fields.get('skipped', ''),
            'context': ' ; '.join(describe(e) for e in reversed(before)),
        })
    return rows


def kill_kind(fields: dict) -> str:
    """What shape of ending MetricKit reported. Watchdog-shaped means iOS ended the app for not answering."""
    reason = fields.get('reason', '')
    termination = fields.get('crashTermination', '').lower()
    if 'watchdog' in reason or '8badf00d' in termination:
        return 'watchdog'
    if 'cpu' in reason:
        return 'cpu'
    if 'memory' in reason:
        return 'memory'
    if 'crash' in reason:
        return 'crash'
    return 'other'


def watchdog_count(fields: dict) -> int:
    """How many watchdog-shaped endings one event reports: iOS's watchdog exit counts, or a crash it ended with
    0x8badf00d. A MetricKit hang report (`hangs`) is left out: the app lived through it.
    """
    count = sum(int(fields.get(k) or 0) for k in ('fgWatchdog', 'bgWatchdog'))
    if '8badf00d' in fields.get('crashTermination', '').lower():
        count = max(count, 1)
    return count


def exit_counts(fields: dict) -> dict[str, int]:
    """The exits one event counts, by MetricKit's field (`bgCpuLimit`, `fgWatchdog`, ...), plus crash reports.

    CPU exceptions and disk-write exceptions are left out: iOS reports them without necessarily ending the app.
    """
    counts = {k: int(v) for k, v in fields.items() if re.fullmatch(r'(bg|fg)[A-Z]\w*', k) and v.isdigit()}
    if fields.get('crashes', '0').isdigit() and int(fields.get('crashes', '0')):
        counts['crashes'] = int(fields['crashes'])
    return {k: v for k, v in counts.items() if v}


def total_exits(events: list[Event]) -> dict[str, int]:
    """Exits by field over every report, with each day's count taken once.

    MetricKit's exit counts are cumulative for their period, so a period seen on two launches counts its larger
    figure, not their sum.
    """
    per_period: dict[tuple, int] = {}
    for event in events:
        if event.kind != 'app.previous_exit':
            continue
        period = event.fields.get('exitsPeriod') or event.fields.get('diagnosticsPeriod') or event.time
        for name, count in exit_counts(event.fields).items():
            key = (period, name)
            per_period[key] = max(per_period.get(key, 0), count)
    totals: dict[str, int] = defaultdict(int)
    for (_, name), count in per_period.items():
        totals[name] += count
    return dict(totals)


def kill_rows(events: list[Event], exports: list[Export]) -> list[dict]:
    rows = []
    for index, event in enumerate(events):
        if event.kind != 'app.previous_exit' or event.fields.get('reason', 'none_reported') == 'none_reported':
            continue
        build, sha, sure = attribute_build(event, exports)
        earlier = events[:index]
        last_hang = next((e for e in reversed(earlier) if e.kind == 'main.hang'), None)
        last_away = next((e for e in reversed(earlier) if e.kind in ('app.background', 'startup.background_end')),
                         None)
        rows.append({
            'build': build, 'sha': sha, 'build_sure': 'yes' if sure else 'no', 'loggedAt': event.time,
            'kind': kill_kind(event.fields), 'exits': sum(exit_counts(event.fields).values()),
            'watchdogCount': watchdog_count(event.fields),
            'reason': event.fields.get('reason', ''),
            'period': event.fields.get('exitsPeriod') or event.fields.get('diagnosticsPeriod', ''),
            'details': ', '.join(f'{k}={v}' for k, v in sorted(event.fields.items())
                                 if k not in ('reason', 'source', 'exitsPeriod', 'diagnosticsPeriod')
                                 and not k.endswith('Frames')),
            'cpuExceptions': event.fields.get('cpuExceptions', ''),
            'hasFrames': 'yes' if any(k.endswith('Frames') for k in event.fields) else 'no',
            'hangBefore': f'{last_hang.time} {describe(last_hang)}' if last_hang else '',
            'awayBefore': f'{last_away.time} {describe(last_away)}' if last_away else '',
        })
    return rows


def memory_rows(exports: list[Export]) -> list[dict]:
    seen: dict[tuple, dict] = {}
    for export in exports:
        exported = export.exported_at[:10]
        for part in export.memory.split(' | '):
            match = MEMORY_READING.match(part.strip())
            if not match:
                continue
            # Readings carry no year: take the export's, or the year before for a December reading in January.
            year = int(exported[:4]) if exported[:4].isdigit() else 0
            if exported[5:7].isdigit() and match['when'][:2] > exported[5:7]:
                year -= 1
            when = f"{year:04d}-{match['when'][:5]}T{match['when'][6:]}"
            key = (when, match['reason'], match['target'], match['mb'])
            if key in seen:
                continue
            seen[key] = {'build': export.build, 'sha': export.sha, 'time': when, 'reason': match['reason'],
                         'target': match['target'], 'footprintMB': int(match['mb']),
                         'freeMB': match['free'] or ''}
    return sorted(seen.values(), key=lambda r: r['time'])


def summarize_hangs(rows: list[dict], keys: tuple[str, ...]) -> list[dict]:
    groups: dict[tuple, list[int]] = defaultdict(list)
    for row in rows:
        groups[tuple(row[k] for k in keys)].append(row['durationMs'])
    table = []
    for key, durations in groups.items():
        table.append({**dict(zip(keys, key)), 'count': len(durations),
                      'medianMs': round(statistics.median(durations)), 'worstMs': max(durations),
                      'totalMs': sum(durations)})
    return sorted(table, key=lambda r: (-r['totalMs'], -r['count']))


def summarize_memory(rows: list[dict]) -> list[dict]:
    groups: dict[tuple, list[int]] = defaultdict(list)
    for row in rows:
        groups[(row['build'], row['reason'])].append(row['footprintMB'])
    return sorted(({'build': b, 'reason': r, 'readings': len(v), 'medianMB': round(statistics.median(v)),
                    'peakMB': max(v)} for (b, r), v in groups.items()), key=lambda r: (r['build'], -r['peakMB']))


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', newline='', encoding='utf-8') as handle:
        if not rows:
            handle.write('')
            return
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def markdown_table(rows: list[dict], columns: list[str]) -> str:
    if not rows:
        return '_None._\n'
    lines = ['| ' + ' | '.join(columns) + ' |', '|' + '---|' * len(columns)]
    lines += ['| ' + ' | '.join(str(row[c]) for c in columns) + ' |' for row in rows]
    return '\n'.join(lines) + '\n'


def seconds(ms: int) -> str:
    return f'{ms / 1000:.1f} s'


def build_report(exports: list[Export], probe: dict[str, str]) -> dict:
    events = merge_events(exports)
    hangs = hang_rows(events, exports)
    kills = kill_rows(events, exports)
    memory = memory_rows(exports)
    raw_events = sum(len(e.events) for e in exports)
    return {
        'exports': exports, 'events': events, 'raw_events': raw_events, 'hangs': hangs, 'kills': kills,
        'memory': memory, 'probe': probe,
        'by_build': summarize_hangs(hangs, ('build', 'screen', 'operation')),
        'by_pair': summarize_hangs(hangs, ('screen', 'operation')),
    }


def render_summary(report: dict) -> str:
    exports, hangs, kills, memory = report['exports'], report['hangs'], report['kills'], report['memory']
    probe = report['probe']
    out = ['## Field data: main-thread hangs from the owner\'s Diagnostics exports (#2259)', '']
    total = sum(r['durationMs'] for r in hangs)
    unlabelled = [r for r in hangs if r['operation'] == 'none']
    exit_totals = total_exits(report['events'])
    exits = sum(exit_totals.values())
    watchdog = sum(n for name, n in exit_totals.items() if name in ('fgWatchdog', 'bgWatchdog')) + sum(
        1 for r in kills if '8badf00d' in r['details'].lower())
    cpu_reports = sum(int(r['cpuExceptions']) for r in kills if r['cpuExceptions'].isdigit())
    times = [ev.time for ev in report['events']]
    hang_times = sorted(r['time'] for r in hangs)
    hang_builds = sorted({(r['build'], r['sha']) for r in hangs})
    hang_span = (f', between {hang_times[0][:16]}Z and {hang_times[-1][:16]}Z on '
                 f'{len(hang_builds)} build{"s" if len(hang_builds) != 1 else ""} '
                 f'({", ".join(f"{b} `{sha}`" for b, sha in hang_builds)})') if hangs else ''
    skipped = sum(int(r['skipped']) for r in hangs if str(r['skipped']).isdigit())
    unsure = sum(1 for r in hangs if r['build_sure'] == 'no')
    first, last = (min(times), max(times)) if times else ('?', '?')
    out += [
        f'1. **{len(hangs)} hangs**, {seconds(total)} frozen in all{hang_span}. '
        f'Read from {len(exports)} exports ({report["raw_events"]} events, {len(report["events"])} after removing '
        f'overlap) covering {first[:10]} to {last[:10]}, but only builds with the hang probe can record a hang, '
        'so this is a count for that window, not a rate over the whole span.'
        + (f' The probe also left out {skipped} hangs over its rate limit, so the count is a floor.' if skipped
           else '')
        + (f' {unsure} hangs may have run on an earlier build than the one named (`build_sure=no`).' if unsure
           else ''),
        f'2. **{len(unlabelled)} of {len(hangs)} hangs** ({seconds(sum(r["durationMs"] for r in unlabelled))}) '
        'have `operation: none`: the work had no label (#2255).',
        f'3. **{exits} exits** iOS reported (MetricKit, in {len(kills)} reports), **{watchdog} watchdog-shaped** '
        f'({", ".join(f"{k} {n}" for k, n in sorted(exit_totals.items())) or "none"}). '
        f'Plus {cpu_reports} CPU-exception reports, which need not have ended the app.',
        '',
        f'### Top {TOP_PAIRS} screen × operation by total frozen time', '',
        markdown_table(report['by_pair'][:TOP_PAIRS], ['screen', 'operation', 'count', 'medianMs', 'worstMs',
                                                       'totalMs']),
        '### By build × screen × operation', '',
        markdown_table(report['by_build'], ['build', 'screen', 'operation', 'count', 'medianMs', 'worstMs',
                                            'totalMs']),
        '### Kills, with the hang and the background event before each', '',
        'The nearest earlier `main.hang` and background event in the merged log. A dash under hangBefore means no '
        'hang was recorded earlier, which for a build without the probe says nothing about whether one happened.',
        '',
        markdown_table([{**k, 'hangBefore': k['hangBefore'] or '–', 'awayBefore': k['awayBefore'] or '–'}
                        for k in kills],
                       ['build', 'loggedAt', 'kind', 'exits', 'watchdogCount', 'reason', 'period', 'hangBefore',
                        'awayBefore']),
        '### Memory', '',
    ]
    if memory:
        peak = max(memory, key=lambda r: r['footprintMB'])
        warnings = [r for r in memory if 'warning' in r['reason']]
        out.append(f'{len(memory)} readings. Peak {peak["footprintMB"]} MB ({peak["reason"]}, {peak["target"]}, '
                   f'build {peak["build"]}, {peak["time"]}). Memory warnings: {len(warnings)}.')
        out.append('')
        out.append(markdown_table(summarize_memory(memory), ['build', 'reason', 'readings', 'medianMB', 'peakMB']))
    else:
        out.append('_No memory readings._')
    out += ['', '### Exports read', '']
    out.append(markdown_table(
        [{'build': e.build, 'sha': e.sha, 'exportedAt': e.exported_at, 'events': len(e.events),
          'hangProbe': probe.get(e.sha, 'unknown'),
          'hangs': sum(1 for ev in e.events if ev.get('kind') == 'main.hang'),
          'budget': budget_word(e.responsiveness)} for e in exports],
        ['build', 'sha', 'exportedAt', 'events', 'hangProbe', 'hangs', 'budget']))
    without = sorted({e.sha for e in exports if probe.get(e.sha) == 'no'})
    out += [
        '### What this data can\'t show', '',
        f'1. Builds without the hang probe (#2099, #2111) record no `main.hang` at all: '
        f'{", ".join(f"`{s}`" for s in without) or "none of these"}. Their freezes are missing here, not absent.',
        '2. `operation: none` names no code. Until the work is labelled (#2255), those hangs rank by screen only.',
        '3. Each export keeps only its last 300 events, and the probe writes at most 20 hangs per 10 minutes '
        '(`skipped` counts the rest). Gaps between exports are lost.',
        '4. A hang that ends in a kill is never recorded: the probe writes after the main thread answers. '
        'MetricKit\'s report comes on a later launch, with only a day or a time range, so the hang and background '
        'events next to a kill are the closest ones before its report, not proof of cause.',
        '5. MetricKit exit counts are per day and may arrive a day late; CPU exceptions are reports, not '
        'necessarily kills.',
        '6. Builds come from the export that carries each event; an event logged before an update is marked '
        '`build_sure=no` in the full table.',
        '',
        '_Full tables (one row per hang with the 3 events before it, kills, memory readings) stay local in '
        '`artifacts/diagnostics-hangs/`._',
    ]
    return '\n'.join(out) + '\n'


def count_by(rows: list[dict], key: str) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for row in rows:
        counts[row[key]] += 1
    return dict(counts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('exports', nargs='*', type=Path, help='export files; default: every one in ~/Downloads')
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--no-git', action='store_true', help='skip the hang-probe check against git')
    args = parser.parse_args(argv)
    paths = args.exports or find_exports(Path.home() / 'Downloads')
    if not paths:
        print('no Diagnostics exports found', file=sys.stderr)
        return 1
    exports = sorted((load_export(p) for p in paths), key=lambda e: e.exported_at)
    probe = {e.sha: ('unknown' if args.no_git else has_hang_probe(e.sha)) for e in exports}
    report = build_report(exports, probe)
    write_csv(args.out / 'hangs.csv', report['hangs'])
    write_csv(args.out / 'kills.csv', report['kills'])
    write_csv(args.out / 'memory.csv', report['memory'])
    write_csv(args.out / 'by-build-screen-operation.csv', report['by_build'])
    summary = args.out / 'summary.md'
    summary.write_text(render_summary(report), encoding='utf-8')
    print(f'{len(exports)} exports, {len(report["events"])} events, {len(report["hangs"])} hangs, '
          f'{len(report["kills"])} kills, {len(report["memory"])} memory readings -> {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
