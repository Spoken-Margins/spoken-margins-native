#!/usr/bin/env python3
"""Check lane requests on Ubuntu before they consume a Mac queue slot.

Uses trusted base-branch code, never executes PR code, and merges only in a disposable local clone.
No branch is pushed. A clean merge changes nothing on GitHub; conflicts get one comment per head/base
pair, needs-mac, and lose lane:queued/automerge. API/fetch failures fail the hosted job, not the PR's
labels. GH_TOKEN/GH_REPO are supplied by the workflow.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import quote

ARMED = {'lane:queued', 'automerge'}


def git(tree: Path, *args: str, check: bool = True, **kwargs):
    env = dict(os.environ, GIT_LFS_SKIP_SMUDGE="1")
    env.update(kwargs.pop("env", {}))
    return subprocess.run(['git', '-C', str(tree), *args], capture_output=True, text=True, check=check, env=env, **kwargs)


def fetch_pull(tree: Path, number: int, base: str) -> None:
    # Checkout persists no credentials. Supply this fetch's read token in the environment, not argv.
    env = dict(os.environ)
    auth = base64.b64encode(f'x-access-token:{env["GH_TOKEN"]}'.encode()).decode()
    env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='http.https://github.com/.extraheader',
               GIT_CONFIG_VALUE_0=f'AUTHORIZATION: basic {auth}')
    git(tree, 'fetch', '--no-tags', 'origin', f'+refs/heads/{base}:refs/remotes/origin/{base}',
        f'+refs/pull/{number}/head:refs/lane-preflight/{number}', env=env)


def conflicting_files(tree: Path, base_sha: str, head: str) -> list[str]:
    """Attempt base-first git merge --no-commit, including real rename/delete conflicts.

    The checkout and index live only in a temporary clone, so even failed merges leave the caller's
    checkout untouched. --no-ff prevents a fast-forward from moving the temporary HEAD either.
    """
    with tempfile.TemporaryDirectory(prefix='lane-conflicts-') as temporary:
        clone = Path(temporary) / 'merge'
        git(tree, 'clone', '--shared', '--no-checkout', '--quiet', str(tree.resolve()), str(clone))
        git(clone, 'checkout', '--quiet', '--detach', base_sha)
        merged = git(clone, '-c', 'user.name=Lane preflight', '-c', 'user.email=lane@localhost',
                     'merge', '--no-commit', '--no-ff', head, check=False)
        if merged.returncode == 0:
            return []
        paths = git(clone, 'diff', '--name-only', '--diff-filter=U', '-z').stdout
        conflicts = [path for path in paths.split('\0') if path]
        if not conflicts:
            raise subprocess.CalledProcessError(merged.returncode, merged.args, merged.stdout, merged.stderr)
        return conflicts


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo

    def api(self, path: str, *args: str):
        result = subprocess.run(['gh', 'api', path, *args], capture_output=True, text=True, check=True)
        return result.stdout

    def pages(self, path: str, selector: str = '.[] | @json') -> list[dict]:
        return [json.loads(line) for line in self.api(path, '--paginate', '--jq', selector).splitlines()]

    def pulls(self) -> list[dict]:
        return self.pages(f'repos/{self.repo}/pulls?state=open&base=next&per_page=100')

    def cancel_queued_lane_runs(self, number: int, head: str) -> None:
        # next can move after the preflight released a Mac job into the queue. Removing a label
        # doesn't unschedule that job. Cancel only this head's lane runs with no job running.
        runs = self.pages(f'repos/{self.repo}/actions/workflows/lane.yml/runs?event=pull_request_target'
                          '&per_page=100', selector='.workflow_runs[] | @json')
        for run in runs:
            if (str(run['id']) == os.environ.get('GITHUB_RUN_ID')
                    or run['status'] == 'completed'
                    or run.get('display_title') != f'Lane PR #{number} head {head}'):
                continue
            jobs = self.pages(f'repos/{self.repo}/actions/runs/{run["id"]}/jobs?per_page=100',
                              selector='.jobs[] | @json')
            pending = [job for job in jobs if job['status'] != 'completed']
            if pending and all(job['status'] in {'queued', 'waiting', 'pending'} for job in pending):
                self.api(f'repos/{self.repo}/actions/runs/{run["id"]}/cancel', '-X', 'POST')

    def pull(self, number: int) -> dict:
        return json.loads(self.api(f'repos/{self.repo}/pulls/{number}'))

    def base_sha(self, base: str) -> str:
        return json.loads(self.api(f'repos/{self.repo}/branches/{quote(base, safe="")}'))['commit']['sha']

    def comments(self, number: int) -> list[dict]:
        return self.pages(f'repos/{self.repo}/issues/{number}/comments?per_page=100')

    def comment(self, number: int, body: str) -> None:
        self.api(f'repos/{self.repo}/issues/{number}/comments', '-f', f'body={body}')

    def add_label(self, number: int, name: str) -> None:
        self.api(f'repos/{self.repo}/issues/{number}/labels', '-X', 'POST', '-f', f'labels[]={name}')

    def remove_label(self, number: int, name: str) -> None:
        self.api(f'repos/{self.repo}/issues/{number}/labels/{quote(name, safe="")}', '-X', 'DELETE')


def labels(pull: dict) -> set[str]:
    return {label['name'] for label in pull.get('labels', [])}


def eligible(pull: dict, repo: str, base: str, request: bool = False) -> bool:
    return (pull.get('state') == 'open' and pull['base']['ref'] == base
            and (pull['head'].get('repo') or {}).get('full_name') == repo
            and (request or bool(labels(pull) & ARMED)))


def check_pull(github: GitHub, number: int, tree: Path, *, expected_head: str = '',
               base: str = 'next', request: bool = False) -> bool:
    pull = github.pull(number)
    head = pull['head']['sha']
    if not eligible(pull, github.repo, base, request) or (expected_head and expected_head != head):
        return False
    fetch_pull(tree, number, base)
    base_sha = git(tree, 'rev-parse', f'origin/{base}').stdout.strip()
    conflicts = conflicting_files(tree, base_sha, head)
    current = github.pull(number)
    if (not eligible(current, github.repo, base, request) or current['head']['sha'] != head
            or github.base_sha(base) != base_sha):
        print(f'#{number}: head, base or request moved; ignoring stale preflight')
        return False
    if not conflicts:
        print(f'#{number}: merges cleanly into {base} ({base_sha[:7]})')
        return True
    marker = f'<!-- lane-conflicts:{head}:{base_sha} -->'
    already_reported = any(marker in comment.get('body', '')
                           and comment.get('user', {}).get('login') == 'github-actions[bot]'
                           for comment in github.comments(number))
    # Remove queue labels before posting: a comment API failure must not leave a known conflict armed.
    names = labels(current)
    if 'needs-mac' not in names:
        github.add_label(number, 'needs-mac')
    for name in ('lane:queued', 'automerge'):
        if name in names:
            github.remove_label(number, name)
    if not already_reported:
        files = ', '.join(json.dumps(path, ensure_ascii=False) for path in conflicts)
        github.comment(number, f'Lane: `{head[:7]}` conflicts with {base} at `{base_sha[:7]}`: {files}. '
                       'Removed lane:queued and automerge; needs-mac asks the finisher to resolve it.\n' + marker)
    github.cancel_queued_lane_runs(number, head)
    print(f'#{number}: conflict; removed from the Mac queues')
    return False


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=Path, default=Path.cwd())
    parser.add_argument('--pr', type=int)
    parser.add_argument('--event-head', default='')
    parser.add_argument('--base', default='next')
    parser.add_argument('--request', action='store_true', help='/lane comment, possibly before lane:queued')
    args = parser.parse_args(argv)
    github = GitHub(os.environ['GH_REPO'])
    if args.pr:
        clean = check_pull(github, args.pr, args.tree, expected_head=args.event_head,
                           base=args.base, request=args.request)
    else:
        clean = True
        for pull in github.pulls():
            if eligible(pull, github.repo, 'next'):
                clean = check_pull(github, pull['number'], args.tree) and clean
    if output := os.environ.get('GITHUB_OUTPUT'):
        with open(output, 'a') as handle:
            handle.write(f'clean={str(clean).lower()}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
