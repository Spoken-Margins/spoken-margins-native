"""Score every lane test failure since a date from the lane report comments (Part of #2376).

Usage, from the repo root (git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*' first, so PR heads resolve):
    gh api --paginate 'repos/Spoken-Margins/spoken-margins-native/issues/comments?since=2026-10-06T00:00:00Z&per_page=100' \
      --jq '.[] | select(.body|startswith("Lane report")) | {u:.html_url, at:.created_at, a:.user.login, b:.body}' \
      > artifacts/test-trust/lane-comments.jsonl
    python3 ops/test-trust/score.py . artifacts/test-trust 2026-10-07

Input: lane-comments.jsonl (one GitHub comment per line: u, at, a, assoc, b), only bot-authored reports used.
Optional input: trunk-red-issues.jsonl, one `{"test": ..., "issue": N, "from": "2026-11-02T00:00:00Z", "to": "..."}` per line (UTC, `Z` form; leave `to` out while the fix is unmerged), for
each `regression` issue that names a test red on `main` (from: when the breaking PR merged; to: when the fix merged).
Output: episodes.jsonl (one per failing test per PR failure run, with its class) and per-test.tsv.

Classes, per failing test at head H on PR P:
- mutation: the change between fail and pass reverts a deliberate MUTATION / PROOF ONLY commit
- catch-candidate: a later run on P passed the test and P's own commits after the failing run (never a merge from
  `next`/`main`, #3900) changed product code and no test file (product-only fix)
- mixed-fix: ... changed product code and test files together; reported apart, not counted as a catch
- wrong-test: ... changed only test files
- rerun-pass: the same head (or no own change) passed later, same next
- next-moved: the same head passed later, next moved in between
  (but if two or more different PRs failed the same test with no change of their own inside a trunk-red-issues.jsonl
  window for that test, the issue names `main` as red, and those episodes are trunk-red, #3702)
- trunk-red: the lane re-ran the test on plain next and it failed there too (collapsed per test per next sha)
- unresolved: no later run on P passed it (PR closed, superseded, merged by other means)
Runner faults (hangs, budgets, missing tests, no slot, build-before-boot) are counted per report, not per test.
"""
import json, re, subprocess, sys, collections, pathlib

REPO = pathlib.Path('.')
HERE = pathlib.Path('artifacts/test-trust')
SINCE = '2026-10-07'
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'scripts'))
import lane_ledger  # noqa: E402

NAME = r'[A-Za-z_][\w]*Tests?(?:/[\w]+)?/test\w+(?![\w…])|test_[\w]+\.[\w]+Tests?\.test\w+'
FAILED_PATTERNS = [
    re.compile(r'Failed: (' + NAME + ')'),
    re.compile(r'(' + NAME + r') — expected: passes\. observed: failed'),
    re.compile(r'^\s*(?:FAIL|ERROR): (test\w+) \(([\w.]+)\)'),
]
FAULT = re.compile(r'exit 124|ran past its|ran out of its own|Missing \d+ tests|no host-test slot|'
                   r'Build before simulator boot: Process exit|Not in any app test plan|printed no test output|lane error', re.I)
MUTATION = re.compile(r'MUTATION|PROOF ONLY|intended[- ]failure|intended to fail', re.I)
THREAD_MOVE = re.compile(r'Task\.detached|DispatchQueue|@MainActor|nonisolated|\bMainActor\b|\bqos:|\.background\b|'
                         r'priority: \.(?:low|utility|background)|OperationQueue|\bactor\s+\w+', re.I)
NEXT_RED = re.compile(r're-run on plain next ([0-9a-f]{7,}): (.*)')


