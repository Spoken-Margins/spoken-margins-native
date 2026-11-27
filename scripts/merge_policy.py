#!/usr/bin/env python3
"""The "merge policy" check: the merge rules GitHub has no setting for, for its merge queue (#4693).

GitHub's merge queue tests the exact merge and merges it. Four of the lane's rules are not a GitHub setting, so this
one check carries them, on the PR and again in the queue:

1. Audio, persistence, packet and lane changes need a clean Codex or Claude audit of the PR's head
   (scripts/lane_merge_rules.py merge_blockers and audit_blocker).
2. A PR that brings in another PR's commit with a blocking audit is held until that finding is resolved
   (lane_merge_rules.py inherited_check, scripts/lane_inherited_holds.py).
3. A PR touching `.github/` or `scripts/lane_merge_rules.py` merges only with the owner's tap (lane_merge_rules.py
   owner_tap_paths; owner rule 2026-10-09, #1203): the `owner-tap` label, which only the owner adds, or his approving
   review of the PR's current head (scripts/owner_review_tap.py; owner's decision 2026-11-24). His latest approve,
   request-changes or dismissed review decides; a request for changes, a dismissal, an approval of an older commit or
   anyone else's review is no tap. The reviews are read only for such a PR without the label, one paginated call. In a
   merge group the approval must be on the PR's own head, not the group's merge commit.
4. An outside contributor's commits carry `Signed-off-by:` (scripts/signoff_check.py, #2114).
5. A PR that changes `Packages/SessionKit/Package.resolved` without `Packages/SessionKit/Package.swift` is held: SwiftPM
   on Linux rewrites that file and drops the Mac's pins (#4972; the rewrite reached #4965 and #4970).
6. A PR whose body says `Closes #N` for a listener-facing issue is held until a real-use proof (or a waiver) is recorded
   on the PR or the issue, and the proof still covers the PR's code (scripts/real_use_proof.py, #4979). `Part of #N`
   is never held: a fix that can't be run before the merge says so, and the issue closes later with its proof.

The rules themselves are not copied here: they are imported from lane_merge_rules.py, test-scope.py and signoff_check.py
in the same checkout, which the workflow takes from main, never from the PR. The PR's commits are fetched as git data
and only read.

pull_request: the PR's head. merge_group: every PR in the group, i.e. the queue entries up to and including the one
whose head commit is the group's head (GraphQL mergeQueue.entries). A GitHub read is tried ATTEMPTS times; one that
still fails blocks (fail closed), so a blip removes a PR from the queue rather than waving it through. A read refused
because the hour's API budget is spent waits for the budget to reset and reads again (#4990), so that hold clears
itself; the check shows as running meanwhile. The search API's own small budget (about 30 a minute, shared by every
run at once) and a secondary limit are waited out the same way, and one run searches once for all its PRs (#5224).

Prints one line per PR: "may merge" or the reasons it can't. Exit 1 if any PR is blocked or anything couldn't be read.

With --report-sha (the workflow, #4986) it also posts the verdict as a commit status with the context `merge policy` on
that commit (the Statuses API, #5162: a check run made through the Checks API landed in whichever check suite came first
on the commit, and the merge queue did not count it when that was the label bridge's). The Actions job that runs it is
named differently, so the required check is the one this script writes. A PR on the `pull_request` event held only for
an audit that isn't there yet, or for the owner's tap, gets that status left `pending` ("waiting") instead of failed: no
runner waits, because the job ends, and the audit's re-run, the owner's label event or his review event posts the next
verdict. Any other
hold is `failure`, a merge group never waits (a held entry has to leave the queue), a read that failed is `failure`,
and a cancel is `error`. The status is posted `pending` first and the verdict last, so a run that is cancelled or
killed between them leaves it pending (blocked), never a stale pass. In this mode the exit code is 0 for a pass or a
wait and 1 for a failure, so the job is red only when the status is.

With --start (pull_request runs, #4867) it also starts any dispatchable required check (scripts/required_checks.py) that
has no run on the head, and says "not started" for each. A required check that never ran waits for nobody, so the policy
starts it; that is a note, not a block, and it never changes the exit code. A run that is going, or that finished with
any verdict, is left alone.
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import types
import urllib.parse

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import owner_review_tap  # noqa: E402

OWNER_TAP_LABEL = 'owner-tap'
CHECK_NAME = 'merge policy'  # the required check; the workflow's job is named differently so only this script writes it
OWNER_TAP_MARK = 'which only the owner merges'  # in the owner-tap reason (blockers); is_waiting() reads it
SESSIONKIT_RESOLVED = 'Packages/SessionKit/Package.resolved'
SESSIONKIT_MANIFEST = 'Packages/SessionKit/Package.swift'
ATTEMPTS = 3
RETRY_WAIT = 10  # seconds, doubled after each failed try
START_RECHECK_WAIT = 60  # seconds: the PR's own checks start with this one, so a run not yet listed gets this long to appear
# #4990: a read refused because the hour's API budget is spent is waited out, not failed. On 2026-11-22 the check held
# two owner-tapped PRs (#4985, #4983) with "API rate limit exceeded for installation", and a re-run 19 minutes later
# hit the same limit; nothing but a person re-running it after the reset would have cleared the hold.
RATE_LIMITED = 'api rate limit exceeded'  # the primary limit; a secondary ("abuse") limit is retried as any failure
RATE_WAIT_SLACK = 20  # seconds past the reset, so the first call lands inside the new window
# The longest wait for a reset, in seconds. The workflow file sets RATE_LIMIT_WAIT with a job time limit that fits it;
# a PR whose branch has an older copy of the workflow (15-minute limit) gets this default.
DEFAULT_RATE_WAIT = 600
# #5224: a secondary ("abuse") limit names no reset; GitHub asks for a wait of at least a minute before trying again.
# The search API, which every run at once shares, ran out on 2026-11-23 and the inherited-holds lookup, which read
# GitHub without retrying, failed whole merge groups (run 45291666840).
SECONDARY_LIMITED = 'secondary rate limit'
SECONDARY_WAIT = 61
SEARCH_PAGES = 10  # GitHub search answers at most 1000 results; lane_inherited_holds.SEARCH_PAGES is the same
SINCE = re.compile(r'\s*updated:>=(\d{4}-\d{2}-\d{2})')
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

    def __init__(self, repo: str, run=subprocess.run, sleep=time.sleep, attempts: int = ATTEMPTS, clock=time.time,
                 rate_wait: float | None = None, out=sys.stderr):
        self.repo, self.run, self.sleep, self.attempts, self.clock, self.out = repo, run, sleep, attempts, clock, out
        self.rate_wait = rate_wait_from_env() if rate_wait is None else rate_wait

    def _try(self, args: list[str]) -> tuple[bool, str]:
        try:
            done = self.run(['gh', *args], capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.SubprocessError) as error:
            return False, str(error)[:200]
        return (True, done.stdout) if done.returncode == 0 else (False, failure_text(done.stderr, done.stdout))

    def _reset_wait(self, args: list[str]) -> float | None:
        """Seconds until the spent budget's window resets, or None when that can't be read. `rate_limit` is the one
        read GitHub does not count against the budget."""
        resource = 'graphql' if 'graphql' in args else 'search' if any(a.startswith('search/') for a in args) else 'core'
        ok, text = self._try(['api', 'rate_limit', '--jq', f'.resources.{resource}.reset'])
        try:
            return max(0.0, float(text.strip()) - self.clock()) + RATE_WAIT_SLACK if ok else None
        except ValueError:
            return None

    def _gh(self, args: list[str], attempts: int | None = None) -> str:
        attempts = attempts or self.attempts
        problem, wait, waited_for_reset = '', RETRY_WAIT, False
        for attempt in range(attempts):
            if attempt:
                self.sleep(wait)
                wait *= 2
            ok, text = self._try(args)
            if not ok and RATE_LIMITED in text.lower() and not waited_for_reset and attempts > 1:
                # Once per read, and not for a single-try POST. Too long a wait, or an unreadable reset, fails as before.
                waited_for_reset, reset_in = True, self._reset_wait(args)
                if reset_in is not None and reset_in <= self.rate_wait:
                    print(f'GitHub API budget spent; waiting {int(reset_in)} seconds for it to reset, then reading again.',
                          file=self.out, flush=True)
                    self.sleep(reset_in)
                    ok, text = self._try(args)
            elif not ok and SECONDARY_LIMITED in text.lower() and not waited_for_reset and attempts > 1:
                waited_for_reset, pause = True, min(SECONDARY_WAIT, self.rate_wait)
                print(f'GitHub secondary rate limit; waiting {int(pause)} seconds, then reading again.',
                      file=self.out, flush=True)
                self.sleep(pause)
                ok, text = self._try(args)
            if ok:
                return text
            problem = text
        raise ReadFailed(f'gh {" ".join(args[:2])} failed {attempts} times: {problem}')

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

    def workflow_runs(self, workflow: str, sha: str) -> list[dict]:
        """The runs of <workflow> on commit <sha>, of any event."""
        found = self.api(f'repos/{self.repo}/actions/workflows/{workflow}/runs?head_sha={sha}&per_page=100')
        return (found or {}).get('workflow_runs') or []

    def run_jobs(self, run_id: int) -> list[dict]:
        """The jobs of one workflow run, each with its own conclusion."""
        found = self.api(f'repos/{self.repo}/actions/runs/{run_id}/jobs?per_page=100')
        return (found or {}).get('jobs') or []

    def dispatch(self, workflow: str, ref: str, inputs: dict[str, str]) -> None:
        """workflow_dispatch <workflow> on branch <ref>. One try: a POST that landed but answered late must not start twice."""
        args = ['api', '-X', 'POST', f'repos/{self.repo}/actions/workflows/{workflow}/dispatches', '-f', f'ref={ref}']
        for name, value in inputs.items():
            args += ['-f', f'inputs[{name}]={value}']
        self._gh(args, attempts=1)

    def issue(self, number: int) -> dict:
        return self.api(f'repos/{self.repo}/issues/{number}')

    def issue_comments(self, number: int) -> list[dict]:
        """An issue's comments that the lane trusts (the same filter as `comments`, for a PR's issue)."""
        return self.comments(number)

    def issue_timeline(self, number: int) -> list[dict]:
        """An issue's timeline events: the last `reopened` one ends every proof written before it (#4979)."""
        return self.api(f'repos/{self.repo}/issues/{number}/timeline?per_page=100', paginate=True)

    def reviews(self, number: int) -> list[dict]:
        """The PR's reviews, every page (the owner's approval is his tap, owner_review_tap.py)."""
        return self.api(f'repos/{self.repo}/pulls/{number}/reviews?per_page=100', paginate=True)

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


