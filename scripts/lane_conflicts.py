#!/usr/bin/env python3
"""Hosted merge-conflict check for armed PRs, before they wait for a Mac (#683).

A conflict with the base branch is otherwise found only when the PR's job reaches a Mac runner: #604 passed T2, waited
three hours in the queue, then ended in a 0-second job saying "does not merge cleanly into next". This script
runs on the VPS runner (.github/workflows/lane-conflicts.yml). For every open PR into the base branch that
carries `automerge` or `lane:queued`, it tries `git merge --no-commit --no-ff` of the PR head onto the base tip
in a throwaway worktree. A clean merge changes nothing. A conflict

1. posts one comment per head/base pair, naming the files, in the Mac finisher's hand-off format;
2. adds `needs-mac`, and removes `lane:queued` and `automerge`, so nothing re-queues it;
3. cancels the PR's lane.yml runs whose Mac job has not started, so the queued slot is freed too.

It never pushes to a branch and never force-pushes. Any doubt (a fetch or merge error, a head that moved since
the PR list, an API failure) changes nothing: the Mac's own merge check (lane-runner.py) still catches it.

Run from the base branch's copy, never the PR's: `python3 scripts/lane_conflicts.py --repo OWNER/NAME --base next`.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))

ARMED = ('automerge', 'lane:queued')
REMOVE = ARMED
ADD = 'needs-mac'
HANDOFF = 'Handing to the Mac finisher:'


class GitHubApi:
    def __init__(self, repo):
        self.repo = repo

    def _run(self, args):
        # stderr is kept on the error, so a 404 can be told from any other failure (and never reaches the log raw).
        return subprocess.run(['gh', 'api', *args], text=True, timeout=30, capture_output=True, check=True).stdout

    def get(self, path):
        return json.loads(self._run([f'repos/{self.repo}/{path}']))

    def get_all(self, path):
        pages = json.loads(self._run(['--paginate', '--slurp', f'repos/{self.repo}/{path}']))
        return [item for page in pages for item in (page if isinstance(page, list) else [page])]

    def post(self, path, fields=None):
        args = ['-X', 'POST', f'repos/{self.repo}/{path}']
        for key, value in (fields or {}).items():
            args += ['-f', f'{key}={value}']
        self._run(args)

    def delete(self, path):
        self._run(['-X', 'DELETE', f'repos/{self.repo}/{path}'])


def git(cwd, *args, check=True, auth=None, timeout=300):
    """One git command with no hooks, no LFS downloads, no prompts and no user or system git config.

    `auth` is a token for an https remote. It goes in through the environment (never argv, which `ps` shows and
    an error message repeats) and its derived header is masked in the job log.
    """
    cmd = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.quotePath=false', '-c', 'filter.lfs.smudge=',
           '-c', 'filter.lfs.process=', '-c', 'filter.lfs.required=false', '-c', 'user.name=lane-conflicts',
           '-c', 'user.email=lane@localhost']
    env = dict(os.environ, GIT_LFS_SKIP_SMUDGE='1', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1',
               GIT_CONFIG_GLOBAL=os.devnull)
    if auth:
        basic = base64.b64encode(f'x-access-token:{auth}'.encode()).decode()
        print(f'::add-mask::{basic}')
        env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='http.extraHeader',
                   GIT_CONFIG_VALUE_0=f'Authorization: basic {basic}')
    return subprocess.run(cmd + list(args), cwd=cwd, env=env, text=True, capture_output=True, check=check,
                          timeout=timeout)


def describe(error):
    """An error as one safe log line: git's or gh's own message, never the command line."""
    if isinstance(error, subprocess.CalledProcessError):
        text = (error.stderr or '').strip().replace('\n', ' ')[:300]
        return f'{Path(str(error.cmd[0])).name} exited {error.returncode}' + (f': {text}' if text else '')
    return repr(error)


def fetch(workdir, remote, base, prs, token=None, log=print):
    """Bring the base tip and each PR head into the cached clone. Returns (base tip sha, PRs that fetched).

    The base must fetch or this raises. Each PR head is fetched on its own, so one missing ref (a PR closed or
    deleted mid-run) costs only that PR its check.
    """
    workdir = Path(workdir)
    if not (workdir / '.git').exists():
        workdir.mkdir(parents=True, exist_ok=True)
        git(workdir, 'init', '-q')
    git(workdir, 'remote', 'remove', 'origin', check=False)
    git(workdir, 'remote', 'add', 'origin', remote)
    # Last run's refs and any worktree a killed run left behind.
    for ref in git(workdir, 'for-each-ref', '--format=%(refname)', 'refs/lane-conflicts/').stdout.split():
        git(workdir, 'update-ref', '-d', ref, check=False)
    for stale in Path(tempfile.gettempdir()).glob('sm-lane-merge-*'):
        shutil.rmtree(stale, ignore_errors=True)
    git(workdir, 'worktree', 'prune', check=False)
    git(workdir, 'fetch', '-q', '--no-tags', 'origin', f'+refs/heads/{base}:refs/lane-conflicts/base', auth=token)
    fetched = []
    for pr in prs:
        try:
            git(workdir, 'fetch', '-q', '--no-tags', 'origin', f'+refs/pull/{pr}/head:refs/lane-conflicts/pr-{pr}',
                auth=token)
            fetched.append(pr)
        except subprocess.SubprocessError as error:
            log(f'::warning::#{pr}: could not fetch its head ({describe(error)}); skipped.')
    return git(workdir, 'rev-parse', 'refs/lane-conflicts/base').stdout.strip(), fetched


def conflicts_with(workdir, base_sha, head_sha):
    """The files that conflict when head_sha is merged onto base_sha, [] for a clean merge.

    Raises when git fails for any other reason, so a doubtful run never reads as a conflict.
    """
    workdir = Path(workdir)
    tree = Path(tempfile.mkdtemp(prefix='sm-lane-merge-'))
    try:
        git(workdir, 'worktree', 'add', '-q', '--detach', str(tree), base_sha)
        merged = git(tree, 'merge', '--no-commit', '--no-ff', head_sha, check=False)
        if merged.returncode == 0:
            return []
        files = sorted(set(git(tree, 'diff', '--name-only', '--diff-filter=U').stdout.split('\n')) - {''})
        if not files:
            raise RuntimeError(f'git merge failed without conflicts: {merged.stderr.strip()[:300]}')
        return files
    finally:
        git(tree, 'merge', '--abort', check=False)
        git(workdir, 'worktree', 'remove', '--force', str(tree), check=False)
        shutil.rmtree(tree, ignore_errors=True)
        git(workdir, 'worktree', 'prune', check=False)


def marker(head, base_sha):
    return f'<!-- lane-conflict head={head[:7]} base={base_sha[:7]} -->'


def comment_body(pr_base, base_sha, head, files):
    shown = ', '.join(f'`{name}`' for name in files[:10])
    more = f' and {len(files) - 10} more' if len(files) > 10 else ''
    return (f'{HANDOFF} the PR does not merge cleanly into `{pr_base}` (`{base_sha[:7]}`) at its head '
            f'`{head[:7]}`. Conflicting files: {shown}{more}.\n\n'
            f'Done when: `{pr_base}` is merged into the branch (no force-push), the conflicts are resolved, '
            f'the checks that covered the change pass, and the branch is pushed. Then add `automerge` again '
            f'(and a `/lane` request with `lane:queued` if the diff needs one).\n\n'
            f'Hosted conflict check (#683): `lane:queued` and `automerge` were removed and this PR\'s queued lane '
            f'runs cancelled, so the Mac spends no slot on it. Nothing was pushed to the branch.\n'
            f'{marker(head, base_sha)}')


def cancel_queued_runs(api, pr, head):
    """Cancel the lane.yml runs for this PR head whose Mac jobs have not started. Returns the cancelled run ids."""
    import lane_dedupe
    cancelled = []
    for run_id, run in sorted(lane_dedupe.active_runs(api).items()):
        info = lane_dedupe.parse_run_name(run.get('display_title'))
        if not info or info['pr'] != pr or info['head'] != head:
            continue
        if lane_dedupe.mac_job_started(lane_dedupe.mac_jobs(api, run_id)):
            continue
        api.post(f'actions/runs/{run_id}/cancel')
        cancelled.append(run_id)
    return cancelled


def remove_label(api, pr, name):
    """Remove a label; one that is already gone (404) counts as removed. Returns True when it is gone."""
    try:
        api.delete(f'issues/{pr}/labels/{quote(name, safe="")}')
    except subprocess.CalledProcessError as error:
        if '404' not in (error.stderr or '') and 'Not Found' not in (error.stderr or ''):
            raise
    return True


def act_on_conflict(api, pr, base, base_sha, head, files, log=print):
    """Comment once, move the labels, then cancel queued runs. Returns what was done.

    The queued runs are cancelled only after both lane labels are off the PR: a PR that kept its labels but lost
    its runs would wait with nothing to queue it again. Any failure stops the hand-off and leaves the rest alone.
    """
    done = []
    try:
        current = api.get(f'pulls/{pr}')
        if current['state'] != 'open' or current['head']['sha'] != head:
            log(f'#{pr}: moved on since the check (head or state changed); nothing changed.')
            return done
        labels = {label['name'] for label in current.get('labels', [])}
        if not labels & set(ARMED):
            log(f'#{pr}: no longer armed; nothing changed.')
            return done
        if not any(marker(head, base_sha) in (c.get('body') or '') for c in api.get_all(f'issues/{pr}/comments?per_page=100')):
            api.post(f'issues/{pr}/comments', {'body': comment_body(base, base_sha, head, files)})
            done.append('comment')
        # The labels that start a Mac job go first; needs-mac is the hand-off and goes on last.
        for name in REMOVE:
            if name in labels and remove_label(api, pr, name):
                done.append(f'-{name}')
        if ADD not in labels:
            api.post(f'issues/{pr}/labels', {'labels[]': ADD})
            done.append(f'+{ADD}')
        cancelled = cancel_queued_runs(api, pr, head)
        if cancelled:
            done.append('cancelled ' + ', '.join(str(run) for run in cancelled))
    except (ImportError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        log(f'::warning::#{pr}: the conflict hand-off stopped ({describe(error)}); the Mac check still catches it.')
    return done


def armed_pulls(api, base, only=None):
    pulls = []
    for pull in api.get_all(f'pulls?state=open&base={quote(base, safe="")}&per_page=100'):
        if only and pull['number'] != only:
            continue
        if not {label['name'] for label in pull.get('labels', [])} & set(ARMED):
            continue
        if (pull['head'].get('repo') or {}).get('full_name') != api.repo:
            continue  # a fork: the workflow token can't act on it, and its code is not ours to fetch
        pulls.append(pull)
    return pulls


def sweep(api, remote, base, workdir, token=None, only=None, log=print):
    """Check every armed PR. Returns {pr: [files]} for the PRs that conflicted."""
    pulls = armed_pulls(api, base, only)
    if not pulls:
        log('No armed PRs into ' + base + '.')
        return {}
    base_sha, fetched = fetch(workdir, remote, base, [pull['number'] for pull in pulls], token, log)
    found = {}
    for pull in pulls:
        pr, head = pull['number'], pull['head']['sha']
        if pr not in fetched:
            continue
        try:
            if git(workdir, 'rev-parse', f'refs/lane-conflicts/pr-{pr}').stdout.strip() != head:
                log(f'#{pr}: head moved while fetching; skipped.')
                continue
            files = conflicts_with(workdir, base_sha, head)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            log(f'::warning::#{pr}: could not check ({describe(error)}); the Mac check still catches it.')
            continue
        if not files:
            log(f'#{pr}: merges cleanly into {base} ({base_sha[:7]}).')
            continue
        log(f'#{pr}: CONFLICT with {base} ({base_sha[:7]}): {", ".join(files[:10])}')
        found[pr] = files
        log(f'#{pr}: ' + (', '.join(act_on_conflict(api, pr, base, base_sha, head, files, log)) or 'nothing changed'))
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--repo', default=os.environ.get('GH_REPO'), help='OWNER/NAME')
    parser.add_argument('--base', help='the base branch (default: the trunk)')
    parser.add_argument('--pr', type=int, help='check only this PR')
    parser.add_argument('--remote', help='clone URL (default: the repository on the GitHub server)')
    parser.add_argument('--workdir', default=os.environ.get('SM_LANE_CONFLICTS_DIR')
                        or str(Path.home() / '.cache' / 'sm-lane-conflicts'))
    args = parser.parse_args(argv)
    if args.base is None:  # #1492: the trunk (scripts/trunk.py)
        from trunk import trunk_branch
        args.base = trunk_branch()
    if not args.repo:
        parser.error('--repo or GH_REPO is required')
    remote = args.remote or f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{args.repo}.git'
    try:
        sweep(GitHubApi(args.repo), remote, args.base, args.workdir, os.environ.get('GH_TOKEN'), args.pr)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Never red: a red check wakes the PR's thread as if its code failed. The Mac check still catches conflicts.
        print(f'::warning::Conflict check unavailable ({describe(error)}).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