def reports():
    for line in (HERE / 'lane-comments.jsonl').read_text().splitlines():
        c = json.loads(line)
        if c['a'] != 'github-actions[bot]' or not c['b'].startswith('Lane report'):
            continue
        head = c['b'].split('\n', 1)[0]
        m = re.match(r'Lane report (pr(\d+)|next|main)\S* — (PASS|FAIL|INCONCLUSIVE)', head)
        if not m:
            continue
        req = re.search(r'<!-- lane-request: (\{.*?\}) -->', c['b'])
        req = json.loads(req.group(1)) if req else {}
        key = f'pr:{m.group(2)}' if m.group(2) else 'trunk'
        failed = set()
        for ln in c['b'].split('\n'):
            for p in FAILED_PATTERNS:
                for g in p.finditer(ln):
                    failed.add(g.group(1) if p.groups == 1 else f'{g.group(2)}.{g.group(1)}')
        red_on_next = {}
        for g in NEXT_RED.finditer(c['b']):
            for t, why in re.findall(r'(' + NAME + r') \(([^)]*)\)', g.group(2)):
                red_on_next[t] = (g.group(1), why)
        tier = req.get('tier', '')
        steps = re.search(r'^ran: (.*)$', c['b'], re.M)
        yield {
            'url': c['u'], 'at': c['at'], 'key': key, 'verdict': m.group(3), 'head': req.get('commit', ''),
            'next': req.get('next', ''), 'tier': tier, 'tests_req': req.get('tests', []),
            'host': bool(re.search(r'host tests \(--plan fast\)', c['b'])),
            'host_passed': bool(re.search(r'host tests \(--plan fast\): passed', c['b'])) and not any(
                not ('/' in f and f.split('/')[0].startswith('SpokenMarginsApp')) for f in failed),
            't3': bool(re.search(r'app plan|adapters plan', c['b'])),
            'failed': sorted(failed), 'red_on_next': red_on_next, 'fault': m.group(3) != 'PASS' and bool(FAULT.search(c['b'])),
            'ratchet_fail': 'hot-file ratchet: failed' in c['b'],
            'ran': steps.group(1) if steps else '',
        }


def is_app_test(t):
    return t.startswith('SpokenMarginsApp')


def ran_test(r, t):
    """Did report r run test t and not fail it?"""
    if t in r['failed']:
        return False
    if not is_app_test(t):
        return r['host'] and r['verdict'] != 'INCONCLUSIVE' and not r['fault']
    if not r['t3'] or r['fault']:
        return False
    cls = t.split('/')[1]
    for q in r['tests_req']:
        q = q.replace('SpokenMarginsAppTests/', '')
        if q == cls or q == '/'.join(t.split('/')[1:]):
            return True
    return False


def _git(repo, *args, stdin=None):
    r = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, input=stdin, timeout=120)
    return r.stdout if r.returncode == 0 else None


def _own_commits(repo, head, nxt):
    """The PR's own commits at <head>: reachable from it, not from the `next` it was tested against, no merges.
    None when git can't say (an unknown sha, no `next` recorded)."""
    if not head or not nxt:
        return None
    out = _git(repo, 'rev-list', '--no-merges', head, '^' + nxt)
    return None if out is None else out.split()


def _patch_ids(repo, shas):
    """sha -> stable patch id, so a rebased copy of a commit is the same commit."""
    ids = {}
    for sha in shas:
        shown = _git(repo, 'show', '--format=', '-p', sha)
        out = _git(repo, 'patch-id', '--stable', stdin=shown or '')
        ids[sha] = out.split()[0] if out and out.split() else sha
    return ids


def own_change(repo, fail_head, fail_next, pass_head, pass_next):
    """(files, shas) of the PR's own commits that appear after the failing run: the commits own to <pass_head> whose
    patch is not among those own to <fail_head>. Merges from `next` and the commits `next` brought in are never
    counted (#3900). None when either side's own commits can't be listed."""
    after, before = _own_commits(repo, pass_head, pass_next), _own_commits(repo, fail_head, fail_next)
    if after is None or before is None:
        return None
    seen = set(_patch_ids(repo, before).values())
    new = [sha for sha, pid in _patch_ids(repo, after).items() if pid not in seen]
    files = set()
    for sha in new:
        files.update(f for f in (_git(repo, 'show', '--format=', '--name-only', sha) or '').split('\n') if f)
    return sorted(files), new


