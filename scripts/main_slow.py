#!/usr/bin/env python3
"""The slow tier's run on main (#5145): the tests PRs leave out, nightly and before the phone builds.

Owner decision 2026-11-23 (docs/decisions.md): tests that are slow on CI and have not failed in 30 days
(scripts/slow_tier.py) leave every PR and merge group and run here instead. .github/workflows/main-slow.yml runs
`verify-tests.py --plan slow` on main's head once a night and before the 8:00 and 17:00 Phoenix phone builds, only when
that commit has no `main-slow` status yet, and records the result as a `main-slow` commit status. scripts/phone-build
reads the same status and runs `--plan slow` itself on a commit without a green one.

A failure opens or updates one "Main slow tests failed on <sha7>" issue labelled `regression`: the failing tests, the
last commit with a green `main-slow`, and every merge between them, so the PR that broke it is among a short list. The
first green run closes it. The decide rules are main_t3.py's (a pending older than STALE_PENDING counts as none; one
`error` gets one retry; a `failure` is never run again on the same commit).

Subcommands:
- decide --sha SHA [--force]: write `run=true|false` to $GITHUB_OUTPUT.
- report --sha SHA --run-url URL --manifest FILE [--exit-code N]: set the final status from the verify-tests.py
  manifest (and its exit code) and keep the failure issue. Exits 0 only on `success`.
- pending / lost --sha SHA --run-url URL.
Environment: GH_TOKEN and GH_REPO. Stdlib only.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main_t3  # noqa: E402  the shared GitHub helpers and decide rules

ROOT = Path(__file__).resolve().parents[1]
CONTEXT = 'main-slow'
MARKER = '<!-- main-slow-failure -->'
STATE_MARKER = re.compile(r'<!-- main-slow-state: (\{.*?\}) -->')
ISSUE_LABEL = 'regression'
HISTORY_PAGES = 3
MERGES_SHOWN = 60
FAILURES_SHOWN = 40


# ---- Pure logic (scripts/tests/test_main_slow.py) ------------------------------------------------

def should_run(statuses: list, now: datetime.datetime, force: bool = False) -> tuple:
    """main_t3.should_run's rules, for the `main-slow` context."""
    saved = main_t3.CONTEXT
    main_t3.CONTEXT = CONTEXT
    try:
        return main_t3.should_run(statuses, now, force)
    finally:
        main_t3.CONTEXT = saved


def results_from_manifest(manifest: dict, exit_code: int) -> tuple:
    """(state, failed tests, details) from a verify-tests.py --plan slow manifest and its exit code."""
    failed, details = [], []
    for step in manifest.get('steps') or []:
        for test, record in (step.get('tests') or {}).items():
            if (record or {}).get('status') == 'failed':
                failed.append(test)
        for error in step.get('errors') or []:
            details.append(f'{step.get("name")}: {error}')
            failed.extend(re.findall(r'\(([\w.]+)\) at ', error))  # unittest ids from parallel/serial runner output
    if manifest.get('error'):
        details.append(str(manifest['error']))
    failed = list(dict.fromkeys(failed))
    if manifest.get('lane_fault'):
        return 'error', failed, [f'runner fault: {manifest["lane_fault"]}', *details]
    if exit_code == 0 and manifest.get('status', '').startswith('verified'):
        return 'success', [], details
    if failed or any('FAILED' in d or 'Failed' in d for d in details):
        return 'failure', failed, details
    if not manifest.get('steps'):
        return 'error', [], details or ['the run stopped before its first step']
    return 'failure', failed, details or [f'verify-tests.py exited {exit_code}']


def description(state: str, failed: list, details: list) -> str:
    if state == 'success':
        return 'the slow tier passed'
    if state == 'pending':
        return 'running the slow tier'
    if failed:
        return f'{len(failed)} failed: ' + ', '.join(failed[:5])
    return (details[0] if details else state)


def last_green(nodes: list, exclude: str = '') -> str | None:
    for node in nodes:
        context = ((node.get('status') or {}).get('context') or {})
        if node.get('oid') != exclude and context.get('state') == 'SUCCESS':
            return node['oid']
    return None


