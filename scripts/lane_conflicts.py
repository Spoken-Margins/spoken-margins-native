#!/usr/bin/env python3
"""Hosted merge-conflict check for armed PRs, before they wait for a Mac (#683).

A conflict with the base branch is otherwise found only when the PR's job reaches a Mac runner: #604 passed T2, waited
three hours in the queue, then ended in a 0-second job saying "does not merge cleanly into next". This script
runs on the VPS runner (.github/workflows/lane-conflicts.yml). For every open PR into the base branch that
carries `automerge` or `lane:queued`, it tries `git merge --no-commit --no-ff` of the PR head onto the base tip
in a throwaway worktree. A clean merge changes nothing. A conflict

1. posts one comment per head/base pair, naming the files: a `Handing to the conflict resolver:` hand-off (#5320,
   live since 2026-11-26), which says the owning thread has 30 minutes to push its own fix first;
2. adds `conflict-resolver`, and removes `lane:queued` and `automerge`, so nothing re-queues it.
   `scripts/conflict_resolver.py` then merges the base in when the conflict is small, or hands the PR to the Mac
   finisher (`needs-mac`). A `conflict-resolver` PR the resolver has not acted on for STALE_HOURS goes to the
   finisher from here (`promote_stale`), so a broken resolver never strands it;
3. cancels the PR's lane.yml runs whose Mac job has not started, so the queued slot is freed too;
4. takes it out of GitHub's merge queue (#5302). A queued PR can't be pushed to ("Branches that are queued for
   merging cannot be updated"), so the finisher could not push the fix, and a label removed with this job's
   GITHUB_TOKEN wakes no merge-queue-label-bridge run to dequeue it (#5276 sat queued 5 hours). So when GitHub says
   the PR is queued or set to auto-merge, this dispatches merge-queue-label-bridge.yml for that one PR; the bridge
   runs as the App, and takes a handed-off PR (`needs-mac` or `conflict-resolver`) with no arming label out. A PR that is not queued gets no dispatch.

A second case (#4538): git merges the PR cleanly but GitHub reports it as not mergeable (`mergeable: false`, state
`dirty`; seen with a history that has more than one merge base). GitHub builds no merge ref for such a PR and so
starts no `pull_request` workflow for it: removing and re-adding `automerge` does nothing, and the PR sits armed
and silent. The sweep treats it as a hand-off of its own, with a comment that says to merge the base into the
branch, unless a lane run for that head, its own or one dispatched for it, is already waiting or running.

The no-merge-ref case still goes to the Mac finisher (`needs-mac`): nothing in it is for a merge tool to resolve.

It never pushes to a branch and never force-pushes. Any doubt (a fetch or merge error, a head that moved since
the PR list, an API failure) changes nothing: the Mac's own merge check (lane-runner.py) still catches it.

Run from the base branch's copy, never the PR's: `python3 scripts/lane_conflicts.py --repo OWNER/NAME --base next`.
"""
import argparse
import base64
import json
import os
import re
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
RESOLVER = 'conflict-resolver'
RESOLVER_HANDOFF = 'Handing to the conflict resolver:'
STALE_HOURS = 2  # the resolver's 30-minute wait plus its 15-minute schedule, several times over


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

    def graphql(self, query, **variables):
        args = ['graphql', '-f', f'query={query}']
        for key, value in variables.items():
            args += ['-F' if isinstance(value, int) else '-f', f'{key}={value}']
        return json.loads(self._run(args))


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


def marker(head, base_sha, kind='conflict'):
    """One comment per head/base pair and kind. `conflict` is git's; `no-merge-ref` is GitHub's alone (#4538)."""
    if kind == 'conflict':
        return f'<!-- lane-conflict head={head[:7]} base={base_sha[:7]} -->'
    return f'<!-- lane-conflict-{kind} head={head[:7]} base={base_sha[:7]} -->'


def comment_body(pr_base, base_sha, head, files):
    shown = ', '.join(f'`{name}`' for name in files[:10])
    more = f' and {len(files) - 10} more' if len(files) > 10 else ''
    return (f'{RESOLVER_HANDOFF} the PR does not merge cleanly into `{pr_base}` (`{base_sha[:7]}`) at its head '
            f'`{head[:7]}`. Conflicting files: {shown}{more}.\n\n'
            f'If this PR\'s thread is working: within 30 minutes, merge `{pr_base}` into the branch (no force-push), '
            f'resolve the conflicts, push, and add `automerge` again; the resolver then leaves it alone. Otherwise '
            f'the conflict resolver (#5320) merges `{pr_base}` in when the conflict is small and re-arms the PR, or '
            f'hands it to the Mac finisher.\n\n'
            f'Hosted conflict check (#683): `lane:queued` and `automerge` were removed and this PR\'s queued lane '
            f'runs cancelled, so the Mac spends no slot on it. Nothing was pushed to the branch.\n'
            f'{marker(head, base_sha)}')


