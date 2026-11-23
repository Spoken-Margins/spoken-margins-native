#!/usr/bin/env python3
"""The two halves of a gated web or site deploy around the owner's tap (#4982). Stdlib, Python 3.9+.

deploy-web.yml and deploy-site.yml run on a push to main that changes the web player or the website. Their deploy job
waits in a GitHub environment (`web-deploy`, `site-deploy`) until the owner approves it. This script does the rest:

  notice   Before the gated job, as github-actions[bot]: post ONE comment that @mentions the owner on the PR behind the
           pushed commit (a commit comment when there is none), saying what is shipping and linking the run where he
           taps Approve. Agents act under his own login and GitHub does not notify a person of their own activity
           (the same reason as scripts/owner_tap_alert.py), so without this he would not hear that a deploy waits.
  newest   In the gated job, before the copy: fail when main already has a newer commit that touches what this deploy
           copies. A re-run keeps its original commit, so re-running an old red run, or approving an older waiting
           run after a newer one, would otherwise put older code back live while `verify` passes (#4985 audit).
  verify   After the deploy: read what is live with scripts/sm_live.py and fail unless it is the commit just deployed.

  python3 scripts/deploy_check.py notice --target web --sha SHA --run-url URL [--dry-run]
  python3 scripts/deploy_check.py newest --target web --sha SHA
  python3 scripts/deploy_check.py verify --target site --sha SHA

The "what is shipping" list is the commits between the live deploy stamp (deploy.json, which both deploy scripts write)
and SHA that touched what the deploy copies. GH_TOKEN and GITHUB_REPOSITORY come from the environment.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_live  # noqa: E402

OWNER_LOGIN = 'uncomposed'
BOT_LOGIN = 'github-actions[bot]'
SHOWN = 15

# What each deploy copies, so the list names only changes that ship. deploy-web.sh also builds the share-link opener
# from the server's tree (research/B4/server/internal/links) and reads the Margins control center cases.
TARGETS = {
    'web': {'name': 'web player', 'url': sm_live.WEB, 'section': 'web',
            'paths': ['Web', 'research/B4/server/internal/links', 'Contracts/fixtures/margins-control-center',
                      'research/B4/deploy/deploy-web.sh']},
    'site': {'name': 'website', 'url': sm_live.SITE, 'section': 'site',
             'paths': ['Site', 'scripts/deploy-spoken-margins-site.sh']},
}


class Failure(Exception):
    """Something this run can't do; the message is printed and the step fails."""


def git(*args):
    done = subprocess.run(['git', *args], capture_output=True, text=True, timeout=60)
    if done.returncode:
        raise Failure(f'git {args[0]} failed: {done.stderr.strip()[:200]}')
    return done.stdout


def live_commit(stamp):
    """The commit in a deploy stamp, without the `-dirty` mark a Mac deploy of edited files adds; None when unreadable."""
    if 'unknown' in stamp:
        return None
    commit = stamp['commit'].split('-', 1)[0]
    return commit if re.fullmatch(r'[0-9a-f]{7,40}', commit) else None


def shipping(target, live, sha, run=git):
    """(lines, note): the commits that ship, newest first and capped, and a sentence when the list can't be worked out."""
    paths = TARGETS[target]['paths']
    if live:
        try:
            run('merge-base', '--is-ancestor', live, sha)
        except Failure:
            live = None
            note = 'I could not find the live version in main\'s history, so this is only the newest change.'
    else:
        note = 'I could not read which version is live now, so this is only the newest change.'
    if live:
        out = run('log', '--no-merges', '--format=%h %s', f'{live}..{sha}', '--', *paths)
        lines = [line for line in out.splitlines() if line.strip()]
        if not lines:
            return [], 'No change to what this deploy copies since the live version; it copies the same files again.'
        more = len(lines) - SHOWN
        lines = lines[:SHOWN] + ([f'and {more} more'] if more > 0 else [])
        return lines, None
    return [run('log', '-1', '--format=%h %s', sha).strip()], note


def quiet(text):
    """A commit subject with its @mentions broken, so the comment pings only the owner."""
    return text.replace('@', '@​')


def marker(target, sha):
    return f'<!-- deploy-notice: {target} {sha} -->'


def notice_body(target, sha, live, lines, note, run_url):
    info = TARGETS[target]
    head = (f'@{OWNER_LOGIN} the {info["name"]} ({info["url"]}) is ready to update, and it is waiting for your OK.')
    where = f'Live now: {live[:9]}. New: {sha[:9]}.' if live else f'New: {sha[:9]}.'
    body = [head, '', f'What is shipping. {where}']
    if note:
        body.append(note)
    body += [f'- {quiet(line)}' for line in lines]
    body += ['', f'To ship it, open the run and tap "Review deployments", then Approve: {run_url}',
             'If you do nothing, nothing changes. If a newer note like this one arrives, reject this run and approve that one.', '', marker(target, sha)]
    return '\n'.join(body) + '\n'


def gh(*args, payload=None):
    done = subprocess.run(['gh', 'api', *args], input=None if payload is None else json.dumps(payload),
                          capture_output=True, text=True, timeout=60)
    if done.returncode:
        raise Failure(f'gh api {args[-1].split("?")[0]} failed: {done.stderr.strip()[:200]}')
    return json.loads(done.stdout) if done.stdout.strip() else None


def already_posted(comments, target, sha):
    tag = marker(target, sha)
    return any((c.get('user') or {}).get('login') == BOT_LOGIN and tag in (c.get('body') or '') for c in comments)