def failure_text(stderr: str, stdout: str) -> str:
    """Why a `gh` call failed: its stderr, plus the `message` of the error body `gh api` prints on stdout when stderr
    lacks it (#5224), so a rate limit is recognised and reported whichever stream carries it."""
    text = (stderr or '').strip()
    try:
        message = json.loads(stdout or '').get('message') or ''
    except (ValueError, AttributeError):
        message = ''
    if message and message not in text:
        text = f'{text} {message}'.strip()
    return text[:300]


class SharedReads:
    """The inherited-holds lookup's GitHub reads for one run, shared by every PR the run judges (#5224).

    Reads go through GitHub, so they are retried and wait out a spent budget, and a read that still fails raises
    ReadFailed, which holds the PR (fail closed). A search is read in full once per query and later answered from
    memory: a PR whose new commits are newer asks `updated:>=` a later day, which is the same answer filtered by
    `updated_at`. A PR asking an earlier day than any search so far gets a new search. Other reads are kept by path.

    Before this, each PR ran its own two searches (a group of six, twelve or more), and every merge-policy run at once
    drew on the same search budget of about 30 a minute; one refusal failed the whole merge group (run 45291666840)."""

    def __init__(self, github: 'GitHub'):
        self.github, self.searches, self.reads = github, {}, {}

    def __call__(self, path: str, paginate: bool = False):
        if path.startswith('search/'):
            return self._search(path)
        key = (path, paginate)
        if key not in self.reads:
            self.reads[key] = self.github.api(path, paginate)
        return self.reads[key]

    def _search(self, path: str) -> dict:
        split = urllib.parse.urlsplit(path)
        params = dict(urllib.parse.parse_qsl(split.query, keep_blank_values=True))
        found = SINCE.search(params.get('q', ''))
        if not found:
            return self.github.api(path)  # not the shape it shares: read as asked
        since = found.group(1)
        key = (split.path, SINCE.sub('', params['q']).strip(), params.get('sort'), params.get('order'))
        held = self.searches.get(key)
        if held is None or since < held[0]:
            held = self.searches[key] = (since, self._every_page(split.path, params))
        items = [item for item in held[1] if (item.get('updated_at') or '9999')[:10] >= since]
        page = int(params.get('page') or 1)
        return {'total_count': len(items), 'incomplete_results': False, 'items': items if page == 1 else []}

    def _every_page(self, path: str, params: dict) -> list[dict]:
        items = []
        for page in range(1, SEARCH_PAGES + 1):
            query = urllib.parse.urlencode({**params, 'per_page': '100', 'page': str(page)}, quote_via=urllib.parse.quote)
            result = self.github.api(f'{path}?{query}')
            if result.get('incomplete_results'):
                raise ReadFailed('GitHub search answered incompletely')
            items += result.get('items') or []
            if page * 100 >= (result.get('total_count') or 0):
                return items
        raise ReadFailed(f'more than {SEARCH_PAGES * 100} results to look through ({params.get("q", "")})')


