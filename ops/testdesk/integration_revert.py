"""After a confirmed integration FAIL: find the culprit merge and say whether to revert it (#1180).

Pure decisions and text for sm_integration_run.py. The script does the git, gh and simulator work and hands
the results to these functions, so every rule here is host-testable without a Mac.

Owner rule (2026-09-30): "revert first". The culprit is the first-parent commit where the failing tests
stop passing, found by bisecting the commits since the last PASS (the same answer as re-running at each
one, in about log2(n) builds). The revert is never opened when it would be unsafe or unclear; the owner
is told instead.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path
import re
from typing import Callable, Optional

MAX_CHECKS = 8   # builds spent on the search; 2**8 commits are more than a day of merges
HOT_FILES = ('App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift',
             'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift')
# A revert of these is a data or compatibility change in its own right: the owner decides.
NEVER_REVERT = {'persistence': 'persistence', 'packet': 'a packet format'}
MIGRATION = re.compile(r'migrat', re.I)
LANE_EXTRA_PREFIXES = ('.github/', 'scripts/lane')


def load_test_scope(root: Path):
    """scripts/test-scope.py, the lane's own classifier (its file name has a hyphen)."""
    path = root / 'scripts' / 'test-scope.py'
    loader = importlib.machinery.SourceFileLoader('test_scope', str(path))
    spec = importlib.util.spec_from_loader('test_scope', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


# The search

def check_verdict(failed: list[str], summary: dict) -> str:
    """'fail' when a failing test fails again, 'pass' when every one passes, else 'unknown'.

    A test that is missing at that commit (it did not exist yet) or a run that stopped (the target did not
    build) says nothing about the culprit, so it is 'unknown', never 'pass'."""
    statuses = [summary['tests'].get(test) for test in failed]
    if any(status == 'failed' for status in statuses):
        return 'fail'
    if summary['verdict'] != 'INCONCLUSIVE' and statuses and all(status == 'passed' for status in statuses):
        return 'pass'
    return 'unknown'


def find_culprit(commits: list[dict], check: Callable[[dict], str], max_checks: int = MAX_CHECKS) -> dict:
    """Bisect `commits` (first-parent, oldest first, the failing tip last; the last PASS is just before them).

    Returns {'status': 'found', 'commit': <dict>, 'checks': [(sha7, verdict)]} where the commit before it
    passed (or is the last PASS) and it fails; or {'status': 'unknown', 'why': ..., 'checks': [...]}.
    The tip itself is known to fail (it was confirmed by two re-runs)."""
    checks: list[tuple[str, str]] = []
    if not commits:
        return {'status': 'unknown', 'why': 'no commits between the last PASS and the tip', 'checks': checks}
    low, high = -1, len(commits) - 1     # commits[low] passes (-1: the last PASS), commits[high] fails
    while high - low > 1:
        if len(checks) >= max_checks:
            return {'status': 'unknown', 'why': f'{max_checks} builds were not enough to narrow it down',
                    'checks': checks}
        middle = (low + high) // 2
        verdict = check(commits[middle])
        checks.append((commits[middle]['sha'][:7], verdict))
        if verdict == 'fail':
            high = middle
        elif verdict == 'pass':
            low = middle
        else:
            return {'status': 'unknown', 'checks': checks,
                    'why': f'the failing tests gave no clear answer at {commits[middle]["sha"][:7]}'}
    return {'status': 'found', 'commit': commits[high], 'checks': checks}


# Whether to revert

def pr_number(subject: str) -> Optional[int]:
    match = re.match(r'Merge pull request #(\d+)', subject or '')
    return int(match.group(1)) if match else None


def pr_title(subject: str, body: str = '') -> str:
    """The merged PR's title: GitHub's merge commit puts it on the line after the first (body)."""
    lines = [line.strip() for line in (body or '').splitlines() if line.strip()]
    if lines:
        return lines[0]
    match = re.match(r'Merge pull request #\d+[: ]\s*(?:from \S+\s*)?(.*)', subject or '')
    return (match.group(1) if match else subject or '').strip()


def revert_blockers(commit: dict, paths: list[str], scope, root: Path, open_reverts: list[str],
                    already_reverted: Optional[str]) -> list[str]:
    """Reasons not to open a revert PR for the culprit, empty when it is safe to try."""
    reasons = []
    if len(commit.get('parents', [])) != 2 or pr_number(commit.get('subject', '')) is None:
        reasons.append('the culprit is not a merged pull request, so there is no merge to revert')
    if re.match(r'\s*Revert\b', pr_title(commit.get('subject', ''), commit.get('body', '')), re.I):
        reasons.append('the culprit is itself a revert; reverting it would bring the earlier failure back')
    if already_reverted:
        reasons.append(f'next already reverts it ({already_reverted[:7]})')
    if open_reverts:
        reasons.append('another revert PR is open (' + ', '.join(open_reverts) + ')')
    kinds, unreadable = set(), []
    for path in paths:
        if path.startswith(LANE_EXTRA_PREFIXES) or scope.is_lane_path(path):
            kinds.add('the lane')
        if MIGRATION.search(path):
            kinds.add('a migration')
        try:
            category = scope.classify_path(root, path).category
        except Exception:  # noqa: BLE001 - an unreadable file must not let a risky revert through
            unreadable.append(path)
            continue
        if category in NEVER_REVERT:
            kinds.add(NEVER_REVERT[category])
    if kinds:
        reasons.append('the culprit changes ' + ', '.join(sorted(kinds)) + ', which are not reverted automatically')
    if unreadable:
        reasons.append('could not classify ' + ', '.join(unreadable[:3]) + ' to rule out persistence or a packet format')
    return reasons


def grows_hot_file(numstat: str) -> list[str]:
    """Hot files that a staged diff makes longer (`git diff --cached --numstat` lines: added, deleted, path)."""
    grown = []
    for line in (numstat or '').splitlines():
        parts = line.split('\t', 2)
        if len(parts) == 3 and parts[2] in HOT_FILES and parts[0].isdigit() and parts[1].isdigit() \
                and int(parts[0]) > int(parts[1]):
            grown.append(parts[2])
    return grown


# Text

def revert_branch(number: int) -> str:
    return f'revert/pr{number}'


def revert_title(number: int, title: str, sha: str) -> str:
    return f'Revert #{number}: {title} (integration-{sha[:7]} FAIL)'[:200]


def revert_message(number: int, title: str, sha: str, merge_sha: str, report: str, failed: list[str]) -> str:
    return '\n'.join([
        f'Revert #{number}: {title} (integration-{sha[:7]} FAIL)', '',
        f'The integration run on next at {sha[:7]} failed {", ".join(failed)}; the tests passed before this merge',
        f'and fail from it on (found by building the commits in between). Report: {report}', '',
        f'This reverts commit {merge_sha}.'])


def pr_body(number: int, title: str, sha: str, report: str, failed: list[str], checks: list[tuple[str, str]],
            reland: str, hot_note: str = '') -> str:
    found = '; '.join(f'{sha7} {verdict}' for sha7, verdict in checks) or 'none (it was the first commit after the last PASS)'
    lines = [
        f'Reverts #{number} ({title}) because the integration run on next at `{sha[:7]}` failed: '
        + ', '.join(f'`{t}`' for t in failed) + f'. Report: {report}', '',
        f'The tests were re-run on the commits in between: {found}. The merge of #{number} is the first where they fail.',
        '', f'Re-land: {reland}', '']
    if hot_note:
        lines += [hot_note, '']
    lines += ['Opened by the integration script (ops/testdesk/sm_integration_run.py, #1180) under the owner\'s '
              '"revert first" rule. It carries `automerge`: the runner merges it on a host-test PASS.', '']
    return '\n'.join(lines)


def hot_note(grown: list[str]) -> str:
    names = ', '.join(Path(p).name for p in grown)
    return (f'`hot-file-ok`: reverting this merge puts back lines in {names}, which the hot-file ratchet counts as '
            'growth. Taking out a broken change is not new code in the hot file.')


def reland_title(number: int, title: str) -> str:
    return f'Re-land #{number} after an integration revert: {title}'[:200]


def reland_body(number: int, title: str, sha: str, report: str, revert: str, failed: list[str],
                prose: list[str]) -> str:
    """`prose` is the read-only diagnosis, one block of text per failure group (issue_text's output)."""
    return '\n'.join([
        f'#{number} ({title}) was reverted on next because the integration run at `{sha[:7]}` failed '
        + ', '.join(f'`{t}`' for t in failed) + f'. Revert: {revert}. Report: {report}', '',
        '## What the diagnosis found', *[block.strip() + '\n' for block in prose], '',
        '**Done when**',
        f'1. The change from #{number} lands again in a new PR into next, with the failing tests above passing.',
        '2. A test that fails without the fix covers the cause (the integration run found it; the PR gates did not).', '',
        '**Must not break:** the journeys the original PR touched, packets, the database, and the owner\'s Library.', ''])


def not_reverted_comment(sha: str, report: str, failed: list[str], reasons: list[str], suspect: str,
                         checks: list[tuple[str, str]]) -> str:
    searched = ('; searched: ' + ', '.join(f'{s} {v}' for s, v in checks)) if checks else ''
    return '\n'.join([
        f'Integration revert not opened for next at `{sha[:7]}` ({report}).', '',
        'Failing: ' + ', '.join(f'`{t}`' for t in failed) + f'. Suspect: {suspect}{searched}.',
        'Not reverted because:', *[f'- {reason}' for reason in reasons], '',
        '@uncomposed: this needs a person. The failure issue is filed as usual.', ''])
