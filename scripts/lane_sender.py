#!/usr/bin/env python3
"""Whether the sender of a lane event may start a lane run (#1822).

`.github/workflows/lane.yml` runs this in its `route` job, from the base branch's copy, for pull_request events. The
sender is the account that added the label or pushed the commit. It may start a run when it has write access to the
repository (admin, maintain or write permission) or is the project's own bot. Anything else, or any failure to find
out, means no run: the check fails closed, and a trusted person re-adding the label starts it.

Usage: lane_sender.py LOGIN   -> prints `trusted=true` or `trusted=false` for $GITHUB_OUTPUT; GH_REPO names the repo.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

TRUSTED_BOTS = ('github-actions[bot]',)    # the same bot scripts/comment_trust.py names
WRITE_PERMISSIONS = ('admin', 'maintain', 'write')


def permission_of(login: str, repo: str) -> str:
    """The sender's permission on the repo ('' when GitHub can't say)."""
    for _ in range(2):
        found = subprocess.run(['gh', 'api', f'repos/{repo}/collaborators/{login}/permission'],
                               capture_output=True, text=True, timeout=30)
        if found.returncode == 0:
            try:
                return json.loads(found.stdout).get('permission') or ''
            except ValueError:
                return ''
    return ''


def trusted(login: str, permission: str) -> bool:
    return bool(login) and (login in TRUSTED_BOTS or permission in WRITE_PERMISSIONS)


def main(argv: list[str]) -> int:
    login = argv[1] if len(argv) > 1 else ''
    repo = os.environ.get('GH_REPO', '')
    permission = '' if login in TRUSTED_BOTS or not login or not repo else permission_of(login, repo)
    ok = trusted(login, permission)
    print(f'trusted={str(ok).lower()}')
    if not ok:
        print(f'::warning::Ignoring the event from {login or "an unknown sender"} (permission: {permission or "none"}); '
              'only the owner, collaborators with write access and the project bot start lane runs.', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