def rate_wait_from_env() -> float:
    try:
        return max(0.0, float(os.environ.get('RATE_LIMIT_WAIT', '')))
    except ValueError:
        return DEFAULT_RATE_WAIT


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


def commit_messages(tree: Path, base_ref: str, head: str) -> str:
    """The messages of the PR's own commits, which GitHub also reads for closing keywords."""
    return git(tree, 'log', '--format=%B', f'{base_ref}..{head}')


def unsigned_commits(tree: Path, base_ref: str, head: str, association: str, login: str) -> list[dict]:
    import signoff_check
    raw = git(tree, 'log', f'--format=%H{signoff_check.FIELD}%P{signoff_check.FIELD}%ae{signoff_check.FIELD}%B'
                           f'{signoff_check.RECORD}', f'{base_ref}..{head}')
    return signoff_check.check(signoff_check.parse_log(raw), association, login)


def resolved_rewrite(paths: list[str]) -> str | None:
    """#4972: why the pins file may not change on its own, or None. A deliberate dependency bump edits Package.swift in
    the same PR; a Package.resolved that moves alone is SwiftPM on Linux rewriting it, which drops the pins the Mac
    needs and passes every fast check (it fails only on `main-t3` or the phone build after the merge)."""
    if SESSIONKIT_RESOLVED in paths and SESSIONKIT_MANIFEST not in paths:
        return (f'it changes `{SESSIONKIT_RESOLVED}` but not `{SESSIONKIT_MANIFEST}`; SwiftPM on Linux rewrites that '
                f'file and drops the Mac\'s pins. Put it back with `git checkout origin/main -- {SESSIONKIT_RESOLVED}` '
                '(merge `main` first if the branch is behind and main changed it) and push; on Linux run scripts/run-sessionkit-linux-tests.sh and stage files by path, not `git add -A`')
    return None


