#!/usr/bin/env python3
"""The `automerge` label queues a PR in GitHub's merge queue, and removing it takes the PR out (#4693).

Agents already arm a PR by adding `automerge` (AGENTS.md, the lane-request skill, the Claude worker). Keeping that
one interface means no session's instructions have to change in the hour the queue goes on: this script turns the
label into the queue's own commands. merge-queue-label-bridge.yml runs it from main's copy, never the PR's.

- Label added, or found by a sweep: a draft PR, or one whose title contains "DO NOT MERGE" or starts with
  "Throwaway", is never queued; it gets one comment saying why (a hidden marker stops a second one). Any other PR
  gets `gh pr merge <n>` with no method flag: with a required merge queue that enables auto-merge, so GitHub queues
  the PR once its required checks pass. "Already queued" or "auto-merge already enabled" counts as done.
- Label removed: `gh pr merge <n> --disable-auto`, and when the PR is already in the queue, the GraphQL
  `dequeuePullRequest` mutation takes it out.

Every call is tried a few times. One plain line per PR. Exit 1 only when a PR that should have been queued or
dequeued could not be, so the run shows red and the next sweep tries again.

Run: `python3 scripts/merge_queue_label_bridge.py --repo owner/name (--pr N --action labeled|unlabeled | --sweep)`.
"""
import argparse
import json
import re
import subprocess
import sys
import time

LABEL = 'automerge'
TRIES = 3
MARKER = '<!-- merge-queue-label-bridge not-queued -->'
# gh's wording when there is nothing left to do: the PR is already queued or already set to merge.
ALREADY = re.compile(r'already (queued|in the merge queue|enabled)|auto-?merge (is )?already|is already set to', re.I)
NOT_QUEUED = re.compile(r'not (in|on) the merge queue|not queued', re.I)

PR_QUERY = '''query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) { id isDraft title state labels(first: 50) { nodes { name } } mergeQueueEntry { id } }
  }
}'''
DEQUEUE = 'mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { clientMutationId } }'


class Failed(Exception):
    pass


class GitHub:
    """The `gh` calls this script makes. The tests replace it at this boundary."""

    def __init__(self, repo, sleep=time.sleep):
        self.repo = repo
        self.owner, self.name = repo.split('/', 1)
        self.sleep = sleep

    def gh(self, args):
        """(returncode, stdout + stderr) after up to TRIES attempts; a non-zero code is returned, not raised."""
        out = ''
        for attempt in range(TRIES):
            try:
                done = subprocess.run(['gh', *args], text=True, capture_output=True, timeout=90)
            except (OSError, subprocess.SubprocessError) as error:
                out = repr(error)
            else:
                out = (done.stdout or '') + (done.stderr or '')
                if done.returncode == 0 or ALREADY.search(out) or NOT_QUEUED.search(out):
                    return done.returncode, out
            if attempt + 1 < TRIES:
                self.sleep(2 ** attempt)
        return 1, out

    def graphql(self, query, **variables):
        args = ['api', 'graphql', '-f', f'query={query}']
        for key, value in variables.items():
            args += ['-F' if isinstance(value, int) else '-f', f'{key}={value}']
        code, out = self.gh(args)
        if code:
            raise Failed(out.strip()[-300:])
        try:
            return json.loads(out)
        except ValueError as error:
            raise Failed(f'unreadable answer: {error}') from error

    def pull(self, number):
        data = self.graphql(PR_QUERY, owner=self.owner, name=self.name, number=int(number))
        pr = ((data.get('data') or {}).get('repository') or {}).get('pullRequest')
        if not pr:
            raise Failed(f'no pull request #{number}')
        return pr

    def armed_numbers(self):
        code, out = self.gh(['pr', 'list', '--repo', self.repo, '--state', 'open', '--label', LABEL,
                             '--limit', '200', '--json', 'number'])
        if code:
            raise Failed(out.strip()[-300:])
        return sorted(item['number'] for item in json.loads(out))

    def comments(self, number):
        code, out = self.gh(['api', f'repos/{self.repo}/issues/{number}/comments', '--paginate',
                             '--jq', '.[].body'])
        if code:
            raise Failed(out.strip()[-300:])
        return out

    def comment(self, number, body):
        code, out = self.gh(['pr', 'comment', str(number), '--repo', self.repo, '--body', body])
        if code:
            raise Failed(out.strip()[-300:])

    def merge(self, number):
        return self.gh(['pr', 'merge', str(number), '--repo', self.repo])

    def disable_auto(self, number):
        return self.gh(['pr', 'merge', str(number), '--repo', self.repo, '--disable-auto'])

    def dequeue(self, node_id):
        self.graphql(DEQUEUE, id=node_id)


