#!/usr/bin/env python3
"""Test origin/next's merged tip unattended, paced by the Codex worker's Dial.

Stdlib only, Python 3.9+. launchd ticks every 20 minutes; tests run at most once
per SHA and every two hours. Evidence survives detached-worktree removal in the
ops checkout's artifacts/codex-testdesk/. No job is installed by this script.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import sm_codex_worker as worker

sys.path.insert(0, str(worker.REPO_ROOT / 'scripts'))
import lane_slots

HOME_DIR = Path.home() / 'SpokenMarginsOps' / 'codex-testdesk'
SPACING_SECONDS = 2 * 60 * 60
REPORT_ISSUE = 184
NOT_VERIFIED = 'not verified: agent-driven journeys, audible content, Lock Screen (owner)'


# Pure decisions and text: no simulator, GitHub or Codex needed in host tests.

def hold_reason(now: float, dial: dict, limits: dict | None, free: int, busy: bool) -> str | None:
    if dial['workers'] == 0:
        return 'Dial allows 0 Codex workers'
    return (worker.pacing_hold(now, dial['stop'], limits, free,
                               finish_by=dial.get('finish_by', ('Codex reset',)))
            or ('Mac-wide simulator slot is busy' if busy else None))


def schedule_hold(sha: str, state: dict, now: float) -> str | None:
    if sha in state.get('results', {}):
        return 'already has a result for ' + sha[:7]
    if 'last_started' in state and now - state['last_started'] < SPACING_SECONDS:
        return 'less than 2 hours since the last run started'
    return None


def summarize(manifest: dict) -> dict:
    counts = dict.fromkeys(('passed', 'failed', 'skipped'), 0)
    failed, journeys, errors = [], {}, []
    incomplete = False
    for step in manifest.get('steps', []):
        errors.extend(step.get('errors', []))
        # Timeouts/floods take precedence over any assertion recorded before interruption.
        incomplete |= bool(step.get('interrupted') or step.get('simulator_crash_report')
                           or step.get('exit_code') == 124)
        probation = step.get('probation', {})
        journeys.update(step.get('gating', {}))
        journeys.update(probation)
        for name, record in step.get('tests', {}).items():
            status = record['status']
            if status in counts:
                counts[status] += 1
            if status == 'failed' and name not in probation:
                failed.append(name)
    if incomplete:
        verdict = 'INCONCLUSIVE'
    elif failed:
        verdict = 'FAIL'
    elif manifest.get('status') == 'verified':
        verdict = 'PASS'
    else:
        # Compile/setup errors, missing tests and an XCTest connection that never
        # completes a test are infrastructure evidence, not listener bugs.
        verdict = 'INCONCLUSIVE'
    return {'verdict': verdict, 'counts': counts, 'failed': sorted(set(failed)),
            'journeys': journeys, 'errors': errors + ([manifest['error']] if manifest.get('error') else [])}


def combine(results: list[dict]) -> dict:
    verdicts = [r['verdict'] for r in results]
    return {'verdict': next((v for v in ('INCONCLUSIVE', 'FAIL', 'PASS') if v in verdicts), 'INCONCLUSIVE'),
            'counts': {s: sum(r['counts'][s] for r in results) for s in ('passed', 'failed', 'skipped')},
            'failed': sorted({t for r in results for t in r['failed']}),
            # A plan that failed conclusively is filed even when another plan was INCONCLUSIVE.
            'confirmed_failed': sorted({t for r in results if r['verdict'] == 'FAIL' for t in r['failed']}),
            'journeys': {t: s for r in results for t, s in r['journeys'].items()},
            'errors': [e for r in results for e in r['errors']]}


def script_results(listing: dict, records: dict) -> dict:
    """One outcome per listed script, including class selectors and unrun scripts."""
    results = {}
    for status in ('gating', 'probation'):
        for entry in listing[status]:
            selector = entry['test'].removesuffix('()')
            covered = [s for t, s in records.items() if t == selector or t.startswith(selector + '/')]
            results[selector] = next((s for s in ('failed', 'missing', 'skipped', 'passed')
                                      if s in covered), 'not_run')
    return results


def probation_ready(state: dict, sha: str, journeys: dict, probation: list[str]) -> list[str]:
    previous = sorted((r for s, r in state.get('results', {}).items() if s != sha),
                      key=lambda r: r['started'])
    done = state.get('results', {}).get(sha)
    if not previous or (done and not done.get('in_progress')):
        return []
    last = previous[-1].get('journeys', {})
    return sorted(t for t in probation if journeys.get(t) == last.get(t) == 'passed')


def report_text(sha: str, result: dict, evidence: Path) -> str:
    c = result['counts']
    lines = [f'Codex Test Desk: {sha[:7]}', '',
             f"{result['verdict']} — {c['passed']} passed, {c['failed']} failed, {c['skipped']} skipped."]
    if result['failed']:
        lines += ['Failing tests: ' + ', '.join(f'`{t}`' for t in result['failed'])]
    if result['journeys']:
        lines += ['Scripted journeys: ' + ', '.join(f'`{t}` {s}' for t, s in sorted(result['journeys'].items()))]
    if result.get('probation_ready'):
        lines += ['Probation passed twice in a row (owner/Test Desk may move to gating): '
                  + ', '.join(f'`{t}`' for t in result['probation_ready'])]
    if result['errors']:
        lines += ['Details: ' + '; '.join(dict.fromkeys(result['errors']))[:1500]]
    return '\n'.join(lines + [f'Evidence on the Mac: `{evidence}`', '', NOT_VERIFIED, ''])


def dedupe_query(test: str) -> str:
    # GitHub indexes words, not XCTest's slash-separated ID. Quote the method;
    # then verify a token match in the returned issue body/title.
    name = test.rsplit('/', 1)[-1].removesuffix('()')
    return 'is:issue is:open "' + re.sub(r'[^A-Za-z0-9_]', '', name) + '"'


def find_duplicate(issues: list[dict], tests: list[str]) -> int | None:
    for issue in issues:
        if issue['number'] == REPORT_ISSUE:
            continue  # the report we just posted names every failure; it is not a bug issue
        text = '\n'.join([issue.get('title') or '', issue.get('body') or '']
                         + [c.get('body') or '' for c in issue.get('comments', [])])
        if any(re.search(r'(?<!\w)' + re.escape(t.rsplit('/', 1)[-1].removesuffix('()')) + r'(?!\w)', text)
               for t in tests):
            return issue['number']
    return None


def diagnoses(raw: str, failed: list[str]) -> list[dict]:
    """Accept only a complete partition of the observed failures; fall back to replay steps."""
    try:
        groups = json.loads(raw)
        seen = []
        for group in groups:
            if not isinstance(group['tests'], list) or not group['tests'] or not all(
                    isinstance(group[k], str) and group[k].strip()
                    for k in ('title', 'steps', 'expected', 'actual', 'root_cause')):
                raise ValueError('missing fields')
            seen.extend(group['tests'])
        if sorted(seen) != sorted(failed):
            raise ValueError('not a partition')
        return groups
    except (ValueError, TypeError, KeyError):
        return [{'tests': [t], 'title': f'{t.rsplit("/", 1)[-1]} fails on next',
                 'steps': f'Run `--plan app` / `--plan journeys` at the tip below; observe `{t}`.',
                 'expected': 'The test scenario passes its assertions.',
                 'actual': 'The scenario fails an assertion; see the retained xcode-tests.log.',
                 'root_cause': 'Unconfirmed: Codex diagnosis was unavailable or invalid. Read the test and evidence.'}
                for t in failed]


def issue_text(group: dict, sha: str, report: str, evidence: Path) -> str:
    return '\n'.join([
        f"Failing tests: {', '.join('`' + t + '`' for t in group['tests'])}", '',
        '## Steps', group['steps'], '', '## Expected', group['expected'], '',
        '## Actual', group['actual'], '', '## Root-cause summary (Codex inference)', group['root_cause'], '',
        f'Tip SHA: `{sha}`', 'Build: next at the SHA above (unreleased integration tip).',
        f'Test Desk report: {report}', f'Evidence on the Mac: `{evidence}`', '', NOT_VERIFIED, ''])


@contextlib.contextmanager
def exclusive_slot():
    """Reserve the simulator nonblocking under the existing decision lock.

    Keep the decision lock for both plans so no second job can join. Pass both
    descriptors to verify-tests so a parent exit cannot unlock a running child.
    """
    folder = lane_slots.state_dir()
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / lane_slots.SIMULATOR_DECISION).open('a+') as decision:
        try:
            fcntl.flock(decision, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise TimeoutError('simulator slot decision is busy') from None
        if lane_slots.simulator_job_running():
            raise TimeoutError('Mac-wide simulator slot is busy')
        handle, _, _ = lane_slots.acquire([lane_slots.SIMULATOR_SLOT], 'simulator slot',
                                         'Codex Test Desk', max_wait=0)
        try:
            yield (handle.fileno(), decision.fileno())
        finally:
            lane_slots.release_handle(handle)


class Ops(worker.Ops):
    def __init__(self, home: Path = HOME_DIR, **kwargs):
        super().__init__(home=home, **kwargs)

    def test_plan(self, wt: Path, output: Path, plan: str, fds: tuple) -> dict:
        cmd = ['.venv/bin/python', 'scripts/verify-tests.py', '--plan', plan,
               '--output', str(output), '--simulator-slot-fd', str(fds[0])]
        env = {k: v for k, v in os.environ.items() if k not in ('CODEX_SANDBOX', lane_slots.BUILD_NEEDS_ROOM_ENV)}
        # verify-tests owns timeouts, crash handling and shutdown. No shorter outer
        # timeout can kill its finally block while a simulator is still running.
        with (output.parent / f'{plan}-runner.log').open('w') as log:
            result = subprocess.run(cmd, cwd=wt, env=env, pass_fds=fds,
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        path = output / 'manifest.json'
        if not path.exists():
            return {'status': 'failed_or_incomplete', 'steps': [],
                    'error': f'{plan}: runner exit {result.returncode}, no manifest; see {plan}-runner.log'}
        return json.loads(path.read_text())

    def post_report(self, body: str, evidence: Path) -> str:
        path = evidence / 'report.md'
        path.write_text(body)
        res = self.must(['gh', 'api', '--method', 'POST',
                         f'repos/{worker.REPO}/issues/{REPORT_ISSUE}/comments', '-F', f'body=@{path}'])
        return json.loads(res.stdout)['html_url']

    def diagnose(self, wt: Path, evidence: Path, failed: list[str]) -> list[dict]:
        logs = '\n'.join(f'\n{p.parent.name}:\n{p.read_text(errors="replace")[-60000:]}'
                         for p in sorted(evidence.glob('*/xcode-tests.log')))
        prompt = (
            'Read AGENTS.md. Diagnose these observed test failures read-only; do not edit, run tests, '
            'boot simulators, file issues or post comments. Read the test code and relevant implementation. '
            'Group tests only when they have the same root cause. For each distinct failure give a symptom '
            'title and a concrete listener failure scenario (steps, expected, actual), and root_cause. '
            'Mark uncertainty; do not invent evidence. Return ONLY a JSON array of objects with keys '
            'tests (list of the exact failing IDs), title, steps, expected, actual, root_cause. '
            f'Full evidence logs are in {evidence}. Every failing ID must appear exactly once.\nFailing IDs:\n' + json.dumps(failed) + '\nOutput:\n' + logs)
        prompt_path = evidence / 'diagnosis-prompt.txt'
        prompt_path.write_text(prompt)
        answer = evidence / 'diagnosis.json'
        # Prompt on stdin keeps a large test log below the OS argument-size limit.
        cmd = [worker.CODEX, 'exec', '-m', worker.MODEL, '-c', f'model_reasoning_effort="{worker.EFFORT}"',
               '-s', 'read-only',
               '-C', str(wt), '-o', str(answer), '-']
        with prompt_path.open() as source, (evidence / 'codex.log').open('w') as log:
            proc = subprocess.Popen(cmd, stdin=source, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                proc.wait(timeout=30 * 60)
            except subprocess.TimeoutExpired:
                worker.kill_tree(proc)
        raw = answer.read_text() if proc.returncode == 0 and answer.exists() else ''
        return diagnoses(raw, failed)

    def file_failures(self, groups: list[dict], sha: str, report: str, evidence: Path) -> None:
        for i, group in enumerate(groups):
            duplicate = None
            for test in group['tests']:
                issues = self.gh_json(['issue', 'list', '-R', worker.REPO, '--state', 'open',
                                       '--search', dedupe_query(test), '--limit', '100',
                                       '--json', 'number,title,body,comments'])
                duplicate = find_duplicate(issues, [test])
                if duplicate is not None:
                    break
            body = issue_text(group, sha, report, evidence)
            path = evidence / f'issue-{i + 1}.md'
            path.write_text(body)
            if duplicate is not None:
                self.must(['gh', 'issue', 'comment', str(duplicate), '-R', worker.REPO, '--body-file', str(path)])
            else:
                self.must(['gh', 'issue', 'create', '-R', worker.REPO, '--title', group['title'][:120],
                           '--body-file', str(path), '--label', 'ready,priority,bug'])


def save_state(path: Path, state: dict) -> None:
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2) + '\n')
    tmp.replace(path)


def tick(ops: Ops, dry_run: bool = False) -> str:
    say = print if dry_run else ops.log
    now = ops.now().timestamp()
    try:
        dial = worker.read_dial(ops.dial_body(), worker.load_parse_dial())
    except Exception as error:
        say('hold: Dial could not be read: ' + str(error))
        return 'held'
    try:
        limits = worker.parse_rate_limits(ops.limits())
    except Exception:
        limits = None
    try:
        free = ops.free_bytes()
    except OSError:
        free = 0
    why = hold_reason(now, dial, limits, free, lane_slots.simulator_job_running())
    if why:
        say('hold: ' + why)
        return 'held'
    if not dry_run:
        ops.must(['git', 'fetch', '--quiet', 'origin', worker.BASE_BRANCH], cwd=ops.repo_root, timeout=600)
    sha = ops.must(['git', 'rev-parse', 'origin/next'], cwd=ops.repo_root).stdout.strip()
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('origin/next did not resolve to a full SHA')
    path = ops.home / 'state.json'
    state = json.loads(path.read_text()) if path.exists() else {'results': {}}
    abandoned = [s for s, r in state['results'].items() if r.get('in_progress')]
    for s in abandoned:
        # The tick holds the slot lock for the whole run, so an in-progress record here was cut off
        # (Mac restart, kill). Close it as INCONCLUSIVE; once-per-SHA means it is not rerun.
        record = state['results'][s]
        record.pop('in_progress')
        record['errors'] = record.get('errors', []) + ['Run stopped before completion (Mac restart or killed)']
    if abandoned and not dry_run:
        save_state(path, state)
    why = schedule_hold(sha, state, now)
    if why:
        say('hold: ' + why)
        return 'held'
    if dry_run:
        say(f'Would fetch origin/next (cached tip {sha}), make a detached worktree, run setup-worktree.sh, '
            '--plan app then --plan journeys (gating + probation), post one report on #184, '
            'diagnose FAIL with codex exec -s read-only, search open issues and comment/file ready,priority,bug; '
            'record results and remove the worktree. No tests or writes in dry-run.')
        return 'dry-run'
    with contextlib.ExitStack() as stack:
        try:
            fds = stack.enter_context(exclusive_slot())
        except TimeoutError as error:
            say('hold: ' + str(error))
            return 'held'
        ops.home.mkdir(parents=True, exist_ok=True)
        wt = ops.home / 'worktree'
        evidence = ops.repo_root / 'artifacts' / 'codex-testdesk' / f'{int(now)}-{sha[:7]}'
        evidence.mkdir(parents=True, exist_ok=False)
        result = summarize({'error': 'Run stopped before completion'})
        state['last_started'] = now
        # Recorded before any test starts, so a run cut off mid-way is never repeated on this SHA.
        state['results'][sha] = dict(result, started=now, evidence=str(evidence), in_progress=True)
        save_state(path, state)
        added = False
        try:
            # Recover only this job's detached scratch worktree after a previous interrupted tick.
            if wt.exists():
                ops.must(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
            ops.must(['git', 'worktree', 'add', '--detach', str(wt), sha], cwd=ops.repo_root)
            added = True
            ops.must(['scripts/setup-worktree.sh'], cwd=wt)
            listing = json.loads((wt / 'TestPlans/scripted-journeys.json').read_text())
            probation = [e['test'].removesuffix('()') for e in listing['probation']]
            results = [summarize(ops.test_plan(wt, evidence / 'app', 'app', fds))]
            if results[0]['verdict'] != 'INCONCLUSIVE' and (listing['gating'] or listing['probation']):
                results.append(summarize(ops.test_plan(wt, evidence / 'journeys', 'journeys', fds)))
            result = combine(results)
            result['journeys'] = script_results(listing, result['journeys'])
            stack.close()  # simulator reservation ends before GitHub/Codex work
            result['probation_ready'] = probation_ready(state, sha, result['journeys'], probation)
            # Persist before network/Codex calls: neither failed posting nor a diagnostic
            # failure may rerun simulators on the same SHA.
            state['results'][sha] = dict(result, started=now, evidence=str(evidence))
            save_state(path, state)
            report = ops.post_report(report_text(sha, result, evidence), evidence)
            state['results'][sha]['report'] = report
            save_state(path, state)
            if result['confirmed_failed']:
                ops.file_failures(ops.diagnose(wt, evidence, result['confirmed_failed']), sha, report, evidence)
            return result['verdict']
        except Exception as error:
            if state['results'][sha].get('in_progress'):
                result = summarize({'error': str(error)})
                state['results'][sha] = dict(result, started=now, evidence=str(evidence))
                save_state(path, state)
                report = ops.post_report(report_text(sha, result, evidence), evidence)
                state['results'][sha]['report'] = report
                save_state(path, state)
            raise
        finally:
            try:
                if state['results'][sha].get('in_progress'):
                    state['results'][sha] = dict(result, started=now, evidence=str(evidence))
                    save_state(path, state)
            finally:
                if added or wt.exists():
                    removed = ops.run(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
                    if removed.returncode:
                        ops.log('worktree removal failed: ' + removed.stderr[:300])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--dry-run', action='store_true', help='print decisions; run no tests and change nothing')
    args = ap.parse_args(argv)
    ops = Ops()
    if args.dry_run:
        tick(ops, dry_run=True)
        return 0
    ops.home.mkdir(parents=True, exist_ok=True)
    with (ops.home / 'tick.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            ops.log('hold: another tick is running')
            return 0
        try:
            tick(ops)
        except Exception as error:
            ops.log('tick error: ' + str(error))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