def proof_blockers(github: GitHub, tree: Path, base_ref: str, number: int, head: str, pull: dict,
                   comments: list[dict]) -> list[str]:
    """#4979: the real-use proof a `Closes #N` PR needs for a listener-facing issue. A PR that names no closing issue
    costs nothing here. ReadFailed from a read propagates (the merge is held); any other failure inside the proof
    check holds only this PR, and says so, so a bug in the rule cannot hide behind a pass."""
    import real_use_proof
    # GitHub also closes an issue on a `Closes #N` in a commit message when the squash message carries it.
    messages = commit_messages(tree, base_ref, head)
    if not real_use_proof.closing_issues((pull.get('body') or '') + '\n' + messages, number, github.repo):
        return []
    def own_commits() -> list[str]:
        return git(tree, 'rev-list', f'{base_ref}..{head}').split()
    def paths_after(commit: str) -> list[str]:
        # -c shows what a merge commit changed beyond its parents (a conflict resolution); quotepath off keeps non-ASCII names whole
        return git(tree, '-c', 'core.quotepath=false', 'log', '-c', '--format=', '--name-only', head,
                   f'^{commit}', f'^{base_ref}').split('\n')
    try:
        return real_use_proof.pr_blockers(github, number, pull, comments, own_commits, paths_after, messages)
    except ReadFailed:
        raise
    except Exception as error:  # noqa: BLE001
        return [f'the real-use proof check failed ({str(error)[:200]}), so it holds this PR']


