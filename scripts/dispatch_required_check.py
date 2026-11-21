#!/usr/bin/env python3
"""Start a required check on every open PR head that has no run of it (#4867).

Run it the day a check becomes required: `scripts/dispatch_required_check.py hosted-web.yml`. Each open, ready, same-repo
PR into main whose head has no run of the workflow (or only cancelled ones) gets a workflow_dispatch run on its branch,
so the check reports on that head. A head with a run in progress, or one that finished with any verdict, is left alone:
a failed run stays failed. A head whose runs were all cancelled is started again (you asked for the sweep). A second
run therefore dispatches nothing (give the first one a minute to show up).

The PR that adds a required check states how many PRs this started (docs/workstreams/test-lane.md).

Needs `actions: write` (a maintainer's gh login, or a token that has it). Exit 0 when the sweep ran, 1 when a read or a
dispatch failed, 2 for a workflow that can't be started this way.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import time

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import merge_policy  # noqa: E402
import required_checks  # noqa: E402


def open_prs(github, base: str) -> list[dict]:
    return github.api(f'repos/{github.repo}/pulls?state=open&base={base}&per_page=100', paginate=True)


RECHECK_WAIT = 60  # seconds: a run for a head pushed just now may not be listed yet


def scan(github, workflow: str, base: str) -> tuple[list[tuple], list[str], int]:
    """(heads to start as (number, sha, ref, state), a line per PR left alone, read failures)."""
    todo, notes, failures = [], [], 0
    for pull in open_prs(github, base):
        number, head = pull['number'], (pull.get('head') or {})
        sha, ref = head.get('sha'), head.get('ref')
        if pull.get('draft'):
            notes.append(f'#{number}: draft, left alone (the merge policy starts a missing check when the PR is labelled)')
        elif (head.get('repo') or {}).get('full_name') != github.repo:
            notes.append(f'#{number}: from a fork, left alone (a fork PR gets no hosted run)')
        else:
            try:
                state = required_checks.head_state(github.workflow_runs(workflow, sha))
            except merge_policy.ReadFailed as error:
                failures += 1
                notes.append(f'#{number}: could not read its runs ({error})')
                continue
            if required_checks.needs_start(state, restart_cancelled=True):
                todo.append((number, sha, ref, state))
            else:
                notes.append(f'#{number}: {state}, left alone')
    return todo, notes, failures


def sweep(github, workflow: str, base: str = 'main', dry_run: bool = False, out=sys.stdout, sleep=time.sleep,
          recheck_wait: float = RECHECK_WAIT) -> tuple[list[int], int]:
    """(PRs started, failures). Prints one line per PR. A head found without a run is looked for once more after
    <recheck_wait> seconds before it is started, so a PR pushed seconds ago, whose own run is slow to be listed, isn't
    started twice. A cancelled-only head is started here (a person ran the sweep on purpose)."""
    todo, notes, failures = scan(github, workflow, base)
    if todo and not dry_run and recheck_wait:
        sleep(recheck_wait)
        todo, notes, failures = scan(github, workflow, base)
    for note in notes:
        print(note, file=out)
    started = []
    for number, sha, ref, state in todo:
        if dry_run:
            print(f'#{number}: {state} on {sha[:7]}; would start {workflow} on `{ref}`', file=out)
            started.append(number)
            continue
        try:
            required_checks.start(github, workflow, ref, base)
        except merge_policy.ReadFailed as error:
            failures += 1
            print(f'#{number}: could not start {workflow} ({error}){required_checks.failure_hint(error)}', file=out)
            continue
        started.append(number)
        print(f'#{number}: {state} on {sha[:7]}; started {workflow} on `{ref}`', file=out)
    print(f'{workflow}: started {len(started)} PR(s)' + (f' ({", ".join("#%d" % n for n in started)})' if started else '')
          + (f'; {failures} failure(s)' if failures else '') + ('; dry run' if dry_run else '') + '.', file=out)
    return started, failures


def main(argv: list[str] | None = None, github=None, out=sys.stdout, sleep=time.sleep) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('workflow', help='a required workflow file, e.g. hosted-web.yml')
    parser.add_argument('--repo', default='')
    parser.add_argument('--base', default='main')
    parser.add_argument('--recheck-wait', type=float, default=RECHECK_WAIT,
                        help='seconds to wait before starting heads found without a run, then look again (0: no wait)')
    parser.add_argument('--dry-run', action='store_true', help='list what would start; start nothing')
    args = parser.parse_args(argv)
    if args.workflow in required_checks.NOT_DISPATCHABLE:
        print(f'{args.workflow} can not be started this way: {required_checks.NOT_DISPATCHABLE[args.workflow]}.', file=out)
        return 2
    if args.workflow not in required_checks.dispatchable():
        print(f'{args.workflow} makes no required check (scripts/required_checks.py lists: '
              f'{", ".join(required_checks.dispatchable())}).', file=out)
        return 2
    if github is None:
        import os
        repo = args.repo or os.environ.get('GITHUB_REPOSITORY') or os.environ.get('GH_REPO') or ''
        if not repo:
            parser.error('--repo (or GITHUB_REPOSITORY) is required')
        github = merge_policy.GitHub(repo)
    try:
        _, failures = sweep(github, args.workflow, args.base, args.dry_run, out, sleep=sleep, recheck_wait=args.recheck_wait)
    except merge_policy.ReadFailed as error:
        print(f'could not list the open PRs ({error})', file=out)
        return 1
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
