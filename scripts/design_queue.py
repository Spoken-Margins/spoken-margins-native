#!/usr/bin/env python3
"""Design queue (#3866): which `needs-design` issues the design pass takes next, as one batch. Stdlib, Python 3.9+.

An issue that changes what a listener sees or hears carries `needs-design` until an Opus pass posts its **Design**
comment (owner, 2026-11-09). On 2026-11-12 the backlog comb found 56 such issues and not one Design comment: the
routine #3866 asked for had never been built past its label. The Claude Mac worker (ops/claude/sm_claude_worker.py)
now runs a design pass when it has no PR or Mac issue to work on, and this script picks what that pass designs.

  scripts/design_queue.py           print the next batch and what is waiting; change nothing
  scripts/design_queue.py --json    the same for scripts

The order:
  1. The batches in ops/claude/design-queue.json, in file order, each cut to the members still waiting. That list is
     the order the director set on #4187 on 2026-11-12; edit the file to change it.
  2. Then everything else waiting: `priority` first, then oldest. The first such issue anchors a batch, joined by
     the waiting issues that share a parent with it (`Part of #N`) or that it names, so one flow is designed once.

An issue is waiting when it is open, carries `needs-design`, has no trusted **Design** comment yet, is not held
(`blocked`, `deferred`, `in-progress`, `needs-owner`, `parked`, `tracker`, or the Later milestone), and is not on the file's `hold`
list (issues a person is designing by hand). An issue with a trusted Design comment that still carries
`needs-design` is listed as `designed_unlabelled`: the swap was missed, and `scripts/sm_sweep.py` reports it.

The design pass's own stop note (`Thread "Claude Mac worker N" stopping: design pass, K of M designed`) is how a
batch is paced. The note sits on the anchor and names every member (`Batch: #1, #2.`), so it paces each of them: none
within FAULT_COOLDOWN of the last run it was in, and an issue whose last NO_PROGRESS_LIMIT runs in a week all
designed nothing is passed over (`stuck`), and so is one in MAX_FAULTS fault notes (`stopping: design pass not
run`, the model never ran) in a day. A batch that keeps failing therefore stops after the same few runs as one
issue would, instead of re-anchoring on each member in turn. `scripts/design_queue.py` prints the stuck ones.

Reads one `gh issue list` (open `needs-design` issues with their comments); writes nothing.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import comment_trust  # noqa: E402  (#1822: only the owner's, collaborators' and the bot's comments count)

REPO = 'Spoken-Margins/spoken-margins-native'
LABEL = 'needs-design'
QUEUE_FILE = HERE.parent / 'ops' / 'claude' / 'design-queue.json'
HELD_LABELS = {'blocked', 'deferred', 'in-progress', 'needs-owner', 'parked', 'tracker'}
PARKED_MILESTONE = 'Later'
MAX_BATCH = 8                                   # the largest batch on #4187; a bigger one will not fit one run
FAULT_COOLDOWN = dt.timedelta(minutes=30)       # as the worker's own FAULT_COOLDOWN
NO_PROGRESS_WINDOW = dt.timedelta(days=7)
NO_PROGRESS_LIMIT = 2                           # runs in a row that designed nothing before an anchor is passed over

# A Design comment's first line is its heading: "**Design**", "## Design", "**Design (batch 1, 2 of 8)**".
# "Design pass: …", "Designed …" and "Design question" are not Design comments.
DESIGN_HEAD = re.compile(r'^\s*(?:#{1,6}\s*)?(?:\*\*|__)?\s*Design\s*(?:\*\*|__)?\s*(?:$|[(:—–-]|\*\*|__)')
STOP_NOTE = re.compile(r'Thread "Claude Mac worker \d+" stopping: design pass, (\d+) of (\d+) designed')
FAULT_NOTE = re.compile(r'Thread "Claude Mac worker \d+" stopping: design pass not run\b')   # never reached the model
FAULT_WINDOW = dt.timedelta(hours=24)
MAX_FAULTS = 3                                  # as the worker's MAX_FAULTS: past this the anchor waits for a person
PART_OF = re.compile(r'\b(?:part of|parent:?|sub-issue of)\s+#(\d+)', re.I)
MENTION = re.compile(r'(?<![\w/])#(\d+)\b')
# The worker's stop and fault notes name the whole batch ("Batch: #1, #2."), so every member is paced by every run
# it was in, wherever the note was posted. Without it a failing batch re-anchors on its next member at once.
BATCH_LINE = re.compile(r'\bBatch: (#\d+(?:, #\d+)*)\.')


def when(text: str) -> dt.datetime:
    return dt.datetime.fromisoformat(text.replace('Z', '+00:00'))


def labels_of(issue: dict) -> set:
    return {(label.get('name') if isinstance(label, dict) else label) for label in issue.get('labels') or []}


def milestone_of(issue: dict):
    milestone = issue.get('milestone')
    return milestone.get('title') if isinstance(milestone, dict) else milestone


def first_line(text: str) -> str:
    return next((line for line in (text or '').splitlines() if line.strip()), '')


def is_design_comment(comment: dict) -> bool:
    """A trusted comment whose heading is **Design**."""
    return comment_trust.trusted(comment) and bool(DESIGN_HEAD.match(first_line(comment.get('body') or '')))


def stop_notes(comments: list) -> list:
    """[(time, designed, of)] for the design pass's own stop notes, oldest first. Only trusted ones count."""
    out = []
    for comment in comment_trust.trusted_only(comments):
        match = STOP_NOTE.search(comment.get('body') or '')
        if match:
            out.append((when(comment.get('createdAt') or comment.get('created_at')), int(match[1]), int(match[2])))
    return sorted(out)


