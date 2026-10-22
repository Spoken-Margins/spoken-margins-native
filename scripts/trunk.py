"""The trunk: the one branch day-to-day PRs merge into, and whose tip the Mac's jobs build and test (#1492).

Code that answers a PR uses that PR's base branch. Code with no PR in hand (the phone build, the Test Desk's
integration run, the status page, the audit's base checkout) asks trunk_branch() instead of naming a branch.

One name, two places to set it:
- SM_TRUNK in the environment wins. Every workflow sets it from the repository variable `SM_TRUNK`, with
  DEFAULT_TRUNK as the fallback (`${{ vars.SM_TRUNK || 'main' }}`); scripts/tests/test_trunk.py keeps the
  fallbacks equal to DEFAULT_TRUNK.
- DEFAULT_TRUNK below, for the Mac's launchd jobs and local runs.
The trunk moved to main on 2026-10-20 (#1492): the repository variable and DEFAULT_TRUNK both say main.

Stdlib only, Python 3.9-compatible: the lane runner and launchd jobs import it under /usr/bin/python3.
"""
from __future__ import annotations

import os
import re
from typing import Mapping, Optional

DEFAULT_TRUNK = 'main'

# A plain branch name: no leading dash (an option to git), no "..", no ref prefix, nothing a shell would expand.
_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._/-]*')


def trunk_branch(environ: Optional[Mapping[str, str]] = None) -> str:
    """The trunk's branch name: SM_TRUNK when set, else DEFAULT_TRUNK. Raises ValueError on a name git would
    not take as a plain branch, so a typo stops the job instead of testing or pushing somewhere else."""
    env = os.environ if environ is None else environ
    name = (env.get('SM_TRUNK') or '').strip() or DEFAULT_TRUNK
    if not _NAME.fullmatch(name) or '..' in name or name.endswith(('/', '.', '.lock')) or name.startswith('refs/'):
        raise ValueError(f'SM_TRUNK is not a plain branch name: {name!r}')
    return name


def trunk_ref(environ: Optional[Mapping[str, str]] = None) -> str:
    """The trunk's remote-tracking ref, as git commands take it: origin/<trunk>."""
    return f'origin/{trunk_branch(environ)}'


def is_trunk(base: str, environ: Optional[Mapping[str, str]] = None) -> bool:
    """Whether <base> (a PR's base branch, or a ref such as origin/<name> or refs/heads/<name>) is the trunk."""
    for prefix in ('refs/heads/', 'refs/remotes/origin/', 'origin/'):
        if base.startswith(prefix):
            base = base[len(prefix):]
            break
    return base == trunk_branch(environ)


if __name__ == '__main__':  # `python3 scripts/trunk.py` prints the name, for shell scripts
    print(trunk_branch())
