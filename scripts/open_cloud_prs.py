#!/usr/bin/env python3
"""Open the pull request for a branch a cloud session pushed, as the project's GitHub App (#4915, route 1).

Why: a cloud session reaches GitHub only through the cloud's proxy, which puts the owner's credential on every request
(probe of 2026-11-23, #4915). A PR the session opens is therefore authored by the owner, and GitHub never lets a PR's
author approve it, so the owner could not approve cloud PRs that touch the files he holds (.github/CODEOWNERS). So a
cloud session only pushes, and .github/workflows/open-cloud-prs.yml, which runs from `main` only, opens the PR as
`spoken-margins-agent[bot]`.

How a session asks: the newest commits of its branch include a *request commit*: an empty commit (it changes no file;
`git commit --allow-empty` with nothing staged) whose message is

    PR: <the PR title>

    <the PR body, markdown, with `Closes #N` or `Part of #N`>

    PR-Labels: automerge          (optional; only the labels in ALLOWED_LABELS are applied)
    Signed-off-by: ...

A branch is picked only when all of these hold (`pick`): its name starts with `claude/`; its newest commit is at most
MAX_AGE_DAYS old; no PR, open, closed or merged, ever had it as its head; and one of its newest HISTORY commits *ahead
of `main`* is a request commit. Only commits ahead of `main` count: merged PRs leave their request commits on `main`, so
every branch cut from it carries old ones in its history. Nothing from the branch is checked out or run: its commits
are read as API data (GraphQL `compare` from `main`), and the title and body go to GitHub as JSON strings.

Two modes, two tokens (see the workflow):
  * `find` reads with the workflow's own read-only token and prints the picked branch names as JSON. One GraphQL page
    per 100 `claude/` branches, then the first lines of the commits ahead of `main` for the recent ones with no PR, then
    full messages for the few whose first lines include a request.
  * `open --only <json>` runs with the App token. It re-reads those branches the same way (never trusting the find
    job's output for anything but which names to look at), opens the PR and adds the allowed labels.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass

PREFIX = 'claude/'
BASE = 'main'
MAX_AGE_DAYS = 7
HISTORY = 20
ALLOWED_LABELS = frozenset({'automerge'})
# Branch names GitHub allows that are also safe to echo into a summary; a workflow_dispatch input is held to this too.
BRANCH_RE = re.compile(r'^claude/[A-Za-z0-9._/-]{1,200}$')
SUBJECT_RE = re.compile(r'^PR:[ \t]*(?P<title>\S.*?)\s*$')
HEADLINE_RE = re.compile(r'^PR:[ \t]*\S')
TRAILER_RE = re.compile(r'^(?P<key>[A-Za-z][A-Za-z0-9-]*):[ \t]*(?P<value>.*?)\s*$')
TRAILER_KEYS = {'signed-off-by', 'co-authored-by', 'pr-labels'}
TITLE_MAX = 200
BODY_MAX = 60_000  # GitHub's limit is 65,536 characters; leave room for the footer


@dataclass(frozen=True)
class Request:
    title: str
    body: str
    labels: tuple[str, ...]


def parse_request(message: str | None) -> Request | None:
    """The PR a request commit asks for, or None when the message is not one (or asks for an empty title or body)."""
    lines = (message or '').replace('\r\n', '\n').split('\n')
    match = SUBJECT_RE.match(lines[0]) if lines else None
    if not match:
        return None
    title = match.group('title')[:TITLE_MAX]
    rest = lines[1:]
    # Trailers: known-key lines peeled off the bottom of the message. Peeling line by line, not by paragraph, also
    # removes a `Signed-off-by` that `git commit -s` glued onto a body paragraph ending in a `Key: value` line.
    labels: list[str] = []
    end = len(rest)
    while end:
        line = rest[end - 1]
        m = TRAILER_RE.match(line)
        if not line.strip():
            end -= 1
        elif m and m.group('key').lower() in TRAILER_KEYS:
            if m.group('key').lower() == 'pr-labels':
                for label in re.split(r'[,\s]+', m.group('value')):
                    if label in ALLOWED_LABELS and label not in labels:
                        labels.append(label)
            end -= 1
        else:
            break
    body = '\n'.join(rest[:end]).strip('\n')
    if not body.strip():
        return None
    return Request(title=title, body=body[:BODY_MAX], labels=tuple(labels))


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def recent_without_pr(refs: list[dict], now: dt.datetime, max_age_days: int = MAX_AGE_DAYS) -> list[str]:
    """Full branch names (`claude/...`) that are recent and have never been a PR's head. `refs` are GraphQL ref nodes
    from refs(refPrefix: "refs/heads/claude/"), whose `name` lacks the prefix."""
    names = []
    for ref in refs:
        name = PREFIX + (ref.get('name') or '')
        target = ref.get('target') or {}
        when = target.get('committedDate')
        if not BRANCH_RE.match(name) or not when:
            continue
        if (ref.get('associatedPullRequests') or {}).get('totalCount', 1) != 0:
            continue
        if now - parse_time(when) > dt.timedelta(days=max_age_days):
            continue
        names.append(name)
    return sorted(names)


def is_empty(commit: dict) -> bool:
    """A request commit changes no file (`git commit --allow-empty`), so an ordinary commit that happens to start with
    `PR:` (say "PR: tidy review notes" plus a paragraph) never opens a PR nobody asked for. Missing counts as not empty."""
    return commit.get('additions') == 0 and commit.get('deletions') == 0 and not commit.get('changedFilesIfAvailable')


def find_request(history: list[dict]) -> tuple[str, Request] | None:
    """(oid, request) for the newest request commit among a branch's newest commits ahead of `main` (newest first)."""
    for commit in history:
        if not is_empty(commit):
            continue
        request = parse_request(commit.get('message'))
        if request:
            return commit.get('oid') or '', request
    return None