def blockers(github: GitHub, tree: Path, base: str, number: int, head: str, classify=None, inherited=None,
             reads: SharedReads | None = None) -> list[str]:
    """Why PR <number> at <head> may not merge into <base>, or [] when it may. classify and inherited are injected in
    tests; by default they are test-scope.py's classify and lane_merge_rules.py's inherited_check, reading GitHub through
    <reads> (evaluate makes one SharedReads per run, so the PRs of a group share one search)."""
    base_ref = f'origin/{base}'
    pull = github.pull(number)
    fetch_head(tree, number, head)
    paths, diffs = changes(tree, base_ref, head)
    scope = (classify or (lambda p, d: scope_policy().classify(p, d, root=tree)))(paths, diffs)
    comments = github.comments(number)
    if inherited is None:
        inherited = rules().inherited_check(types.SimpleNamespace(repo=github.repo, pr=number), tree, base, head,
                                            api=reads or SharedReads(github))
    reasons = list(rules().merge_blockers(scope, comments, head, inherited))
    tap = rules().owner_tap_paths(scope)
    labels = {label.get('name') for label in pull.get('labels') or []}
    if tap and OWNER_TAP_LABEL not in labels and not owner_review_tap.owner_approved(github.reviews(number), head):
        shown = ', '.join(f'`{p}`' for p in tap)
        reasons.append(f'it touches {shown}, {OWNER_TAP_MARK} (owner rule 2026-10-09, #1203); '
                       f'it needs the `{OWNER_TAP_LABEL}` label or his approving review of `{head[:7]}`')
    rewrite = resolved_rewrite(paths)
    if rewrite:
        reasons.append(rewrite)
    reasons.extend(proof_blockers(github, tree, base_ref, number, head, pull, comments))
    bad = unsigned_commits(tree, base_ref, head, pull.get('author_association') or '',
                           (pull.get('user') or {}).get('login') or '')
    if bad:
        reasons.append(f'{len(bad)} commit(s) have no `Signed-off-by:` line ({", ".join(c["sha"][:7] for c in bad)}); '
                       'see CONTRIBUTING.md')
    return reasons


def is_waiting(reason: str) -> bool:
    """Whether a hold is only a wait for something that arrives by itself: an audit of the head that isn't posted yet
    (lane_merge_rules.AUDIT_MISSING; an audit with blocking findings is not one), or the owner's tap (the `owner-tap`
    label or his approving review).
    Anything else (an inherited finding, an unsigned commit, a Package.resolved rewrite, a missing real-use proof,
    a read that failed) is a defect for the author to fix or a fault, and stays a failure."""
    return rules().AUDIT_MISSING in reason or OWNER_TAP_MARK in reason


def evaluate(github: GitHub, tree: Path, base: str, prs: list[tuple[int, str]], **injected) -> list[tuple[int, str, list[str], bool]]:
    """(number, head, reasons, unread) for each PR; unread is True when a GitHub or git read failed (fail closed)."""
    found = []
    injected.setdefault('reads', SharedReads(github))
    for number, head in prs:
        try:
            found.append((number, head, blockers(github, tree, base, number, head, **injected), False))
        except ReadFailed as error:
            found.append((number, head, [f'the check could not read what it needs ({error}), so it holds the merge'], True))
    return found


def say(found: list[tuple[int, str, list[str], bool]], out=sys.stdout) -> None:
    for number, head, reasons, _ in found:
        if reasons:
            print(f'#{number} at {head[:7]} may not merge: ' + '; '.join(reasons) + '.', file=out)
        else:
            print(f'#{number} at {head[:7]} may merge.', file=out)


def verdict(found: list[tuple[int, str, list[str], bool]], queue: bool) -> str:
    """'success', 'waiting' or 'failure' for the status. Only a pull_request run waits (see the module doc)."""
    held = [(reasons, unread) for _, _, reasons, unread in found if reasons]
    if not held:
        return 'success'
    if not queue and all(not unread and all(is_waiting(r) for r in reasons) for reasons, unread in held):
        return 'waiting'
    return 'failure'


def waiting_title(found: list[tuple[int, str, list[str], bool]]) -> str:
    reasons = [r for _, _, rs, _ in found for r in rs]
    wants = []
    if any(rules().AUDIT_MISSING in r for r in reasons):
        wants.append('a clean audit')
    if any(OWNER_TAP_MARK in r for r in reasons):
        wants.append("the owner's tap")
    return 'Waiting for ' + ' and '.join(wants or ['an audit or the owner'])