def no_merge_ref_body(pr_base, base_sha, head):
    return (f'{HANDOFF} GitHub reports this PR as not mergeable into `{pr_base}` (`{base_sha[:7]}`) at its head '
            f'`{head[:7]}`, although git merges it cleanly (usually a history with more than one merge base). '
            f'GitHub builds no merge ref for it, so it starts no lane run when a label is added or removed: '
            f'`automerge` and `lane:queued` would do nothing.\n\n'
            f'Done when: `{pr_base}` is merged into the branch (no force-push) and pushed, so GitHub can merge it '
            f'again. Then add `automerge` again (and a `/lane` request with `lane:queued` if the diff needs one).\n\n'
            f'Hosted conflict check (#4538): `lane:queued` and `automerge` were removed so the PR does not look '
            f'armed while nothing can run. Nothing was pushed to the branch.\n'
            f'{marker(head, base_sha, "no-merge-ref")}')


def live_lane_runs(api):
    """Queued or running lane.yml runs of both kinds: a PR's own, and the ones dispatched for it (release hand-off, audit).

    `lane_dedupe.active_runs` sees only `pull_request` runs, on purpose; a PR GitHub can't merge gets its run by
    `workflow_dispatch`, and that run must not lose its label under it. More than a page, or an API error, raises.
    """
    import lane_dedupe
    runs = dict(lane_dedupe.active_runs(api))
    for status in lane_dedupe.ACTIVE:
        page = api.get(f'actions/workflows/lane.yml/runs?event=workflow_dispatch&status={status}&per_page=100')
        if page['total_count'] > len(page['workflow_runs']):
            raise ValueError(f'more than one page of dispatched {status} runs')
        for found in page['workflow_runs']:
            runs[found['id']] = found
    return runs


def github_cannot_merge(api, pr, head):
    """True when GitHub says the PR can't be merged (`mergeable: false`) and no lane run for this head is live.

    `mergeable` is null while GitHub works it out; null, and any doubt, is not a yes. A live run for the head
    means the PR got its run before GitHub's state changed, so it is left to finish.
    """
    import lane_dedupe
    current = api.get(f'pulls/{pr}')
    if (current.get('state') != 'open' or current['head']['sha'] != head or current.get('mergeable') is not False
            or current.get('mergeable_state') not in (None, 'dirty')):
        return False
    for found in live_lane_runs(api).values():
        info = lane_dedupe.parse_run_name(found.get('display_title'))
        if info and info['pr'] == pr and info['head'] == head:
            return False
    return True


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


QUEUE_STATE = '''query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) { autoMergeRequest { enabledAt } mergeQueueEntry { id } } }
}'''
BRIDGE = 'merge-queue-label-bridge.yml'


def set_to_merge(api, pr):
    """True when GitHub has the PR in the merge queue or set to auto-merge; None when that can't be read."""
    owner, name = api.repo.split('/', 1)
    try:
        found = api.graphql(QUEUE_STATE, owner=owner, name=name, number=int(pr))['data']['repository']['pullRequest']
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return None
    return bool(found and (found.get('autoMergeRequest') or found.get('mergeQueueEntry')))


def release_queue(api, pr, trunk, log=print):
    """Ask the label bridge to take a handed-off PR out of the merge queue (#5302). Returns what was done.

    Only a PR GitHub has queued or set to merge gets the dispatch. When that can't be read the dispatch goes anyway:
    the bridge reads the PR itself and does nothing to one that isn't set to merge. The dispatch is on the trunk,
    the only ref the bridge's `agent-identity` environment admits.
    """
    state = set_to_merge(api, pr)
    if state is False:
        return []
    api.post(f'actions/workflows/{BRIDGE}/dispatches', {'ref': trunk, 'inputs[pr]': str(pr)})
    return ['asked the merge-queue bridge to dequeue' + (' (queue state unread)' if state is None else '')]


def remove_label(api, pr, name):
    """Remove a label; one that is already gone (404) counts as removed. Returns True when it is gone."""
    try:
        api.delete(f'issues/{pr}/labels/{quote(name, safe="")}')
    except subprocess.CalledProcessError as error:
        if '404' not in (error.stderr or '') and 'Not Found' not in (error.stderr or ''):
            raise
    return True