def pick(refs: list[dict], histories: dict[str, list[dict]], now: dt.datetime,
         max_age_days: int = MAX_AGE_DAYS) -> list[str]:
    """Branch names that should get a PR, from the ref list and each branch's newest commits ahead of `main`."""
    return [name for name in recent_without_pr(refs, now, max_age_days) if find_request(histories.get(name) or [])]


def pr_body(request: Request, branch: str, oid: str) -> str:
    return (f'{request.body}\n\n---\n_Opened by `open-cloud-prs` for branch `{branch}` from request commit '
            f'{oid[:9]} (#4915): the session pushed, and the project\'s App opened the PR so the owner can review it._')


# ---------------------------------------------------------------------------------------------------- GitHub I/O

REFS_QUERY = '''query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    refs(refPrefix: "refs/heads/claude/", first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { name associatedPullRequests(states: [OPEN, CLOSED, MERGED]) { totalCount }
              target { ... on Commit { committedDate } } }
    }
  }
}'''


def branches_query(names: list[str], full: bool = True) -> str:
    """For each branch: the ref (PR count, commit date) and its newest HISTORY commits ahead of `main`."""
    fields = ('oid message' if full else 'oid messageHeadline') + ' additions deletions changedFilesIfAvailable'
    refs, compares = [], []
    for i, name in enumerate(names):
        qualified = json.dumps('refs/heads/' + name)
        refs.append(f'r{i}: ref(qualifiedName: {qualified}) {{ name '
                    'associatedPullRequests(states: [OPEN, CLOSED, MERGED]) { totalCount } '
                    'target { ... on Commit { committedDate } } }')
        compares.append(f'c{i}: compare(headRef: {qualified}) {{ aheadBy commits(last: {HISTORY}) {{ nodes {{ {fields} }} }} }}')
    return ('query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { '
            + ' '.join(refs) + f' base: ref(qualifiedName: "refs/heads/{BASE}") {{ ' + ' '.join(compares) + ' } } }')


class GitHub:
    def __init__(self, repo: str, run=subprocess.run):
        self.owner, self.name = repo.split('/', 1)
        self.repo = repo
        self._run = run

    def _call(self, args: list[str], payload: dict | None = None):
        done = self._run(['gh', 'api', *args], input=json.dumps(payload) if payload is not None else None,
                         capture_output=True, text=True)
        try:
            answer = json.loads(done.stdout or 'null')
        except ValueError:
            answer = None
        return done, answer

    def _gh(self, args: list[str], payload: dict | None = None):
        done, answer = self._call(args, payload)
        if done.returncode != 0:
            # gh prints only "gh: Validation Failed (HTTP 422)" on stderr; GitHub's detail ("A pull request already
            # exists for ...") is in the JSON it prints on stdout. Keep both.
            detail = ' '.join(part.strip() for part in (done.stderr, done.stdout) if part and part.strip())
            raise RuntimeError(f"gh api {args[0]} failed: {detail[:600]}")
        return answer

    def graphql(self, query: str, allow_missing: bool = False, **variables):
        """GraphQL data. With allow_missing, NOT_FOUND errors (a branch deleted since it was listed) leave a null in the
        data instead of failing; gh exits non-zero for them but still prints the data."""
        payload = {'query': query, 'variables': {'owner': self.owner, 'name': self.name, **variables}}
        done, answer = self._call(['graphql', '--input', '-'], payload)
        errors = (answer or {}).get('errors') or []
        tolerated = allow_missing and errors and all(e.get('type') == 'NOT_FOUND' for e in errors)
        if not isinstance(answer, dict) or answer.get('data') is None or (errors and not tolerated) \
                or (done.returncode != 0 and not tolerated):
            detail = json.dumps(errors)[:300] if errors else (done.stderr or done.stdout or '').strip()[:300]
            raise RuntimeError(f'GraphQL failed: {detail}')
        return answer['data']

    def claude_refs(self) -> list[dict]:
        refs, after = [], None
        while True:
            page = self.graphql(REFS_QUERY, after=after)['repository']['refs']
            refs.extend(page['nodes'])
            if not page['pageInfo']['hasNextPage']:
                return refs
            after = page['pageInfo']['endCursor']

    def branches(self, names: list[str], full: bool = True) -> tuple[list[dict], dict[str, list[dict]]]:
        """Ref nodes (prefix stripped, as claude_refs gives them) and, newest first, each branch's newest commits ahead
        of `main`: full messages, or only first lines (`messageHeadline`), which is all `find` needs for most."""
        refs, ahead = [], {}
        size = 25 if full else 50
        for start in range(0, len(names), size):
            chunk = names[start:start + size]
            repo = self.graphql(branches_query(chunk, full), allow_missing=True)['repository']
            base = repo.get('base') or {}
            for i, name in enumerate(chunk):
                node, comparison = repo.get(f'r{i}'), base.get(f'c{i}')
                if not node or not comparison:
                    continue  # deleted since it was listed
                refs.append({**node, 'name': name[len(PREFIX):]})
                commits = ((comparison.get('commits') or {}).get('nodes') or []) if comparison.get('aheadBy') else []
                ahead[name] = list(reversed(commits))  # compare lists oldest first
        return refs, ahead

    def open_pr(self, branch: str, request: Request, oid: str) -> int:
        answer = self._gh([f'repos/{self.repo}/pulls', '-X', 'POST', '--input', '-'],
                          {'title': request.title, 'head': branch, 'base': BASE, 'body': pr_body(request, branch, oid)})
        return answer['number']

    def add_labels(self, number: int, labels: tuple[str, ...]) -> None:
        self._gh([f'repos/{self.repo}/issues/{number}/labels', '-X', 'POST', '--input', '-'], {'labels': list(labels)})