def find_open_issue(issues: list) -> dict | None:
    found = [i for i in issues if 'pull_request' not in i and MARKER in (i.get('body') or '') and main_t3.trusted(i)]
    return min(found, key=lambda i: i['number']) if found else None


def issue_title(sha: str) -> str:
    return f'Main slow tests failed on {sha[:7]}'


def issue_body(sha: str, run_url: str, failed: list, details: list, green: str | None, merges: list,
               first_failed: str | None = None) -> str:
    first_failed = first_failed or sha
    state = {'first_failed': first_failed, 'latest': sha, 'last_green': green, 'failed': failed[:200]}
    lines = [MARKER, f'<!-- main-slow-state: {json.dumps(state, sort_keys=True).replace("-->", "")} -->', '',
             f'The slow tier on main (`main-slow`, #5145) failed on `{sha}`: {run_url}', '',
             'These tests left every PR because they were slow and had not failed in 30 days (scripts/slow_tier.py). '
             'One of the merges below broke one. Fix it, and move the test back to every PR by deleting its line in '
             'scripts/slow_tier.py (the waste signal in #5145).', '']
    if first_failed != sha:
        lines += [f'It first failed on `{first_failed}` and is still failing.', '']
    lines.append(f'- Last green `main-slow`: `{green}`' if green else
                 f'- Last green `main-slow`: none in the last {HISTORY_PAGES * 100} commits')
    lines += ['', f'## Failing tests ({len(failed)})', '']
    lines += [f'- `{t}`' for t in failed[:FAILURES_SHOWN]] or ['No single test was named. What the run said:']
    if not failed:
        lines += [f'- {main_t3.truncate(d, 400)}' for d in details[:15]]
    if green:
        lines += ['', f'## Merges since the last green ({len(merges)})', '',
                  f'First-parent commits in `{green[:7]}..{sha[:7]}`; the PR that broke it is one of these:', '']
        lines += [f'- {m}' for m in merges[:MERGES_SHOWN]]
        if len(merges) > MERGES_SHOWN:
            lines.append(f'- and {len(merges) - MERGES_SHOWN} more')
    lines += ['', 'This issue is updated by each failing run and closed by the first green one.', '',
              '_Posted by scripts/main_slow.py from .github/workflows/main-slow.yml._']
    return '\n'.join(lines)[:main_t3.BODY_LIMIT]


def issue_state(issue: dict | None) -> dict:
    match = STATE_MARKER.search((issue or {}).get('body') or '')
    try:
        return json.loads(match.group(1)) if match else {}
    except ValueError:
        return {}


# ---- GitHub --------------------------------------------------------------------------------------

HISTORY_QUERY = main_t3.HISTORY_QUERY.replace(f'"{main_t3.CONTEXT}"', f'"{CONTEXT}"')


def set_status(sha: str, state: str, run_url: str, text: str) -> None:
    payload = {'state': state, 'context': CONTEXT, 'target_url': run_url,
               'description': main_t3.truncate(text, main_t3.DESCRIPTION_LIMIT)}
    main_t3.gh('api', '-X', 'POST', f'repos/{main_t3.repo()}/statuses/{sha}', '--input', '-', stdin=json.dumps(payload))
    print(f'{CONTEXT} on {sha[:7]}: {state} ({payload["description"]})', flush=True)


def find_last_green(sha: str) -> str | None:
    owner, name = main_t3.repo().split('/', 1)
    after = None
    for _ in range(HISTORY_PAGES):
        args = ['api', 'graphql', '-f', f'query={HISTORY_QUERY}', '-f', f'owner={owner}', '-f', f'name={name}',
                '-f', f'expr={sha}']
        if after:
            args += ['-f', f'after={after}']
        history = json.loads(main_t3.gh(*args))['data']['repository']['object']['history']
        found = last_green(history['nodes'], exclude=sha)
        if found or not history['pageInfo']['hasNextPage']:
            return found
        after = history['pageInfo']['endCursor']
    return None