def post_notice(repo, sha, body, target, api=gh):
    """Comment on the PR behind `sha`, or on the commit. Returns where it went, or where it already was."""
    pulls = api(f'repos/{repo}/commits/{sha}/pulls') or []
    merged = [p for p in pulls if p.get('merge_commit_sha') == sha] or pulls
    if merged:
        number = merged[0]['number']
        comments = api(f'repos/{repo}/issues/{number}/comments?per_page=100') or []
        if already_posted(comments, target, sha):
            return f'PR #{number} (already posted)'
        api('-X', 'POST', '--input', '-', f'repos/{repo}/issues/{number}/comments', payload={'body': body})
        return f'PR #{number}'
    comments = api(f'repos/{repo}/commits/{sha}/comments?per_page=100') or []
    if already_posted(comments, target, sha):
        return f'commit {sha[:9]} (already posted)'
    api('-X', 'POST', '--input', '-', f'repos/{repo}/commits/{sha}/comments', payload={'body': body})
    return f'commit {sha[:9]}'


def notice(args, world=None, run=git, api=gh):
    info = TARGETS[args.target]
    stamp = sm_live.deploy_stamp(world or sm_live.World(), info['url'])
    live = live_commit(stamp)
    lines, note = shipping(args.target, live, args.sha, run=run)
    body = notice_body(args.target, args.sha, live, lines, note, args.run_url)
    if args.dry_run:
        print(body, end='')
        return 0
    repo = os.environ.get('GITHUB_REPOSITORY') or sm_live.REPO
    print(f'Posted the deploy notice on {post_notice(repo, args.sha, body, args.target, api=api)}.')
    return 0


def judge(target, sha, facts, site_tree_moved=False):
    """(problems, warnings) for what sm_live read after a deploy of `sha`."""
    problems, warnings = [], []
    stamp = facts if target == 'web' else facts.get('deploy', facts)
    if 'unknown' in facts:
        return [f'could not read what is live: {facts["unknown"]}'], warnings
    if 'unknown' in stamp:
        return [f'could not read the deploy stamp: {stamp["unknown"]}'], warnings
    if stamp['commit'].endswith('-dirty'):
        problems.append(f'the live stamp says {stamp["commit"]}: copied from a checkout with local edits')
    live = live_commit(stamp)
    if not live or not sha.startswith(live):
        problems.append(f'the live stamp says {stamp["commit"]}, not {sha[:9]}')
    if target == 'web':
        if facts.get('behind'):
            warnings.append(f'main already has {facts["behind"]} newer web change(s); their own deploy run carries them')
        return problems, warnings
    for row in facts.get('rows', []):
        if 'unknown' in row:
            problems.append(f'{row["page"]}: could not read it ({row["unknown"]})')
        elif row['http'] != 200:
            problems.append(f'{row["page"]}: HTTP {row["http"]}')
        elif not row['matches_trunk']:
            if site_tree_moved:
                warnings.append(f'{row["page"]} differs from main, which has newer site changes; their own run carries them')
            else:
                problems.append(f'{row["page"]}: differs from main')
    return problems, warnings


def verify(args, world=None, run=git):
    info = TARGETS[args.target]
    world = world or sm_live.World()
    read, render, title = sm_live.READERS[info['section']]
    facts = read(world)
    print(f'{title}, read by scripts/sm_live.py:')
    print('\n'.join(render(facts)))
    moved = False
    if args.target == 'site':
        # sm_live compares the pages with origin/main. When main moved on with newer site changes, a page can differ
        # because this run shipped the older commit; that is the next run's job, not this one's failure.
        moved = run('rev-parse', f'{args.sha}:Site').strip() != run('rev-parse', f'origin/{sm_live.TRUNK}:Site').strip()
    problems, warnings = judge(args.target, args.sha, facts, site_tree_moved=moved)
    for line in warnings:
        print(f'::warning::{line}')
    for line in problems:
        print(f'::error::{line}')
    if problems:
        print(f'The {info["name"]} is not live at {args.sha[:9]}.')
        return 1
    print(f'The {info["name"]} is live at {args.sha[:9]}.')
    return 0


def newer_changes(target, sha, run=git):
    """Short hashes of commits on origin/main after SHA that touch what TARGET copies, newest first."""
    run('fetch', '--quiet', 'origin', 'main')
    out = run('log', '--format=%h', f'{sha}..origin/main', '--', *TARGETS[target]['paths'])
    return [line for line in out.split() if line]


def newest(args, run=git):
    info = TARGETS[args.target]
    newer = newer_changes(args.target, args.sha, run)
    if newer:
        print(f'::error::main already has {len(newer)} newer {info["name"]} change(s) ({", ".join(newer[:5])}); '
              f'deploying {args.sha[:9]} would put older code live. Approve the newest deploy run instead.')
        return 1
    print(f'{args.sha[:9]} is the newest {info["name"]} change on main.')
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description='Notice before and check after a gated web or site deploy.')
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('notice', 'newest', 'verify'):
        part = sub.add_parser(name)
        part.add_argument('--target', choices=sorted(TARGETS), required=True)
        part.add_argument('--sha', required=True)
        if name == 'notice':
            part.add_argument('--run-url', required=True)
            part.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        parser.error('--sha must be a full commit hash')
    try:
        return {'notice': notice, 'newest': newest, 'verify': verify}[args.command](args)
    except (Failure, sm_live.ReadError) as error:
        print(f'deploy_check: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
