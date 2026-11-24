"""The merge rules: which audits clear a head, which paths only the owner merges, and the inherited audit holds.

scripts/merge_policy.py (the merge queue's required check) and scripts/ci_model.py import them from here, so there is
one copy. Moved out of scripts/lane-runner.py (#4769) when the per-PR lane was retired. Like lane-runner.py before it,
this file is on the owner-tap list (OWNER_TAP_FILES): a PR changing it merges only with the owner's tap, because a bad
rule here could wave later PRs through. owner_tap_alert.py, sm_status.py, ops/codex/sm_codex_audit.py and
ops/away/away_check.py keep copies of that list, and tests keep them equal.

Stdlib only, Python 3.9-compatible: it runs under /usr/bin/python3.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


AUDITS = ('**Codex audit (Astra)', '## Codex audit', '**Claude audit on `')


AUDITED = {'audio': 'the audio session', 'persistence': 'persistence', 'packet': 'packets'}


BOT = ('github-actions[bot]', '41898282+github-actions[bot]@users.noreply.github.com')


# Whose PR comments the runner reads (#1719). Once the repository is public, anyone can comment, and a /lane
# request runs the PR's code on the Mac; a fake report or note could also answer a request or lift an audit hold.
# So the runner sees only comments from the owner, the organisation's members and the repository's
# collaborators (GitHub's author_association), and from the project's own bot, the workflows' github-actions.
TRUSTED_ASSOCIATIONS = ('OWNER', 'MEMBER', 'COLLABORATOR')


TRUSTED_BOTS = (BOT[0],)
# The GitHub App the agents act as (#4915). GitHub reports its comments as `<slug>[bot]` with association NONE, so
# without this entry an audit, hold note or /lane request an agent posts as the App would be ignored and the PR held.
# Kept equal to scripts/comment_trust.py's list by scripts/tests/test_app_identity_trust.py.
TRUSTED_APP_SLUGS = ('spoken-margins-agent',)


def trusted_comment(comment: dict) -> bool:
    """Whether the runner may act on this comment: the owner's, a member's or collaborator's, the project's bot, or
    the agents' App.

    A comment without author_association (GitHub always sends it) is not trusted.
    """
    login = (comment.get('user') or {}).get('login')
    bots = TRUSTED_BOTS + tuple(f'{slug}[bot]' for slug in TRUSTED_APP_SLUGS)
    return comment.get('author_association') in TRUSTED_ASSOCIATIONS or login in bots


def base_policy(tree: Path, base: str, path: str):
    """A script from the base branch, loaded as a module, so a PR can't change the rules that judge it.
    None if the base doesn't have it yet."""
    import types
    shown = subprocess.run(['git', '-C', str(tree), 'show', f'origin/{base}:{path}'], capture_output=True, text=True)
    if shown.returncode != 0:
        return None
    module = types.ModuleType('lane_policy_' + Path(path).stem.replace('-', '_'))
    module.__file__ = str(tree / path)
    exec(compile(shown.stdout, f'origin/{base}:{path}', 'exec'), module.__dict__)
    return module


AUDIT_SHA = re.compile(r'`([0-9a-f]{7,40})`')


CLEAN_AUDIT = re.compile(r'no (blocking )?findings\b', re.I)  # how the audit task's verdict line opens


# The start of every reason audit_blocker gives when no audit covers the head yet. merge_policy.py treats a PR held only
# for this (or for the owner's tap) as waiting, not failed; an audit with blocking findings never starts with it.
AUDIT_MISSING = 'has no Codex or Claude audit'


def audit_blocker(comments: list[dict], head: str) -> str | None:
    """Why the Codex or Claude audits on the PR don't clear its head, or None when the newest audit of the head is clean.

    #441: any audit comment used to clear the PR, whatever commit it covered or what it found. An audit
    counts only if its heading names the head commit (the hourly task's says "on `<sha7>`"), and it clears
    only if its verdict, the first line after the heading, opens "No blocking findings". Anything else
    holds, so a new audit format fails closed.
    """
    audits = []
    for comment in comments:
        body = (comment.get('body') or '').lstrip()
        if (body.startswith(AUDITS[:2]) or
                re.fullmatch(r'\*\*Claude audit on `[0-9a-f]{7,40}`\*\*', body.partition('\n')[0].rstrip())):
            heading, _, rest = body.partition('\n')
            verdict = next((line.strip() for line in rest.splitlines() if line.strip()), '')
            audits.append((AUDIT_SHA.findall(heading), verdict))
    if not audits:
        return f'{AUDIT_MISSING} comment yet'
    on_head = [verdict for shas, verdict in audits if any(head.startswith(sha) for sha in shas)]
    if not on_head:
        audited = next((shas[0] for shas, _ in reversed(audits) if shas), None)
        return (f'{AUDIT_MISSING} of its head: the audit is on `{audited}`, the head is `{head[:7]}`' if audited
                else f'{AUDIT_MISSING} naming its head `{head[:7]}`')
    if not CLEAN_AUDIT.match(on_head[-1]):
        return f'the Codex or Claude audit on the head `{head[:7]}` has blocking findings (it doesn\'t say "No blocking findings")'
    return None