def report_failure(sha: str, run_url: str, failed: list, details: list) -> str:
    try:
        green = find_last_green(sha)
    except (RuntimeError, KeyError, TypeError, ValueError) as error:
        print(f'Could not find the last green {CONTEXT}: {error}', flush=True)
        green = None
    merges = main_t3.merges_between(green, sha) if green else []
    issue = find_open_issue(main_t3.open_issues())
    repo = main_t3.repo()
    if issue is None:
        return main_t3.gh('issue', 'create', '-R', repo, '--title', issue_title(sha), '--label', ISSUE_LABEL,
                          '--body-file', '-', stdin=issue_body(sha, run_url, failed, details, green, merges)).strip()
    previous = issue_state(issue)
    body = issue_body(sha, run_url, failed, details, green, merges, previous.get('first_failed'))
    main_t3.gh('issue', 'edit', str(issue['number']), '-R', repo, '--body-file', '-', stdin=body)
    main_t3.gh('issue', 'comment', str(issue['number']), '-R', repo, '--body',
               f'Still failing on `{sha[:7]}` ({run_url}): {len(failed)} failed.')
    return issue['html_url']


def close_on_green(sha: str, run_url: str) -> None:
    issue = find_open_issue(main_t3.open_issues())
    if issue:
        main_t3.gh('issue', 'close', str(issue['number']), '-R', main_t3.repo(), '--reason', 'completed', '--comment',
                   f'`{CONTEXT}` passed on `{sha[:7]}` ({run_url}). Closing; the next failing run opens a new issue.')


# ---- Commands ------------------------------------------------------------------------------------

def command_decide(args) -> int:
    now = datetime.datetime.now(datetime.timezone.utc)
    run, why = should_run(main_t3.statuses(args.sha), now, args.force)
    print(f'{CONTEXT} on {args.sha[:7]}: {"run" if run else "skip"} ({why})')
    main_t3.write_outputs(run=str(run).lower())
    main_t3.write_summary(f'{CONTEXT} on `{args.sha[:7]}`: {"run" if run else "skip"}, {why}.')
    return 0


def command_report(args) -> int:
    try:
        manifest = json.loads(Path(args.manifest).read_text())
    except (OSError, ValueError) as error:
        manifest = {'error': f'no readable manifest: {error}'}
    state, failed, details = results_from_manifest(manifest, args.exit_code)
    text = description(state, failed, details)
    set_status(args.sha, state, args.run_url, text)
    main_t3.write_summary('\n'.join([f'## {CONTEXT} on `{args.sha[:7]}`: {state}', '', text, '',
                                     *[f'- {main_t3.truncate(d, 500)}' for d in details[:40]]]))
    try:
        if state == 'failure':
            print(f'Failure issue: {report_failure(args.sha, args.run_url, failed, details)}', flush=True)
        elif state == 'success':
            close_on_green(args.sha, args.run_url)
    except (RuntimeError, KeyError, ValueError) as error:
        print(f'::warning::Could not update the {CONTEXT} failure issue: {error}', flush=True)
    return 0 if state == 'success' else 1


def command_pending(args) -> int:
    set_status(args.sha, 'pending', args.run_url, description('pending', [], []))
    return 0


def command_lost(args) -> int:
    ours = [s for s in main_t3.statuses(args.sha) if s.get('context') == CONTEXT]
    newest = max(ours, key=lambda s: s.get('created_at') or '', default=None)
    if newest and newest.get('state') == 'pending':
        set_status(args.sha, 'error', args.run_url, 'runner fault: the job stopped before it reported')
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    decide = sub.add_parser('decide')
    decide.add_argument('--sha', required=True)
    decide.add_argument('--force', action='store_true')
    report = sub.add_parser('report')
    report.add_argument('--sha', required=True)
    report.add_argument('--run-url', required=True)
    report.add_argument('--manifest', required=True)
    report.add_argument('--exit-code', type=int, default=1)
    for name in ('pending', 'lost'):
        one = sub.add_parser(name)
        one.add_argument('--sha', required=True)
        one.add_argument('--run-url', required=True)
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        parser.error('--sha must be a full 40-character commit SHA')
    return {'decide': command_decide, 'report': command_report, 'pending': command_pending,
            'lost': command_lost}[args.command](args)


if __name__ == '__main__':
    sys.exit(main())