def fix_kind(files):
    """product-only, mixed, test-only, or other, for a list of changed files."""
    prod = [f for f in files if f.split('/')[0] in lane_ledger.PRODUCT_ROOTS and not lane_ledger._is_test_path(f)]
    tests = [f for f in files if lane_ledger._is_test_path(f)]
    if prod and tests:
        return 'mixed'
    if prod:
        return 'product-only'
    if files and len(tests) == len(files):
        return 'test-only'
    return 'other'


def pr_kind(repo, head, nxt):
    """thread-move when the PR's own product diff adds threading constructs (moves work between threads), else other."""
    if not _own_commits(repo, head, nxt):
        return 'unknown'
    diff = _git(repo, 'log', '--no-merges', '-p', '--format=', '-U0', head, '^' + nxt, '--', *lane_ledger.PRODUCT_ROOTS)
    added = [x for x in (diff or '').split('\n') if x.startswith('+') and not x.startswith('+++')]
    return 'thread-move' if any(THREAD_MOVE.search(x) for x in added) else 'other'


def classify_change(repo, fail_head, fail_next, pass_head, pass_next):
    """(class, fix kind) for the change between a failing run and the passing one, judged by the PR's own commits.
    class is catch (product-only), mixed, wrong-test, flake (nothing of its own changed) or other. When the own
    commits can't be listed, falls back to lane_ledger.classify, which skips merges but compares trees after a rebase."""
    changed = own_change(repo, fail_head, fail_next, pass_head, pass_next)
    if changed is None:
        return lane_ledger.classify(repo, fail_head, pass_head), 'unscoped'
    files, shas = changed
    if not shas:
        return 'flake', 'none'
    kind = fix_kind(files)
    return {'product-only': 'catch', 'mixed': 'mixed', 'test-only': 'wrong-test'}.get(kind, 'other'), kind


def trunk_red_from_issues(episodes, windows):
    """Re-class `next-moved` episodes as `trunk-red` where a regression issue names `main` red for the test (#3702).

    A window is {test, issue, from, to}. The episodes of that test inside it that are `next-moved` (no PR-side change)
    are trunk breaks, not noise, once two or more different PRs hit it: one PR alone could still be a moved next.
    """
    for w in windows:
        # times are the comment's own UTC `...Z` strings; a fix not merged yet leaves `to` out, so the window is open
        hit = [e for e in episodes if e['test'] == w['test'] and e.get('class') == 'next-moved'
               and e['key'].startswith('pr:') and w['from'] <= e['at'] <= w.get('to', '9999')]
        if len({e['key'] for e in hit}) >= 2:
            for e in hit:
                e['class'], e['trunk_issue'] = 'trunk-red', w['issue']
    return episodes


