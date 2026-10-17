#!/usr/bin/env python3
"""Refuse a job on this self-hosted runner when its pull request comes from a fork (#1719).

The workflows' own `head.repo.full_name == github.repository` guards are not enough once the repo
is public: a `pull_request` run uses the workflow files from the PR's merge commit, so a fork's PR
can delete the guard, or add a new workflow with `runs-on: [self-hosted]`. This check runs on the
runner itself, before the job's first step, from a file the PR can't change.

The runner calls refuse-fork-jobs.sh through ACTIONS_RUNNER_HOOK_JOB_STARTED (README.md). A non-zero
exit fails the job before any of its steps run.

Allowed: push, workflow_dispatch, schedule and the other events only people with write access can
start, and pull request events whose head repository is this repository. Refused: a pull request
event from any other repository, or one whose payload can't be read (fail closed).
"""
import json
import os
import sys

# Events whose payload carries a pull request whose code (or workflow files) may come from its head repo.
PULL_REQUEST_EVENTS = {
    'pull_request', 'pull_request_target', 'pull_request_review', 'pull_request_review_comment',
}
# Events a stranger can start on a public repo without write access, with no pull request in the payload.
# None of our workflows use them; refuse on these runners rather than guess what code they'd run.
STRANGER_EVENTS = {'issue_comment', 'issues', 'discussion', 'discussion_comment', 'fork', 'watch'}


def verdict(event_name: str, repository: str, payload: dict) -> tuple[bool, str]:
    """(allowed, reason) for one job."""
    if event_name in STRANGER_EVENTS:
        return False, f'{event_name} events can come from anyone; no self-hosted job runs on them'
    if event_name not in PULL_REQUEST_EVENTS:
        return True, f'{event_name}: only people with write access can start it'
    head = ((payload.get('pull_request') or {}).get('head') or {}).get('repo') or {}
    head_repo = head.get('full_name')
    if not head_repo:
        # A deleted fork leaves head.repo null: it is still not this repository.
        return False, 'the pull request has no head repository (a deleted fork?)'
    if not repository or head_repo.lower() != repository.lower():
        return False, f'the pull request comes from {head_repo}, not {repository}'
    return True, f'the pull request comes from {repository} itself'


def main() -> int:
    event_name = os.environ.get('GITHUB_EVENT_NAME', '')
    repository = os.environ.get('GITHUB_REPOSITORY', '')
    path = os.environ.get('GITHUB_EVENT_PATH', '')
    try:
        with open(path, encoding='utf-8') as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as error:
        if event_name in PULL_REQUEST_EVENTS or event_name in STRANGER_EVENTS or not event_name:
            print(f'::error::Runner guard: cannot read the event payload ({error}); refusing this job.')
            return 1
        payload = {}
    allowed, reason = verdict(event_name, repository, payload)
    if allowed:
        print(f'Runner guard: allowed, {reason}.')
        return 0
    print(f'::error::Runner guard: refused, {reason}. This runner only runs this repository\'s own branches.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