def fault_notes(comments: list) -> list:
    """Times of the design pass's fault notes (a run that never reached the model), oldest first. Trusted only."""
    return sorted(when(c.get('createdAt') or c.get('created_at')) for c in comment_trust.trusted_only(comments)
                  if FAULT_NOTE.search(c.get('body') or ''))


def pacing(comments: list, now: dt.datetime):
    """None when the issue may anchor a run now, else 'cooling' or 'stuck'. A fault (no model ran) cools the anchor
    for FAULT_COOLDOWN and never counts as a run that designed nothing; MAX_FAULTS in a day make it stuck."""
    notes = stop_notes(comments)
    faults = fault_notes(comments)
    last = max([n[0] for n in notes[-1:]] + faults[-1:], default=None)
    if last and now - last < FAULT_COOLDOWN:
        return 'cooling'
    if len([t for t in faults if now - t < FAULT_WINDOW]) >= MAX_FAULTS:
        return 'stuck'
    recent = [n for n in notes if now - n[0] < NO_PROGRESS_WINDOW][-NO_PROGRESS_LIMIT:]
    if len(recent) == NO_PROGRESS_LIMIT and all(designed == 0 for _, designed, _ in recent):
        return 'stuck'
    return None


def load_queue(path: Path = QUEUE_FILE) -> dict:
    data = json.loads(path.read_text())
    return {'hold': {int(n): why for n, why in (data.get('hold') or {}).items()},
            'batches': [{'name': b['name'], 'issues': [int(n) for n in b['issues']]} for b in data.get('batches') or []]}


def batch_members(body: str) -> set:
    match = BATCH_LINE.search(body or '')
    return {int(n) for n in re.findall(r'\d+', match[1])} if match else set()


def run_notes(issues: list) -> dict:
    """{issue number: the trusted design-pass notes on other issues whose Batch line names it}."""
    out: dict = {}
    for issue in issues:
        for comment in comment_trust.trusted_only(issue.get('comments') or []):
            body = comment.get('body') or ''
            if STOP_NOTE.search(body) or FAULT_NOTE.search(body):
                for n in batch_members(body) - {issue['number']}:
                    out.setdefault(n, []).append(comment)
    return out


def classify(issues: list, queue: dict, now: dt.datetime) -> dict:
    """Sort the open `needs-design` issues into waiting, designed-but-still-labelled, held, cooling and stuck."""
    out = {'waiting': [], 'designed_unlabelled': [], 'held': [], 'cooling': [], 'stuck': []}
    elsewhere = run_notes(issues)
    for issue in issues:
        names = labels_of(issue)
        if LABEL not in names or (issue.get('state') or 'OPEN').upper() != 'OPEN':
            continue
        comments = issue.get('comments') or []
        if any(is_design_comment(c) for c in comments):
            out['designed_unlabelled'].append(issue)
        elif names & HELD_LABELS or milestone_of(issue) == PARKED_MILESTONE or issue['number'] in queue['hold']:
            out['held'].append(issue)
        else:
            state = pacing(comments + elsewhere.get(issue['number'], []), now)
            out[state or 'waiting'].append(issue)
    return out


