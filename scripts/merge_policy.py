#!/usr/bin/env python3
"""The "merge policy" check: the merge rules GitHub has no setting for, for its merge queue (#4693).

GitHub's merge queue tests the exact merge and merges it. Four of the lane's rules are not a GitHub setting, so this
one check carries them, on the PR and again in the queue:

1. Audio, persistence, packet and lane changes need a clean Codex or Claude audit of the PR's head
   (scripts/lane_merge_rules.py merge_blockers and audit_blocker).
2. A PR that brings in another PR's commit with a blocking audit is held until that finding is resolved
   (lane_merge_rules.py inherited_check, scripts/lane_inherited_holds.py).
3. A PR touching `.github/` or `scripts/lane_merge_rules.py` merges only with the owner's tap:
   the `owner-tap` label, which only the owner adds (lane_merge_rules.py owner_tap_paths; owner rule 2026-10-09, #1203).
4. An outside contributor's commits carry `Signed-off-by:` (scripts/signoff_check.py, #2114).

The rules themselves are not copied here: they are imported from lane_merge_rules.py, test-scope.py and signoff_check.py
in the same checkout, which the workflow takes from main, never from the PR. The PR's commits are fetched as git data
and only read.

pull_request: the PR's head. merge_group: every PR in the group, i.e. the queue entries up to and including the one
whose head commit is the group's head (GraphQL mergeQueue.entries). A GitHub read is tried ATTEMPTS times; one that
still fails blocks (fail closed), so a blip removes a PR from the queue rather than waving it through.

Prints one line per PR: "may merge" or the reasons it can't. Exit 1 if any PR is blocked or anything couldn't be read.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import types

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

OWNER_TAP_LABEL = 'owner-tap'
ATTEMPTS = 3
RETRY_WAIT = 10  # seconds, doubled after each failed try
QUEUE_QUERY = '''query($owner: String!, $name: String!, $branch: String!) {
  repository(owner: $owner, name: $name) {
    mergeQueue(branch: $branch) {
      entries(first: 100) { nodes { position headCommit { oid } pullRequest { number headRefOid } } }
    }
  }
}'''


class ReadFailed(RuntimeError):
    """A GitHub or git read that still failed after its retries."""


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_MODULES: dict[str, types.ModuleType] = {}


def rules():
    """scripts/lane_merge_rules.py, where the audit, inherited-hold and owner-tap rules live (one copy, #4769)."""
    if 'rules' not in _MODULES:
        _MODULES['rules'] = _load('lane_merge_rules_for_merge_policy', 'lane_merge_rules.py')
    return _MODULES['rules']


def scope_policy():
    if 'scope' not in _MODULES:
        _MODULES['scope'] = _load('test_scope_for_merge_policy', 'test-scope.py')
    return _MODULES['scope']


class GitHub:
    """`gh api` reads with retries. run and sleep are injected in tests."""

    def __init__(self, repo: str, run=subprocess.run, sleep=time.sleep, attempts: int = ATTEMPTS):
        self.repo, self.run, self.sleep, self.attempts = repo, run, sleep, attempts

    def _gh(self, args: list[str]) -> str:
        problem, wait = '', RETRY_WAIT
        for attempt in range(self.attempts):
            if attempt:
                self.sleep(wait)
                wait *= 2
            try:
                done = self.run(['gh', *args], capture_output=True, text=True, timeout=120)
            except (OSError, subprocess.SubprocessError) as error:
                problem = str(error)[:200]
                continue
            if done.returncode == 0:
                return done.stdout
            problem = (done.stderr or '').strip()[:200]
        raise ReadFailed(f'gh {" ".join(args[:2])} failed {self.attempts} times: {problem}')

    def api(self, path: str, paginate: bool = False):
        args = ['api', path] + (['--paginate', '--jq', '.[]'] if paginate else [])
        out = self._gh(args)
        try:
            return [json.loads(line) for line in out.splitlines() if line.strip()] if paginate else json.loads(out)
        except ValueError as error:
            raise ReadFailed(f'gh api {path}: not JSON ({error})') from error

    def graphql(self, query: str, **fields: str):
        args = ['api', 'graphql', '-f', f'query={query}']
        for key, value in fields.items():
            args += ['-F', f'{key}={value}']
        try:
            return json.loads(self._gh(args))
        except ValueError as error:
            raise ReadFailed(f'gh api graphql: not JSON ({error})') from error

    def pull(self, number: int) -> dict:
        return self.api(f'repos/{self.repo}/pulls/{number}')

    def comments(self, number: int) -> list[dict]:
        """The PR's comments that the lane trusts (owner, members, collaborators, the project's bot)."""
        found = self.api(f'repos/{self.repo}/issues/{number}/comments?per_page=100', paginate=True)
        return [c for c in found if rules().trusted_comment(c)]

    def queue_entries(self, branch: str) -> list[dict]:
        owner, name = self.repo.split('/', 1)
        data = self.graphql(QUEUE_QUERY, owner=owner, name=name, branch=branch)
        queue = ((data.get('data') or {}).get('repository') or {}).get('mergeQueue')
        if queue is None:
            raise ReadFailed(f'{self.repo} has no merge queue on {branch}' + (f': {data["errors"]}' if data.get('errors') else ''))
        return queue['entries']['nodes']


def group_prs(entries: list[dict], group_head: str) -> list[tuple[int, str]]:
    """(number, head) of each PR in the merge group whose head commit is <group_head>: the entries up to and including
    that one, in queue order. Raises ReadFailed when no entry has that head (the group left the queue, or a stale read)."""
    ordered = sorted(entries, key=lambda e: e.get('position') or 0)
    for index, entry in enumerate(ordered):
        if (entry.get('headCommit') or {}).get('oid') == group_head:
            return [(e['pullRequest']['number'], e['pullRequest']['headRefOid']) for e in ordered[:index + 1]]
    raise ReadFailed(f'no merge queue entry has the group head {group_head[:7]}')


def git(tree: Path, *args: str) -> str:
    done = subprocess.run(['git', '-C', str(tree), *args], capture_output=True, text=True)
    if done.returncode:
        raise ReadFailed(f'git {" ".join(args[:2])}: {done.stderr.strip()[:200]}')
    return done.stdout


def fetch_head(tree: Path, number: int, head: str, attempts: int = ATTEMPTS, sleep=time.sleep) -> None:
    """Make sure the PR's head commit is in <tree>, as data only."""
    if subprocess.run(['git', '-C', str(tree), 'cat-file', '-e', f'{head}^{{commit}}'], capture_output=True).returncode == 0:
        return
    problem = ''
    for attempt in range(attempts):
        if attempt:
            sleep(RETRY_WAIT)
        done = subprocess.run(['git', '-C', str(tree), 'fetch', '--no-tags', 'origin',
                               f'+refs/pull/{number}/head:refs/merge-policy/pr-{number}'], capture_output=True, text=True)
        if done.returncode == 0 and subprocess.run(['git', '-C', str(tree), 'cat-file', '-e', f'{head}^{{commit}}'],
                                                   capture_output=True).returncode == 0:
            return
        problem = done.stderr.strip()[:200] or f'{head[:7]} is not the fetched head'
    raise ReadFailed(f'could not fetch #{number} at {head[:7]}: {problem}')


def changes(tree: Path, base_ref: str, head: str) -> tuple[list[str], dict[str, str]]:
    """The PR's changed paths against its merge base with <base_ref>, both sides of a rename, and the SessionKit source
    diffs test-scope.py reads (as lane-runner.py committed_changes, for a commit instead of HEAD)."""
    merge_base = git(tree, 'merge-base', base_ref, head).strip()
    paths = [p for p in git(tree, 'diff', '--name-only', '--no-renames', '-z', merge_base, head).split('\0') if p]
    diffs, current = {}, None
    for line in git(tree, 'diff', '-U0', merge_base, head, '--', 'Packages/SessionKit/Sources').splitlines():
        if line.startswith('diff --git '):
            current = line.split(' b/', 1)[1]
            diffs[current] = ''
        elif current:
            diffs[current] += line + '\n'
    return sorted(set(paths)), diffs


def unsigned_commits(tree: Path, base_ref: str, head: str, association: str, login: str) -> list[dict]:
    import signoff_check
    raw = git(tree, 'log', f'--format=%H{signoff_check.FIELD}%P{signoff_check.FIELD}%ae{signoff_check.FIELD}%B'
                           f'{signoff_check.RECORD}', f'{base_ref}..{head}')
    return signoff_check.check(signoff_check.parse_log(raw), association, login)


def blockers(github: GitHub, tree: Path, base: str, number: int, head: str, classify=None, inherited=None) -> list[str]:
    """Why PR <number> at <head> may not merge into <base>, or [] when it may. classify and inherited are injected in
    tests; by default they are test-scope.py's classify and lane_merge_rules.py's inherited_check."""
    base_ref = f'origin/{base}'
    pull = github.pull(number)
    fetch_head(tree, number, head)
    paths, diffs = changes(tree, base_ref, head)
    scope = (classify or (lambda p, d: scope_policy().classify(p, d, root=tree)))(paths, diffs)
    comments = github.comments(number)
    if inherited is None:
        inherited = rules().inherited_check(types.SimpleNamespace(repo=github.repo, pr=number), tree, base, head)
    reasons = list(rules().merge_blockers(scope, comments, head, inherited))
    tap = rules().owner_tap_paths(scope)
    labels = {label.get('name') for label in pull.get('labels') or []}
    if tap and OWNER_TAP_LABEL not in labels:
        shown = ', '.join(f'`{p}`' for p in tap)
        reasons.append(f'it touches {shown}, which only the owner merges (owner rule 2026-10-09, #1203); '
                       f'it needs the `{OWNER_TAP_LABEL}` label, which only the owner adds')
    bad = unsigned_commits(tree, base_ref, head, pull.get('author_association') or '',
                           (pull.get('user') or {}).get('login') or '')
    if bad:
        reasons.append(f'{len(bad)} commit(s) have no `Signed-off-by:` line ({", ".join(c["sha"][:7] for c in bad)}); '
                       'see CONTRIBUTING.md')
    return reasons


def judge(github: GitHub, tree: Path, base: str, prs: list[tuple[int, str]], out=sys.stdout, **injected) -> int:
    """Print one line per PR and return the exit code: 0 when every PR may merge."""
    blocked = 0
    for number, head in prs:
        try:
            reasons = blockers(github, tree, base, number, head, **injected)
        except ReadFailed as error:
            reasons = [f'the check could not read what it needs ({error}), so it holds the merge']
        if reasons:
            blocked += 1
            print(f'#{number} at {head[:7]} may not merge: ' + '; '.join(reasons) + '.', file=out)
        else:
            print(f'#{number} at {head[:7]} may merge.', file=out)
    return 1 if blocked else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', ''))
    parser.add_argument('--base', default='main')
    parser.add_argument('--tree', type=Path, default=SCRIPTS.parent)
    parser.add_argument('--pr', type=int, help='one PR (pull_request, workflow_dispatch)')
    parser.add_argument('--head', default='', help="the PR's head commit; empty: the PR's current head")
    parser.add_argument('--group-head', default='', help="a merge group's head commit (merge_group)")
    args = parser.parse_args(argv)
    if not args.repo or not (args.pr or args.group_head):
        parser.error('--repo and one of --pr or --group-head are required')
    github = GitHub(args.repo)
    try:
        if args.group_head:
            prs = group_prs(github.queue_entries(args.base), args.group_head)
        else:
            prs = [(args.pr, args.head or github.pull(args.pr)['head']['sha'])]
    except ReadFailed as error:
        print(f'merge policy could not find the PRs to check ({error}), so it holds the merge.')
        return 1
    return judge(github, args.tree, args.base, prs)


if __name__ == '__main__':
    sys.exit(main())