def read_windows():
    path = HERE / 'trunk-red-issues.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def main(argv):
    global REPO, HERE, SINCE
    REPO = pathlib.Path(argv[1] if len(argv) > 1 else '.')
    HERE = pathlib.Path(argv[2] if len(argv) > 2 else 'artifacts/test-trust')
    SINCE = argv[3] if len(argv) > 3 else '2026-10-07'
    rs = sorted(reports(), key=lambda r: r['at'])
    rs = [r for r in rs if r['at'] >= SINCE]
    by_key = collections.defaultdict(list)
    for r in rs:
        by_key[r['key']].append(r)
    episodes, faults, seen_red = [], collections.Counter(), set()
    kinds, pr_kinds = {}, {}
    for key, runs in by_key.items():
        for i, r in enumerate(runs):
            if r['fault']:
                faults[r['tier'] or 'auto'] += 1
            for t in r['failed']:
                ep = {'test': t, 'key': key, 'at': r['at'], 'url': r['url'], 'from': r['head'], 'next': r['next']}
                if t in r['red_on_next'] and 'passed' not in r['red_on_next'][t][1]:
                    sig = (t, r['red_on_next'][t][0])
                    if sig in seen_red:
                        continue
                    seen_red.add(sig)
                    ep['class'] = 'trunk-red'
                    episodes.append(ep)
                    continue
                if key == 'trunk':
                    sig = (t, r['head'])
                    if sig in seen_red:
                        continue
                    seen_red.add(sig)
                closer = next((s for s in runs[i + 1:] if ran_test(s, t)), None)
                if closer is None:
                    ep['class'] = 'unresolved'
                else:
                    ep['to'], ep['to_url'] = closer['head'], closer['url']
                    if r['head'] == closer['head'] or not r['head']:
                        ep['class'] = 'next-moved' if r['next'] != closer['next'] else 'rerun-pass'
                    else:
                        k = (r['head'], r['next'], closer['head'], closer['next'])
                        if k not in kinds:
                            kinds[k] = classify_change(REPO, *k)
                        c, ep['fix'] = kinds[k]
                        if c == 'catch' and MUTATION.search(subprocess.run(
                                ['git', '-C', str(REPO), 'log', '--format=%s', f"{r['head']}~1..{closer['head']}"],
                                capture_output=True, text=True).stdout):
                            c = 'mutation'
                        ep['class'] = {'catch': 'catch-candidate', 'mixed': 'mixed-fix', 'flake': (
                            'next-moved' if r['next'] != closer['next'] else 'rerun-pass')}.get(c, c)
                        if ep['class'] in ('catch-candidate', 'mixed-fix'):
                            pk = (closer['head'], closer['next'])
                            if pk not in pr_kinds:
                                pr_kinds[pk] = pr_kind(REPO, *pk)
                            ep['pr_kind'] = pr_kinds[pk]
                # a failing run with the same failure set on the same head twice is one episode
                if any(e['test'] == t and e['key'] == key and e['from'] == r['head'] and e.get('class') == ep['class']
                       for e in episodes):
                    continue
                episodes.append(ep)
    trunk_red_from_issues(episodes, read_windows())
    with (HERE / 'episodes.jsonl').open('w') as f:
        for e in episodes:
            f.write(json.dumps(e) + '\n')
    per = collections.defaultdict(collections.Counter)
    for e in episodes:
        per[e['test']][e['class']] += 1
    cols = ['catch-candidate', 'mixed-fix', 'mutation', 'wrong-test', 'rerun-pass', 'next-moved', 'trunk-red', 'other', 'unresolved']
    with (HERE / 'per-test.tsv').open('w') as f:
        f.write('test\t' + '\t'.join(cols) + '\ttotal\n')
        for t, c in sorted(per.items(), key=lambda kv: -sum(kv[1].values())):
            f.write(t + '\t' + '\t'.join(str(c[k]) for k in cols) + f'\t{sum(c.values())}\n')
    # first-try failure rate per run of the host step and T3 step, excluding runner faults
    first = collections.Counter()
    for r in rs:
        if r['key'] == 'trunk' or r['fault']:
            continue
        kind = 'T3' if r['t3'] else ('host' if r['host'] else None)
        if kind:
            first[kind, 'runs'] += 1
            first[kind, 'test-fail'] += bool(r['failed'])
    print('reports', len(rs), 'episodes', len(episodes), 'tests', len(per))
    print('classes', collections.Counter(e['class'] for e in episodes))
    cand = [e for e in episodes if e['class'] in ('catch-candidate', 'mixed-fix', 'wrong-test')]
    print('fixes after a failing run (product-only / mixed / test-only):',
          sum(e['class'] == 'catch-candidate' for e in cand), sum(e['class'] == 'mixed-fix' for e in cand),
          sum(e['class'] == 'wrong-test' for e in cand))
    by_kind = collections.Counter(e.get('pr_kind', 'unknown') for e in episodes if e['class'] == 'catch-candidate')
    print('product-only catches by kind of PR', dict(by_kind))
    print('fault reports by tier', dict(faults))
    print('runs with a named test failure', dict(first))


if __name__ == '__main__':
    main(sys.argv)