def not_queueable(pr):
    """Why this PR must never be queued, or None."""
    title = (pr.get('title') or '').strip()
    if pr.get('isDraft'):
        return 'it is a draft'
    if 'do not merge' in title.lower():
        return 'its title says DO NOT MERGE'
    if title.lower().startswith('throwaway'):
        return 'its title starts with "Throwaway"'
    return None


def labels(pr):
    return {node['name'] for node in ((pr.get('labels') or {}).get('nodes') or [])}


def queue(github, number, out=sys.stdout):
    """Queue one armed PR. True when it is queued, set to merge, or rightly left alone."""
    pr = github.pull(number)
    if pr.get('state') != 'OPEN':
        print(f'#{number}: not open, nothing to do', file=out)
        return True
    if LABEL not in labels(pr):
        print(f'#{number}: no `{LABEL}` label any more, nothing to do', file=out)
        return True
    why = not_queueable(pr)
    if why:
        if MARKER not in github.comments(number):
            github.comment(number, f'{MARKER}\nNot queued for merging: {why}. The `{LABEL}` label stays, but the merge '
                                   'queue will not take this PR until that changes and the label is added again.')
        print(f'#{number}: not queued, {why}', file=out)
        return True
    if pr.get('mergeQueueEntry'):
        print(f'#{number}: already in the merge queue', file=out)
        return True
    code, text = github.merge(number)
    if code == 0 or ALREADY.search(text):
        print(f'#{number}: queued (GitHub adds it once its required checks pass)', file=out)
        return True
    print(f'#{number}: could not queue: {text.strip()[-300:]}', file=out)
    return False


def unqueue(github, number, out=sys.stdout):
    """Take one PR back out: no auto-merge, and out of the queue if it is in. True when done."""
    pr = github.pull(number)
    if LABEL in labels(pr):
        print(f'#{number}: `{LABEL}` is back on, left queued', file=out)
        return True
    code, text = github.disable_auto(number)
    ok = code == 0 or bool(re.search(r'not enabled|no auto-?merge|not set to', text, re.I))
    if pr.get('mergeQueueEntry'):
        github.dequeue(pr['id'])
        print(f'#{number}: taken out of the merge queue', file=out)
        return True
    print(f'#{number}: auto-merge off' if ok else f'#{number}: could not turn auto-merge off: {text.strip()[-300:]}',
          file=out)
    return ok


def main(argv=None, github=None, out=sys.stdout):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', type=int)
    parser.add_argument('--action', choices=['labeled', 'unlabeled'])
    parser.add_argument('--label', default=LABEL, help='the label the event is about; only `automerge` is acted on')
    parser.add_argument('--sweep', action='store_true', help='queue every open PR that carries `automerge`')
    args = parser.parse_args(argv)
    github = github or GitHub(args.repo)
    if args.label != LABEL:
        print(f'label `{args.label}` is not `{LABEL}`: nothing to do', file=out)
        return 0
    try:
        if args.sweep or not args.pr:
            numbers = github.armed_numbers()
            print(f'{len(numbers)} open PRs carry `{LABEL}`', file=out)
            results = []
            for number in numbers:
                try:
                    results.append(queue(github, number, out))
                except Failed as error:
                    print(f'#{number}: could not read: {error}', file=out)
                    results.append(False)
            return 0 if all(results) else 1
        act = unqueue if args.action == 'unlabeled' else queue
        return 0 if act(github, args.pr, out) else 1
    except Failed as error:
        print(f'could not reach GitHub: {error}', file=out)
        return 1


if __name__ == '__main__':
    sys.exit(main())