def has_request_headline(history: list[dict]) -> bool:
    """Cheap first pass: does any of these commits' first line look like `PR: <title>`?"""
    return any(HEADLINE_RE.match(c.get('messageHeadline') or '') and is_empty(c) for c in history)


def find(gh: GitHub, now: dt.datetime, extra: list[str] | None = None) -> list[str]:
    """Most recent `claude/` branches have no PR and never ask for one (188 of 338 on 2026-11-23), so first read only
    first lines, then full messages for the few branches whose first lines include a request.

    Every run is a full sweep, a dispatch for one branch included (`extra` only adds names): the VPS backstop and the
    sweep's rule 15 count any run as one, so a branch-only run must not leave another session's failed dispatch behind."""
    names = sorted(set(recent_without_pr(gh.claude_refs(), now)) | set(extra or []))
    if not names:
        return []
    _, headlines = gh.branches(names, full=False)
    asking = [name for name in names if has_request_headline(headlines.get(name) or [])]
    if not asking:
        return []
    refs, ahead = gh.branches(asking)
    return pick(refs, ahead, now)


def open_prs(gh: GitHub, names: list[str], now: dt.datetime, log=print) -> tuple[list[tuple[str, int]], int]:
    """Open each qualifying branch's PR. Returns (opened, failures); a failure is a PR or label call GitHub refused."""
    opened, failures = [], 0
    wanted = sorted({n for n in names if BRANCH_RE.match(n)})
    if not wanted:
        return opened, failures
    refs, ahead = gh.branches(wanted)
    for name in pick(refs, ahead, now):
        oid, request = find_request(ahead[name])
        try:
            number = gh.open_pr(name, request, oid)
        except RuntimeError as err:
            if 'already exists' in str(err):  # a run that raced this one opened it
                log(f'{name}: already has a PR')
            else:
                log(f'{name}: not opened: {err}')
                failures += 1
            continue
        line = f'{name}: opened #{number} "{request.title}"'
        if request.labels:
            try:
                gh.add_labels(number, request.labels)
                line += f' with {", ".join(request.labels)}'
            except RuntimeError as err:  # the PR exists now, so no later run retries the label
                line += f'; labels {", ".join(request.labels)} NOT added ({err}): add them by hand'
                failures += 1
        log(line)
        opened.append((name, number))
    return opened, failures


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('mode', choices=['find', 'open'])
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', 'Spoken-Margins/spoken-margins-native'))
    parser.add_argument('--only', help='JSON list of branch names to look at (open: required)')
    parser.add_argument('--branch', default='', help='one branch to look at (workflow_dispatch input); empty = all')
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    gh = GitHub(args.repo)
    if args.branch and not BRANCH_RE.match(args.branch):
        print(f'not a claude/ branch name: {args.branch!r}', file=sys.stderr)
        return 2
    if args.mode == 'find':
        names = find(gh, now, [args.branch] if args.branch else None)
        print(json.dumps(names))
        return 0
    names = json.loads(args.only or '[]')
    if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
        print('--only must be a JSON list of strings', file=sys.stderr)
        return 2
    lines = []
    opened, failures = open_prs(gh, names, now, log=lambda line: (print(line), lines.append(line)))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as fh:
            fh.write('\n'.join(['## open-cloud-prs', *[f'- {line}' for line in lines or ['nothing to open']]]) + '\n')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
