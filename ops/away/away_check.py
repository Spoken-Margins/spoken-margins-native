#!/usr/bin/env python3
"""Away check: is there enough work, and nothing waiting on the owner, before a hand-off?

The lead session runs this before any overnight or away-day hand-off, and when the owner
says "run the away check" (owner, 2026-10-17: "I would really love to feel confident that we
have an exhaustive build queue"). It reads live GitHub state with `gh` and prints a short
report in four numbered parts:

1. Queue depth against time away: open `ready` issues not `in-progress`, plus open audit
   issues, against the Dial's thread count (#589) times the hours away.
2. Holds an agent wrote: lines in AGENTS.md on the trunk (`main`) that make work wait, and whether
   each quotes the owner with a date. A hold with no owner quote is suspect.
3. Owner-only items: open PRs touching `scripts/lane-runner.py` or `.github/` (his merge
   tap), `needs-owner` issues, and issues whose latest comment asks him to run a command.
4. Allowance pace: the latest Mac tick on #337 against the Dial's straight line to the reset.

It reads only; it never edits AGENTS.md, issues or labels. Stdlib only, Python 3.9+.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'dial'))
import dial_gate  # noqa: E402  (the Dial's own parsers, so both read #589 and #337 the same way)
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from sm_paths import ops_home  # noqa: E402  (#1844)
from trunk import trunk_branch  # noqa: E402  (#1492)

REPO = dial_gate.REPO
DIAL_ISSUE = dial_gate.DIAL_ISSUE
STATUS_ISSUE = dial_gate.STATUS_ISSUE

# How many issues one thread finishes per hour of work. Deliberately generous, so the check
# errs toward "thin": a queue that runs dry costs the night; spare issues cost nothing.
# Measured 2026-10-17: 404 PRs merged into next in the 7 days before, with the Dial at
# 5 threads, which is about 0.5 per thread-hour averaged over idle time too.
ISSUES_PER_THREAD_HOUR = 1.0
AUDIT_LABELS = ('found-by-audit', 'review-finding')
OWNER_MERGE_PATHS = ('scripts/lane-runner.py', '.github/')
HOLDS_LISTED = 5    # holds to check, listed in the report; the rest are counted
OWNER_LISTED = 2    # items per owner-only list
TITLE_WIDTH = 60

# ---------- 1. queue (pure) ----------


def label_names(item: dict) -> set[str]:
    return {lab['name'] if isinstance(lab, dict) else lab for lab in item.get('labels', [])}


def queue_verdict(ready: list[dict], audits: list[dict], threads: int, hours: float,
                  rate: float = ISSUES_PER_THREAD_HOUR) -> dict:
    """Workable issues against what the threads can finish while the owner is away.

    Issues carrying `in-progress` are someone's already, and an issue that is both `ready`
    and an audit finding counts once."""
    free = {}
    for item in ready + audits:
        if 'in-progress' not in label_names(item):
            free[item['number']] = item
    ready_free = sum(1 for i in ready if i['number'] in free)
    have = len(free)
    need = int(round(threads * hours * rate))
    return {'ready': ready_free, 'audits': have - ready_free, 'have': have, 'need': need,
            'enough': have >= need, 'short': max(0, need - have)}


# ---------- 2. holds in AGENTS.md (pure) ----------

HOLD_RE = re.compile(
    r"\buntil\b|\bwaits?\b|\bwaiting\b|\b(?:on|a|to) hold\b|\bholds? (?:back|off|new work|work)\b|"
    r"no `ready`|planning only|\bstays? off\b|\bonly (?:after|when|once|until)\b|"
    r"\bonly\b[^.]*\b(?:issues?|work|threads?)\b",
    re.IGNORECASE)
# A hold on work names the work: a hold on how the player behaves isn't one.
WORK_RE = re.compile(
    r"\b(?:work|issues?|threads?|`?ready`?|dispatch|milestone|co-op|open source|solid ground|"
    r"`?later`?|planning|prs?|starts?|beta|code|slices?)\b",
    re.IGNORECASE)
# The wording that stopped Co-op on 10-16 and its kin; these are listed first.
STRONG_HOLD_RE = re.compile(r"no `ready`|planning only|\bstays? off\b|\bon hold\b|\bwaits? (?:until|for)\b|"
                            r"\buntil (?:then|after)\b", re.IGNORECASE)
# A sentence that ends or denies a hold doesn't make work wait.
NEGATED_RE = re.compile(
    r"not a hold|never a hold|no longer|nothing waits|waits? (?:on|behind) nothing|ended|"
    r"\bgone\b|doesn't wait|don't wait|never waits|is lifted|lifts|\bnever stop\b|could wait",
    re.IGNORECASE)
DATE_RE = re.compile(r'\b20\d\d-\d\d-\d\d\b')
QUOTE_RE = re.compile(r'"[^"]*\w+\s+\w+[^"]*"|“[^”]*\w+\s+\w+[^”]*”')
OWNER_RE = re.compile(r"\bowner\b|\bowner's\b|\bhe (?:said|picked|added|chose)\b", re.IGNORECASE)


# Words in his quote that ask for a wait. "I am giving you the go" does not.
WAIT_WORD_RE = re.compile(r"hold|wait|paus|until|after|\bonly\b|\bstop|\boff\b|later|before|"
                          r"not yet|don't|shouldn't|no more", re.IGNORECASE)


def is_owner_quoted(text: str) -> bool:
    """A dated owner call: a date, plus his words in quote marks or an "(owner, date)" tag."""
    return bool(DATE_RE.search(text)) and bool(QUOTE_RE.search(text) or OWNER_RE.search(text))


def quotes_a_wait(text: str) -> bool:
    return any(WAIT_WORD_RE.search(m.group(0)) for m in QUOTE_RE.finditer(text))


def hold_backing(chain: list[str]) -> str:
    """Who stands behind a hold, from its line and the bullets and lead-in above it.

    'owner': a date, and his quoted words ask for a wait.
    'unbacked': a dated owner call, but his quoted words don't ask for this wait. The
        10-16 "Co-op is planning only" hold sat under "I am giving you the go." like this.
    'suspect': no dated owner call at all."""
    text = '\n'.join(chain)
    if not DATE_RE.search(text) or not any(is_owner_quoted(t) for t in chain):
        return 'suspect'
    return 'owner' if quotes_a_wait(text) else 'unbacked'


def sentences(text: str) -> list[str]:
    """Split after . ! or ? even when bold or a closing quote follows (`go."`, `Co-op.**`)."""
    return [s for s in re.sub(r'([.!?][*"\u201d)\']*)\s+', '\\1\n', text).split('\n') if s.strip()]


def scan_holds(agents_md: str) -> list[dict]:
    """Every line of AGENTS.md with a sentence that makes work wait.

    Each is marked by `hold_backing` from the line, the bullets it sits under and the
    paragraph leading into them, and the `##` section. Fenced code is skipped."""
    out = []
    parents: list[tuple[int, str]] = []   # (indent, text) of enclosing bullets
    section = ''
    in_fence = False
    for n, raw in enumerate(agents_md.splitlines(), start=1):
        if raw.lstrip().startswith('```'):
            in_fence = not in_fence
            continue
        if in_fence or not raw.strip():
            continue
        if raw.startswith('#'):
            section, parents = raw, []
            continue
        indent = len(raw) - len(raw.lstrip())
        bullet = re.match(r'\s*(?:[-*]|\d+\.)\s+', raw) is not None
        if not bullet and indent == 0:
            parents = [(-1, raw)]   # a lead-in paragraph covers the bullets under it
        while parents and parents[-1][0] >= indent:
            parents.pop()
        chain = [section] + [t for _, t in parents]
        if bullet:
            parents.append((indent, raw))
        holds = [s for s in sentences(raw.strip())
                 if HOLD_RE.search(s) and WORK_RE.search(s) and not NEGATED_RE.search(s)]
        if not holds:
            continue
        text = next((h for h in holds if STRONG_HOLD_RE.search(h)), holds[0])
        out.append({'line': n, 'text': text.strip(' -*'), 'backing': hold_backing(chain + [raw])})
    return out


# ---------- 3. owner-only items (pure) ----------

COMMAND_RE = re.compile(r'```(?:zsh|bash|sh|shell|console)?\s*\n\s*\S.*?```|`[^`\n]+`', re.DOTALL)
# Words that put the command in the owner's hands. Narrative ("the same command run from the
# Terminal panel built fine") must not count, so a bare mention of Terminal is not enough.
ASK_RE = re.compile(
    r"\b(?:please run|(?:can|could|would) you run|you(?:'ll)? need to run|run this|run these|"
    r"run the following|paste (?:this|these|the following)|owner(?:'s)? (?:step|action)|"
    r"(?:for|needs?) (?:the owner|cole|you) to run|cole,? (?:run|please))\b",
    re.IGNORECASE)

NO_ASK_RE = re.compile(r"\bno owner (?:step|action)s?\b|\bowner (?:step|action)s?\W{0,3}(?:is |are )?none\b",
                       re.IGNORECASE)


def asks_owner_to_run(body: str) -> bool:
    """The comment hands the owner a command to run: a command in code marks plus words
    asking him to run it."""
    if not body or not COMMAND_RE.search(body):
        return False
    return bool(ASK_RE.search(NO_ASK_RE.sub('', body)))


def touches_owner_paths(files: list[dict]) -> bool:
    return any(f['path'] == p or (p.endswith('/') and f['path'].startswith(p))
               for f in files for p in OWNER_MERGE_PATHS)


# ---------- 4. allowance pace (pure) ----------


def pace(now: dt.datetime, usage_info: dict, dial: dict) -> dict:
    """Weekly use against the Dial's straight line from the week's start to its stop line."""
    stop = dial.get('stop') or 100
    line = dial_gate.trend_line(now, stop, dial.get('hours_early', 0))
    usage = usage_info.get('usage')
    reset = dial_gate.next_reset(now)
    out = {'line': line, 'stop': stop, 'reset': reset, 'halted_by': usage_info.get('halted_by', []),
           'percent': None, 'age_h': None, 'gap': None}
    if usage:
        out['percent'] = usage['percent']
        out['age_h'] = (now - usage['at']).total_seconds() / 3600
        out['gap'] = usage['percent'] - line
    return out


# ---------- report (pure) ----------


def short(title: str, width: int = TITLE_WIDTH) -> str:
    title = ' '.join(title.split())
    return title if len(title) <= width else title[:width - 1].rstrip() + '…'


def listed(items: list[dict], width: int = TITLE_WIDTH, most: int = OWNER_LISTED) -> list[str]:
    lines = [f'   - #{i["number"]} {short(i["title"], width)}' for i in items[:most]]
    if len(items) > most:
        lines.append(f'   - and {len(items) - most} more')
    return lines


def plural(n: int, word: str, many: str | None = None) -> str:
    return f'{n} {word if n == 1 else (many or word + "s")}'


def report(now: dt.datetime, hours: float, dial: dict, q: dict, holds: list[dict],
           owner_prs: list[dict], needs_owner: list[dict], run_asks: list[dict], p: dict) -> str:
    local = now.astimezone(ZoneInfo('America/Chicago'))
    out = [f'Away check, {local:%a %-d %b %-I:%M %p} CT, for {hours:g} hours away.']

    threads = dial['threads'] if dial['mode'] != 'off' else 0
    if dial['mode'] == 'off':
        out.append('1. Queue: the Dial is Off, so no thread starts while you are away. '
                   f'{q["have"]} issues are free.')
    else:
        word = 'enough' if q['enough'] else 'thin'
        line = (f'1. Queue: {word}. {q["have"]} free issues ({q["ready"]} ready, '
                f'{plural(q["audits"], "audit finding")}) against about {q["need"]} '
                f'that {plural(threads, "thread")} can finish in {hours:g} hours.')
        if not q['enough']:
            line += f' Short by {q["short"]}: label more ready issues or open standing audits.'
        out.append(line)

    suspect = [h for h in holds if h['backing'] == 'suspect']
    unbacked = [h for h in holds if h['backing'] == 'unbacked']
    owned = len(holds) - len(suspect) - len(unbacked)
    line = (f'2. Holds in AGENTS.md: {plural(len(holds), "line")} make work wait; '
            f'{owned} quote the owner asking for it, with a date.')
    if suspect or unbacked:
        out.append(line + f' Check {len(suspect)} with no dated owner call and {len(unbacked)} '
                   'that cite him but quote no wait:')
        shown = sorted(suspect + unbacked,
                       key=lambda h: (not STRONG_HOLD_RE.search(h['text']), h['line']))[:HOLDS_LISTED]
        out += [f'   - line {h["line"]}{" (cites him)" if h["backing"] == "unbacked" else ""}: '
                f'{short(h["text"], 70)}' for h in shown]
        if len(suspect) + len(unbacked) > len(shown):
            out.append(f'   - and {len(suspect) + len(unbacked) - len(shown)} more')
    else:
        out.append(line + ' None to check.')

    total = len(owner_prs) + len(needs_owner) + len(run_asks)
    if not total:
        out.append('3. Only you: nothing. No merge taps, no needs-owner issues, no commands to run.')
    else:
        out.append(f'3. Only you, before you leave: {plural(total, "item")}.')
        if owner_prs:
            out.append(f'   Merge tap (lane runner or .github): {len(owner_prs)}')
            out += listed(owner_prs)
        if needs_owner:
            out.append(f'   Labelled needs-owner: {len(needs_owner)}')
            out += listed(needs_owner)
        if run_asks:
            out.append(f'   A comment asks you to run a command: {len(run_asks)}')
            out += listed(run_asks)

    left = p['reset'] - now
    reset_in = f'{left.days * 24 + left.seconds // 3600} hours'
    if p['percent'] is None:
        out.append(f'4. Allowance: no usage on #{STATUS_ISSUE} to read. The reset is in {reset_in}.')
    else:
        gap = p['gap']
        if abs(gap) < 3:
            where = 'on the line'
        elif gap < 0:
            where = f'{-gap:.0f} points behind the line, so allowance is going unused'
        else:
            where = f'{gap:.0f} points ahead of the line'
        breaker = ('Breaker HALT for ' + ', '.join(p['halted_by'])) if p['halted_by'] else 'Breaker clear'
        stale = f' The tick is {p["age_h"]:.0f} hours old; the Mac may be off.' if p['age_h'] > 3 else ''
        out.append(f'4. Allowance: {p["percent"]}% used, the line says {p["line"]:.0f}% '
                   f'(stop line {p["stop"]}%), {where}. {breaker}. '
                   f'The reset is in {reset_in}.{stale}')
    return '\n'.join(out)


# ---------- GitHub (I/O) ----------


def gh_json(*args: str):
    out = subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None


def issues(label: str) -> list[dict]:
    return gh_json('issue', 'list', '--repo', REPO, '--state', 'open', '--label', label,
                   '--limit', '1000', '--json', 'number,title,labels')


def all_comments(issue: int) -> list[dict]:
    pages = gh_json('api', '--paginate', '--slurp',
                    f'repos/{REPO}/issues/{issue}/comments?per_page=100')
    return [c for page in pages for c in page]


LATEST_COMMENTS_QUERY = '''
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number title comments(last: 1) { nodes { body } } }
    }
  }
}'''


def latest_comments() -> list[dict]:
    owner, name = REPO.split('/')
    found, cursor = [], None
    while True:
        args = ['api', 'graphql', '-f', f'query={LATEST_COMMENTS_QUERY}',
                '-f', f'owner={owner}', '-f', f'name={name}']
        if cursor:
            args += ['-f', f'cursor={cursor}']
        page = gh_json(*args)['data']['repository']['issues']
        for node in page['nodes']:
            last = node['comments']['nodes']
            found.append({'number': node['number'], 'title': node['title'],
                          'body': last[0]['body'] if last else ''})
        if not page['pageInfo']['hasNextPage']:
            return found
        cursor = page['pageInfo']['endCursor']


def agents_md(ref: str) -> str:
    """The public guide on the trunk, plus the owner overlay when it is on this machine (#1854).

    The overlay holds Current focus and the standing calls, so the holds live there; without it the scan
    sees only the public guide."""
    text = subprocess.run(
        ['gh', 'api', '-H', 'Accept: application/vnd.github.raw', f'repos/{REPO}/contents/AGENTS.md?ref={ref}'],
        check=True, capture_output=True, text=True).stdout
    overlay = ops_home() / 'ops' / 'OWNER.md'
    if overlay.is_file():
        text += '\n' + overlay.read_text()
    else:
        print(f'note: {overlay} not found; holds in the owner overlay were not scanned', file=sys.stderr)
    return text


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--hours', type=float, required=True, help='hours the owner will be away')
    ap.add_argument('--rate', type=float, default=ISSUES_PER_THREAD_HOUR,
                    help='issues one thread finishes per hour (default %(default)s)')
    ap.add_argument('--ref', default=trunk_branch(), help='branch to read AGENTS.md from (default: the trunk)')
    args = ap.parse_args(argv)

    now = dt.datetime.now(dt.timezone.utc)
    dial_body = gh_json('issue', 'view', str(DIAL_ISSUE), '--repo', REPO, '--json', 'body')['body']
    dial = dial_gate.parse_dial(dial_body)

    ready = issues('ready')
    audits = [i for label in AUDIT_LABELS for i in issues(label)]
    q = queue_verdict(ready, audits, dial['threads'], args.hours, args.rate)

    holds = scan_holds(agents_md(args.ref))

    prs = gh_json('pr', 'list', '--repo', REPO, '--state', 'open', '--limit', '300',
                  '--json', 'number,title,files')
    owner_prs = [p for p in prs if touches_owner_paths(p.get('files') or [])]
    needs_owner = issues('needs-owner')
    run_asks = [i for i in latest_comments() if asks_owner_to_run(i['body'])]

    usage_info = dial_gate.parse_usage(all_comments(STATUS_ISSUE))
    p = pace(now, usage_info, dial)

    print(report(now, args.hours, dial, q, holds, owner_prs, needs_owner, run_asks, p))
    return 0


if __name__ == '__main__':
    sys.exit(main())