def judge(github: GitHub, tree: Path, base: str, prs: list[tuple[int, str]], out=sys.stdout, **injected) -> int:
    """Print one line per PR and return the exit code: 0 when every PR may merge."""
    found = evaluate(github, tree, base, prs, **injected)
    say(found, out)
    return 1 if any(reasons for _, _, reasons, _ in found) else 0


class CommitStatus:
    """The `merge policy` commit status this script writes (#4986, #5162): posted `pending` before the rules are read,
    then posted once more with the verdict (GitHub reads the newest status of a context). Whatever stops the script in
    between leaves it pending, which blocks the merge.

    A status, not a check run (#5162): a check run made through the Checks API is filed into whichever GitHub Actions
    check suite exists first on the commit, and when that was the label bridge's suite the merge queue never counted it
    ("Required status check 'merge policy' is expected" with the check green: #5147, #5155, #5176, #5178). A commit
    status belongs to no check suite, so there is nothing to race."""

    # The script's verdicts -> a status's states. `waiting` is the pending a PR shows while it waits for its audit or
    # the owner's tap; a cancel is `error`, which blocks like `failure` but says no verdict was reached.
    STATES = {'waiting': 'pending', 'success': 'success', 'failure': 'failure', 'cancelled': 'error'}
    DESCRIPTION_LIMIT = 140  # GitHub refuses a longer status description

    def __init__(self, github: GitHub, sha: str, details_url: str = '', name: str = CHECK_NAME):
        self.github, self.sha, self.details_url, self.name = github, sha, details_url, name
        self.started = False

    def _post(self, state: str, description: str) -> None:
        if len(description) > self.DESCRIPTION_LIMIT:
            description = description[:self.DESCRIPTION_LIMIT - 1] + '…'
        args = ['api', '-X', 'POST', f'repos/{self.github.repo}/statuses/{self.sha}', '-f', f'state={state}',
                '-f', f'context={self.name}', '-f', f'description={description}']
        if self.details_url:
            args += ['-f', f'target_url={self.details_url}']
        self.github._gh(args)

    def start(self) -> None:
        self._post('pending', 'Checking the merge rules')
        self.started = True

    def finish(self, state: str, title: str, summary: str) -> None:
        """state: success, failure or cancelled end it; waiting posts `pending` with the reason in the description. The
        full summary is in the run's log and step summary; a failure's description adds its first line."""
        if not self.started:
            raise ReadFailed('the pending status was never posted')
        first = next((line.strip() for line in summary.splitlines() if line.strip()), '')
        self._post(self.STATES[state], f'{title}: {first}' if state == 'failure' and first else title)


def report(github: GitHub, tree: Path, base: str, prs_of, sha: str, queue: bool, details_url: str = '', out=sys.stdout,
           check_run: CommitStatus | None = None, **injected) -> int:
    """Run the rules and write the verdict as the `merge policy` commit status on <sha>. prs_of() returns the (number,
    head) pairs, and may raise ReadFailed. Returns 0 for a pass or a wait, 1 for a failure or when the status couldn't be
    written; see the module doc for why an interrupted run leaves the status pending."""
    check_run = check_run or CommitStatus(github, sha, details_url)
    check_run.start()
    try:
        try:
            found = evaluate(github, tree, base, prs_of(), **injected)
        except ReadFailed as error:
            line = f'merge policy could not find the PRs to check ({error}), so it holds the merge.'
            print(line, file=out)
            check_run.finish('failure', 'May not merge', line)
            return 1
        buffer = io.StringIO()
        say(found, buffer)
        print(buffer.getvalue(), end='', file=out)
        state = verdict(found, queue)
        title = {'success': 'May merge', 'failure': 'May not merge', 'waiting': waiting_title(found)}[state]
        check_run.finish(state, title, buffer.getvalue())
        return 1 if state == 'failure' else 0
    except KeyboardInterrupt:  # the runner's cancel (SIGINT, then SIGTERM, which main turns into this)
        try:
            check_run.finish('cancelled', 'Cancelled', 'The merge policy run was cancelled before it had a verdict.')
        finally:
            raise
    except Exception as error:  # noqa: BLE001 - an unexpected crash must not leave a stale or silent status
        try:
            check_run.finish('failure', 'The merge policy crashed', f'{type(error).__name__}: {str(error)[:300]}')
        except Exception:  # noqa: BLE001
            pass
        raise