# Owner rule 2026-10-09 (#1203, #1210): arming and merging a PR that touches the runner itself or anything under
# .github/ is the owner's tap. The runner can't test itself, and a bad runner or workflow change could wave later
# PRs through, so a clean audit doesn't let the runner merge these. Other lane paths still merge on an audit.
OWNER_TAP_FILES = {'scripts/lane_merge_rules.py'}


OWNER_TAP_PREFIXES = ('.github/',)


def scope_paths(scope: dict) -> list[str]:
    """Every path test-scope.py saw in the PR's diff."""
    return sorted({f.get('path') or '' for f in scope.get('files', [])} | set(scope.get('lane_paths') or []))


def owner_tap_paths(scope: dict) -> list[str]:
    """The PR's changed paths only the owner merges, whatever an audit says (OWNER_TAP_FILES, OWNER_TAP_PREFIXES)."""
    return [p for p in scope_paths(scope) if p in OWNER_TAP_FILES or p.startswith(OWNER_TAP_PREFIXES)]


INHERITED_HOLD = 'it inherits a blocking audit finding'  # lane_inherited_holds.INHERITED: a test keeps them equal
INHERITED_FAILED = 'the check for inherited audit findings could not finish'


INHERITED_POLICY = 'scripts/lane_inherited_holds.py'


# Other PRs' comments, kept by PR number and updated_at so an unchanged PR costs no call on the next run.
INHERITED_CACHE = Path(os.environ.get('SM_LANE_INHERITED_CACHE') or
                       Path.home() / 'Library/Caches/SpokenMarginsLane/inherited-holds.json')


def short_error(text: str, limit: int = 320) -> str:
    """<text> cut to about <limit> characters, keeping its end. A read's error names the path first and the reason last,
    and a search path alone is 200 characters: cutting the end off left "gh api search/issues?...page=1:" with no reason
    in merge group run 45291666840 (2026-11-23)."""
    if len(text) <= limit:
        return text
    head = limit // 3
    return text[:head] + ' … ' + text[-(limit - head - 3):]


def inherited_check(github, tree: Path, base: str, head: str, api=None):
    """#712: a function from the PR's comments to the reasons its inherited audit findings hold it (see
    scripts/lane_inherited_holds.py). The lookup reads other PRs' audits for the commits this PR brings in beyond
    next; the rules come from next's copy, like the other policies. A lookup that can't finish holds the merge.

    api, when given, is the GitHub read the lookup uses instead of its own one-try `gh api`: merge_policy.py passes one
    that waits out rate limits and shares one search between every PR of a run."""
    try:
        policy = base_policy(tree, base, INHERITED_POLICY)
        if policy is None:
            raise RuntimeError(f'{base} has no {INHERITED_POLICY} yet')
        reads = {'api': api} if api is not None else {}
        holds = policy.find_holds(tree, github.repo, f'origin/{base}', head, github.pr, cache=INHERITED_CACHE, **reads)
    except Exception as error:  # noqa: BLE001 - any failure to look holds the merge instead of waving it through
        why = f'{INHERITED_FAILED}: {short_error(str(error))}. Remove and re-add automerge to check again'
        return lambda comments: [why]
    return lambda comments: policy.reasons(policy.unresolved(holds, comments, head), head)


def merge_blockers(scope: dict, comments: list[dict], head: str, inherited=None) -> list[str]:
    """Why the runner won't merge this PR yet even on PASS: an audited kind of change without a clean Codex or Claude
    audit of its head. Lane changes are one of those kinds; they no longer wait for a person (owner rule
    2026-10-01). The audit script re-arms automerge after a clean audit, and that run merges.

    inherited (inherited_check's answer) adds a hold per blocking audit on another PR's commits this PR brings in
    (#712): a clean audit of this head doesn't clear it, a resolution of that finding plus a clean audit after does."""
    reasons = []
    # Imported here, like lane_slots: the workflow runs this file from $RUNNER_TEMP, where ROOT/scripts is
    # not the workspace, so a top-level import fails before main() puts the tree on sys.path.
    from lane_audit_policy import requires_persistence_audit
    risky = {AUDITED[f['category']] for f in scope['files'] if f['category'] in AUDITED}
    # #1658: test-scope's sessionkit category does not describe persistence risk.
    # Use the auditor's existing eligibility rules as well, without changing tiers.
    if requires_persistence_audit([f.get('path', '') for f in scope['files']]):
        risky.add('persistence')
    risky = sorted(risky)
    if scope.get('lane_paths'):  # owner rule 2026-10-01: lane changes need the audit too (test-scope.py)
        risky.append('the lane')
    audit = audit_blocker(comments, head) if risky else None
    if audit:
        reasons.append(f'it touches {" and ".join(risky)}, and {audit}' if audit.startswith('the ')
                       else f'it touches {" and ".join(risky)} and {audit}')
    return reasons + (inherited(comments) if inherited else [])
