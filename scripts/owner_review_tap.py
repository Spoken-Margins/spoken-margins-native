"""The owner's approving review counts as his merge tap (owner's decision, 2026-11-24).

A PR touching `.github/` or `scripts/lane_merge_rules.py` merges only with the owner's tap (lane_merge_rules.py
owner_tap_paths). The tap was only the `owner-tap` label. On 2026-11-24 the owner approved #5212, #5252 and #5256 and
all three stayed at "Waiting for the owner's tap", because nothing read reviews. Now either counts: the label, or an
approval this module accepts.

What counts: the owner's latest decisive review (APPROVED, CHANGES_REQUESTED or DISMISSED, newest by submitted time;
COMMENTED and unsubmitted PENDING reviews are skipped) is APPROVED, on the PR's current head commit. A request for
changes, a dismissal (GitHub turns the dismissed review's own state to DISMISSED), or an approval of an older commit
does not count. Nobody else's review counts, a bot's or app's included.

One copy of the rule, read by scripts/merge_policy.py (the required check), scripts/owner_tap_alert.py (the
`needs-owner-tap` list and the alert) and scripts/merge_queue_label_bridge.py (arming the merge queue). It takes both
the REST shape (`user.login`, `commit_id`, `submitted_at`) and the GraphQL shape (`author.login`, `commit.oid`,
`submittedAt`). Stdlib only, no imports from this folder: the alert and the bridge workflows check out a few files.
"""
from __future__ import annotations

OWNER_LOGIN = 'uncomposed'  # the owner's GitHub login (owner_tap_alert.OWNER_LOGIN; a test keeps them equal)
DECISIVE = ('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED')


def _login(review: dict) -> str:
    return ((review.get('user') or review.get('author') or {}).get('login') or '')


def _commit(review: dict) -> str:
    return review.get('commit_id') or (review.get('commit') or {}).get('oid') or ''


def _when(review: dict) -> str:
    return review.get('submitted_at') or review.get('submittedAt') or ''


def owner_approved(reviews: list[dict], head: str, owner: str = OWNER_LOGIN) -> bool:
    """Whether the owner's latest decisive review approves commit <head> (see the module doc)."""
    if not head:
        return False
    mine = [r for r in reviews or [] if _login(r).casefold() == owner.casefold()
            and (r.get('state') or '').upper() in DECISIVE and _when(r)]
    if not mine:
        return False
    latest = max(enumerate(mine), key=lambda pair: (_when(pair[1]), pair[0]))[1]  # ties: the later one listed
    return (latest.get('state') or '').upper() == 'APPROVED' and _commit(latest) == head