def act_on_conflict(api, pr, base, base_sha, head, files, log=print, kind='conflict'):
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
        if kind != 'conflict' and current.get('mergeable') is not False:
            # The sweep's git merge takes minutes with many PRs; GitHub may have settled since (#4538 review).
            log(f'#{pr}: GitHub no longer reports it as not mergeable; nothing changed.')
            return done
        already = any(marker(head, base_sha, kind) in (c.get('body') or '') for c in api.get_all(f'issues/{pr}/comments?per_page=100'))
        if not already:
            body = comment_body(base, base_sha, head, files) if kind == 'conflict' else no_merge_ref_body(base, base_sha, head)
            api.post(f'issues/{pr}/comments', {'body': body})
            done.append('comment')
        elif kind != 'conflict':
            # Re-armed at the same head and base: say why it came off again rather than do it silently.
            api.post(f'issues/{pr}/comments', {'body': (
                f'{HANDOFF} still not mergeable on GitHub at `{head[:7]}`, so no run can start; `automerge` and '
                f'`lane:queued` came off again. Merge `{base}` into the branch and push, then arm it.')})
            done.append('comment (re-armed)')
        # The labels that start a Mac job go first; the hand-off label goes on last.
        for name in REMOVE:
            if name in labels and remove_label(api, pr, name):
                done.append(f'-{name}')
        add = RESOLVER if kind == 'conflict' else ADD
        if add not in labels:
            api.post(f'issues/{pr}/labels', {'labels[]': add})
            done.append(f'+{add}')
        cancelled = cancel_queued_runs(api, pr, head)
        if cancelled:
            done.append('cancelled ' + ', '.join(str(run) for run in cancelled))
        # Last: the bridge takes out only a PR that already carries a hand-off label and no arming label.
        done += release_queue(api, pr, ((current.get('base') or {}).get('repo') or {}).get('default_branch') or 'main', log)
    except (ImportError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        log(f'::warning::#{pr}: the conflict hand-off stopped ({describe(error)}); the Mac check still catches it.')
    return done


def promote_stale(api, base, now=None, hours=STALE_HOURS, log=print):
    """Hand any `conflict-resolver` PR whose hand-off is older than `hours` to the Mac finisher. Returns the PRs.

    The resolver moves the label itself on every path it finishes; one still on after `hours` means its runs are
    failing or off, and the PR must not wait on them. The finisher's hand-off carries the conflict marker, so the
    Mac worker treats it as a merge conflict.
    """
    import datetime as dt
    now = now or dt.datetime.now(dt.timezone.utc)
    moved = []
    for pull in api.get_all(f'pulls?state=open&base={quote(base, safe="")}&per_page=100'):
        pr = pull['number']
        if RESOLVER not in {label['name'] for label in pull.get('labels', [])}:
            continue
        if (pull['head'].get('repo') or {}).get('full_name') != api.repo:
            continue
        try:
            comments = api.get_all(f'issues/{pr}/comments?per_page=100')
            ours = [c for c in comments if (c.get('body') or '').lstrip().startswith(RESOLVER_HANDOFF)]
            if ours:
                at = dt.datetime.fromisoformat(ours[-1]['created_at'].replace('Z', '+00:00'))
                if now - at < dt.timedelta(hours=hours):
                    continue
            marker_line = next((m.group(0) for c in reversed(ours)
                                for m in [re.search(r'<!-- lane-conflict head=[0-9a-f]{7} base=[0-9a-f]{7} -->',
                                                    c.get('body') or '')] if m), '')
            api.post(f'issues/{pr}/comments', {'body': (
                f'{HANDOFF} the conflict resolver has not acted on this conflict in {hours} hours, so it comes to '
                f'the Mac finisher.\n\nDone when: `{base}` is merged into the branch (no force-push), the conflicts '
                f'are resolved, the checks that covered the change pass, and the branch is pushed. Then add '
                f'`automerge` again.\n{marker_line}')})
            if ADD not in {label['name'] for label in pull.get('labels', [])}:
                api.post(f'issues/{pr}/labels', {'labels[]': ADD})
            remove_label(api, pr, RESOLVER)
            moved.append(pr)
            log(f'#{pr}: the resolver left it {hours} hours; handed to the Mac finisher.')
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            log(f'::warning::#{pr}: could not hand a stale resolver PR on ({describe(error)}).')
    return moved


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
    """Check every armed PR. Returns {pr: [files]} for the PRs that conflicted; [] for a PR git merges but GitHub can't."""
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
            try:
                blind = github_cannot_merge(api, pr, head)
            except (ImportError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                log(f'::warning::#{pr}: could not read GitHub\'s mergeable state ({describe(error)}); left as is.')
                blind = False
            if not blind:
                log(f'#{pr}: merges cleanly into {base} ({base_sha[:7]}).')
                continue
            log(f'#{pr}: merges cleanly by git, but GitHub reports it as not mergeable, so no label event can start a run.')
            found[pr] = []
            log(f'#{pr}: ' + (', '.join(act_on_conflict(api, pr, base, base_sha, head, [], log, kind='no-merge-ref')) or 'nothing changed'))
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
        api = GitHubApi(args.repo)
        if args.pr is None:
            promote_stale(api, args.base)
        sweep(api, remote, args.base, args.workdir, os.environ.get('GH_TOKEN'), args.pr)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Never red: a red check wakes the PR's thread as if its code failed. The Mac check still catches conflicts.
        print(f'::warning::Conflict check unavailable ({describe(error)}).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
