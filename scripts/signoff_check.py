#!/usr/bin/env python3
"""Fail a pull request from an outside contributor when a commit has no `Signed-off-by:` line (#2114).

CONTRIBUTING.md makes the sign-off the contributor's agreement to the Developer Certificate of Origin and to the
licence grant that keeps the later move to MPL-2.0 possible. The grant takes effect only through that line, so a
commit merged without it would block the switch for the files it touches.

Who is checked: the PR's author, by GitHub's `author_association`. A collaborator (OWNER, MEMBER, COLLABORATOR) and a
bot are not: their commits are the owner's, the project's Claude sessions' or automation's, and have never carried a
sign-off. Anyone else (CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, NONE and the rest) must sign every commit, except merge
commits, which carry no contribution of their own.

The workflow (.github/workflows/signoff-check.yml) runs this from the base branch and reads the PR head as git data
only; nothing from the PR is ever executed.

    scripts/signoff_check.py --base <ref> --head <ref> --association NONE --login someone
Exit 0 when nothing is wrong or nobody is checked; 1 when a commit is unsigned (the message says how to fix it).
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys

EXEMPT_ASSOCIATIONS = {'OWNER', 'MEMBER', 'COLLABORATOR'}
SIGNOFF = re.compile(r'^Signed-off-by:[ \t]+\S.*<[^<>\s]+@[^<>\s]+>[ \t]*$', re.M | re.I)
FIELD, RECORD = '\x1f', '\x1e'

FIX = (
    "\nTo fix: run `git rebase --signoff <base branch>` (or `git commit -s --amend` for the last commit), then "
    "`git push --force-with-lease`.\nThe sign-off is how you agree to the terms in CONTRIBUTING.md."
)


def is_bot(login: str, commit_author_email: str = '') -> bool:
    return login.lower().endswith('[bot]') or bool(re.search(r'\[bot\]@users\.noreply\.github\.com$', commit_author_email, re.I))


def parse_log(raw: str) -> list[dict]:
    """`git log --format=%H<US>%P<US>%ae<US>%B<RS>` as a list of {sha, parents, author_email, body}."""
    commits = []
    for record in raw.split(RECORD):
        if not record.strip():
            continue
        sha, parents, email, body = (record.lstrip('\n').split(FIELD, 3) + ['', '', '', ''])[:4]
        commits.append({'sha': sha, 'parents': parents.split(), 'author_email': email, 'body': body})
    return commits


def unsigned(commits: list[dict]) -> list[dict]:
    """The commits that need a sign-off and lack one. Merge commits (two parents or more) are exempt, as are
    commits by a bot account."""
    return [c for c in commits
            if len(c['parents']) < 2 and not is_bot('', c['author_email']) and not SIGNOFF.search(c['body'])]


def check(commits: list[dict], association: str, login: str) -> list[dict]:
    """The offending commits for a PR by `login` with `association`; empty when the author isn't checked."""
    if association.upper() in EXEMPT_ASSOCIATIONS or is_bot(login):
        return []
    return unsigned(commits)


def pr_commits(base: str, head: str) -> list[dict]:
    raw = subprocess.run(['git', 'log', f'--format=%H{FIELD}%P{FIELD}%ae{FIELD}%B{RECORD}', f'{base}..{head}'],
                         check=True, capture_output=True, text=True).stdout
    return parse_log(raw)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--base', required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--association', required=True, help="the PR author's GitHub author_association")
    parser.add_argument('--login', default='', help="the PR author's login")
    args = parser.parse_args(argv)
    commits = pr_commits(args.base, args.head)
    bad = check(commits, args.association, args.login)
    if not bad:
        print(f'sign-off: nothing to fix ({len(commits)} commits; author {args.login or "?"} is {args.association}).')
        return 0
    print(f'sign-off: {len(bad)} of {len(commits)} commits have no `Signed-off-by:` line:')
    for commit in bad:
        print(f'  {commit["sha"][:7]}')
    print(FIX)
    return 1


if __name__ == '__main__':
    sys.exit(main())