def rank(issue: dict) -> tuple:
    return ('priority' not in labels_of(issue), issue.get('createdAt') or '', issue['number'])


def parents(issue: dict) -> set:
    return {int(n) for n in PART_OF.findall(issue.get('body') or '')}


def mentions(issue: dict) -> set:
    return {int(n) for n in MENTION.findall(issue.get('body') or '')}


def next_batch(issues: list, queue: dict, now: dt.datetime):
    """{'name', 'issues': [numbers], 'source': 'queue' | 'flow'} for the next run, or None when nothing waits.

    Only a waiting issue anchors a batch; a stuck one may still ride in a batch another issue anchors."""
    sorted_out = classify(issues, queue, now)
    waiting = {i['number']: i for i in sorted_out['waiting']}
    riders = {**waiting, **{i['number']: i for i in sorted_out['stuck']}}
    for batch in queue['batches']:
        anchor = next((n for n in batch['issues'] if n in waiting), None)
        if anchor is None:
            continue
        # The anchor goes first: the worker re-checks numbers[0], and a stuck rider there would skip the run forever.
        members = [anchor] + [n for n in batch['issues'] if n in riders and n != anchor][:MAX_BATCH - 1]
        return {'name': batch['name'], 'issues': members, 'source': 'queue'}
    queued = {n for batch in queue['batches'] for n in batch['issues']}
    rest = sorted((i for n, i in waiting.items() if n not in queued), key=rank)
    if not rest:
        return None
    anchor = rest[0]
    family = parents(anchor)
    named = mentions(anchor)
    joined = [i for i in sorted((i for n, i in riders.items() if n not in queued and n != anchor['number']), key=rank)
              if (family and parents(i) & family) or i['number'] in named or anchor['number'] in mentions(i)]
    members = [anchor['number']] + [i['number'] for i in joined][:MAX_BATCH - 1]
    return {'name': f"#{anchor['number']} {anchor.get('title') or ''}".strip(), 'issues': members, 'source': 'flow'}


def fetch(repo: str = REPO) -> list:
    """Open `needs-design` issues with labels, milestone, body and comments, through `gh`."""
    out = subprocess.run(['gh', 'issue', 'list', '-R', repo, '--state', 'open', '--label', LABEL, '--limit', '300',
                          '--json', 'number,title,body,labels,createdAt,milestone,state,comments'],
                         capture_output=True, text=True, timeout=300)
    if out.returncode != 0:
        raise RuntimeError(f'gh issue list failed: {(out.stderr or out.stdout).strip()[:300]}')
    return json.loads(out.stdout or '[]')


def report(issues: list, queue: dict, now: dt.datetime) -> dict:
    sorted_out = classify(issues, queue, now)
    batch = next_batch(issues, queue, now)
    return {'batch': batch, 'counts': {k: len(v) for k, v in sorted_out.items()},
            'designed_unlabelled': [i['number'] for i in sorted_out['designed_unlabelled']],
            'stuck': [i['number'] for i in sorted_out['stuck']]}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--repo', default=REPO)
    args = parser.parse_args(argv)
    try:
        issues = fetch(args.repo)
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'design_queue: GitHub unreadable: {error}', file=sys.stderr)
        return 2
    out = report(issues, load_queue(), dt.datetime.now(dt.timezone.utc))
    if args.json:
        print(json.dumps(out, indent=2))
        return 0
    counts = out['counts']
    print(f"needs-design: {counts['waiting']} waiting, {counts['held']} held, {counts['cooling']} cooling, "
          f"{counts['stuck']} stuck, {counts['designed_unlabelled']} designed but still labelled")
    batch = out['batch']
    print(f"Next batch ({batch['source']}): {batch['name']}: " + ', '.join(f'#{n}' for n in batch['issues'])
          if batch else 'Next batch: none')
    if out['designed_unlabelled']:
        print('Designed, label not swapped: ' + ', '.join(f'#{n}' for n in out['designed_unlabelled']))
    if out['stuck']:
        print('Stuck (two runs designed nothing): ' + ', '.join(f'#{n}' for n in out['stuck']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