def start_missing(github: GitHub, number: int, head: str, base: str = 'main', out=sys.stdout, sleep=time.sleep,
                  recheck_wait: float = START_RECHECK_WAIT) -> list[str]:
    """Start the dispatchable required checks that have no run on PR <number>'s head (#4867), and return their workflows.

    Skips a closed or draft PR, a fork's, and a head the PR has moved past (the newer push has its own events). A check
    not listed yet is looked for again after <recheck_wait> seconds, because the PR's own workflows start at the same
    time as this one, and the PR's head is read again then. A run that was cancelled is not restarted here (the
    dispatch script does that on purpose). A dispatch that fails is printed and never blocks the merge policy."""
    import required_checks  # here, not at the top: a broken module must reach main()'s `except`, not stop every verdict
    def eligible(pull: dict) -> bool:
        return (pull.get('state') == 'open' and not pull.get('draft') and (pull.get('head') or {}).get('sha') == head
                and ((pull.get('head') or {}).get('repo') or {}).get('full_name') == github.repo)
    try:
        pull = github.pull(number)
        if not eligible(pull):
            return []
        todo = required_checks.missing(github, head)
        if todo:
            sleep(recheck_wait)
            pull = github.pull(number)
            todo = required_checks.missing(github, head) if eligible(pull) else []
    except ReadFailed as error:
        print(f'#{number} at {head[:7]}: could not look for required checks that never ran ({error}).', file=out)
        return []
    started, ref = [], pull['head']['ref']
    for workflow in todo:
        names = ', '.join(f'`{n}`' for n in required_checks.checks_of(workflow))
        try:
            required_checks.start(github, workflow, ref, base)
        except ReadFailed as error:
            print(f'#{number} at {head[:7]}: {names} not started, and starting `{workflow}` failed ({error})'
                  f'{required_checks.failure_hint(error)}.', file=out)
            continue
        started.append(workflow)
        print(f'#{number} at {head[:7]}: {names} not started on this head; started `{workflow}` on `{ref}`.', file=out)
    return started


def main(argv: list[str] | None = None, github: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', ''))
    parser.add_argument('--base', default='main')
    parser.add_argument('--tree', type=Path, default=SCRIPTS.parent)
    parser.add_argument('--pr', type=int, help='one PR (pull_request, workflow_dispatch)')
    parser.add_argument('--head', default='', help="the PR's head commit; empty: the PR's current head")
    parser.add_argument('--group-head', default='', help="a merge group's head commit (merge_group)")
    parser.add_argument('--report-sha', default='',
                        help='write the verdict as a `merge policy` commit status on this commit (the PR head, or the '
                             "merge group's head); see the module doc (#4986, #5162)")
    parser.add_argument('--details-url', default='', help="the workflow run's URL, for the status's link")
    parser.add_argument('--start', action='store_true',
                        help="with --pr: start a dispatchable required check that has no run on the PR's head (#4867)")
    args = parser.parse_args(argv)
    if not args.repo or not (args.pr or args.group_head):
        parser.error('--repo and one of --pr or --group-head are required')
    github = github or GitHub(args.repo)
    if args.report_sha:
        return main_report(args, github)
    try:
        if args.group_head:
            prs = group_prs(github.queue_entries(args.base), args.group_head)
        else:
            prs = [(args.pr, args.head or github.pull(args.pr)['head']['sha'])]
    except ReadFailed as error:
        print(f'merge policy could not find the PRs to check ({error}), so it holds the merge.')
        return 1
    code = judge(github, args.tree, args.base, prs)
    if args.start and args.pr and not args.group_head:
        try:
            start_missing(github, prs[0][0], prs[0][1], args.base)
        except Exception as error:  # noqa: BLE001 - starting a check is a courtesy; it never changes the verdict
            print(f'#{prs[0][0]}: looking for required checks that never ran failed ({str(error)[:200]}); the verdict above stands.')
    return code


def main_report(args, github: GitHub) -> int:
    """--report-sha: write the commit status (see report). --start is not offered here: the workflow runs it without."""
    def prs_of():
        if args.group_head:
            return group_prs(github.queue_entries(args.base), args.group_head)
        return [(args.pr, args.head or github.pull(args.pr)['head']['sha'])]
    previous = signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        return report(github, args.tree, args.base, prs_of, args.report_sha, queue=bool(args.group_head),
                      details_url=args.details_url)
    except ReadFailed as error:
        print(f'merge policy could not write its status ({error}).')
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    sys.exit(main())
