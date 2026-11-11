#!/usr/bin/env python3
"""Where the owner-only scripts find the public checkout and their own state (#1844, #1390 step 2).

The scripts in ops/, scripts/phone-build, scripts/daily-phone-plan, scripts/sm_status.py and
scripts/sm_sweep.py will move to a private repo (docs/open-source/private-ops-plan.md). Until they do,
they live inside the checkout they act on. Two settings keep the two apart:

    SM_REPO      the public checkout a script reads and runs git/gh in.
                 Unset: a sibling folder named `repo` next to the script's own checkout (the private
                 repo's layout, ~/SpokenMarginsOps/ops beside ~/SpokenMarginsOps/repo), else the
                 script's own checkout (today's layout: the script and its checkout are one).
    SM_OPS_HOME  the folder holding the scripts' state (logs, locks, ledgers), one subfolder per job.
                 Unset: ~/SpokenMarginsOps.
    SM_OWNER_OVERLAY  the owner overlay file (OWNER.md, #1854).
                 Unset: ~/SpokenMarginsOps/ops/OWNER.md, else OWNER.md in a sibling `ops-private` checkout.

Behaviour with neither set is exactly what each script did before.

Python:  from sm_paths import repo, ops_home, state_dir, own_root, owner_overlay
Shell:   sm_paths_dir=$(cd "$(dirname "$0")" && pwd); . "$sm_paths_dir/sm_paths.sh"   # sets SM_REPO, SM_OPS_HOME
CLI:     sm_paths.py repo [--anchor FILE] | ops-home | state NAME | owner-overlay [--anchor FILE]
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Mapping, Optional

OPS_HOME_FOLDER = 'SpokenMarginsOps'
SIBLING_REPO_FOLDER = 'repo'
OVERLAY_REPO_FOLDER = 'ops-private'   # the private repo holding OWNER.md (#1854); cloud sessions clone it beside the checkout
OVERLAY_FILE = 'OWNER.md'
_ROOT_MARKERS = ('.git', 'project.yml')


def _setting(name: str, env: Optional[Mapping[str, str]]) -> Optional[str]:
    value = (os.environ if env is None else env).get(name)
    return value.strip() or None if value else None


def _absolute(value: str) -> Path:
    return Path(os.path.abspath(os.path.expanduser(value)))


def own_root(anchor: str | os.PathLike) -> Path:
    """The checkout a script file lives in: the nearest parent holding `.git` or `project.yml`.

    A script outside any checkout (a copied file) is its own root, so callers never get None.
    """
    start = Path(anchor).resolve()
    for folder in [start] + list(start.parents):
        if folder.is_dir() and any((folder / marker).exists() for marker in _ROOT_MARKERS):
            return folder
    return start if start.is_dir() else start.parent


def ops_home(env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None) -> Path:
    """SM_OPS_HOME, else ~/SpokenMarginsOps. The state folders do not move."""
    setting = _setting('SM_OPS_HOME', env)
    if setting:
        return _absolute(setting)
    return (home or Path.home()) / OPS_HOME_FOLDER


def state_dir(name: str, env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None) -> Path:
    """One job's state folder under ops_home(), for example state_dir('disk-relief')."""
    return ops_home(env, home) / name


def state_dir_or(name: str, fallback: str | os.PathLike, env: Optional[Mapping[str, str]] = None) -> Path:
    """state_dir(name) when SM_OPS_HOME is set, else `fallback`: for a job whose state never lived under ~/SpokenMarginsOps."""
    return state_dir(name, env) if _setting('SM_OPS_HOME', env) else Path(fallback)


def repo(anchor: str | os.PathLike, default: str | os.PathLike | None = None,
         env: Optional[Mapping[str, str]] = None) -> Path:
    """The public checkout the script at `anchor` (pass __file__) acts on.

    SM_REPO wins. Then `default`, for a script whose checkout was never its own (the disk job acts on the
    owner's development checkout). Then a sibling `repo` checkout next to the script's own, then the script's own.
    """
    setting = _setting('SM_REPO', env)
    if setting:
        return _absolute(setting)
    if default is not None:
        return Path(default)
    root = own_root(anchor)
    sibling = root.parent / SIBLING_REPO_FOLDER
    try:
        if sibling != root and (sibling / '.git').exists():
            return sibling
    except OSError:  # a launchd job without folder access: the script's own checkout is the answer it had before
        pass
    return root


def owner_overlay(anchor: str | os.PathLike, env: Optional[Mapping[str, str]] = None,
                  home: Optional[Path] = None) -> Optional[Path]:
    """The owner overlay (OWNER.md) that adds to the public AGENTS.md, or None when it is not on this machine (#1854).

    SM_OWNER_OVERLAY wins when it names a file. Then ~/SpokenMarginsOps/ops/OWNER.md (the owner's Mac), then
    OWNER.md in an `ops-private` checkout next to the script's own (how a cloud session lays the two repos out).
    """
    setting = _setting('SM_OWNER_OVERLAY', env)
    if setting:
        try:
            return _absolute(setting) if _absolute(setting).is_file() else None
        except OSError:  # no folder access: no overlay is the honest answer
            return None
    candidates = [ops_home(env, home) / 'ops' / OVERLAY_FILE, own_root(anchor).parent / OVERLAY_REPO_FOLDER / OVERLAY_FILE]
    for path in candidates:
        try:
            if path.is_file():
                return path
        except OSError:  # a launchd job without folder access: no overlay is the honest answer
            continue
    return None


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('what', choices=('repo', 'ops-home', 'state', 'owner-overlay'))
    parser.add_argument('name', nargs='?', help='the job folder, for `state`')
    parser.add_argument('--anchor', default=__file__, help='a file inside the script\'s own checkout (default: this one)')
    args = parser.parse_args(argv)
    if args.what == 'repo':
        print(repo(args.anchor))
    elif args.what == 'ops-home':
        print(ops_home())
    elif args.what == 'owner-overlay':
        found = owner_overlay(args.anchor)
        if found is None:
            return 1
        print(found)
    elif args.name:
        print(state_dir(args.name))
    else:
        parser.error('state needs a job name')
    return 0


if __name__ == '__main__':
    sys.exit(main())
