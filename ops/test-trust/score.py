"""Score every lane test failure since a date from the lane report comments (Part of #2376).

Usage, from the repo root (git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*' first, so PR heads resolve):
    gh api --paginate 'repos/Spoken-Margins/spoken-margins-native/issues/comments?since=2026-10-06T00:00:00Z&per_page=100' \
      --jq '.[] | select(.body|startswith("Lane report")) | {u:.html_url, at:.created_at, a:.user.login, b:.body}' \
      > artifacts/test-trust/lane-comments.jsonl
    python3 ops/test-trust/score.py . artifacts/test-trust 2026-10-07

Input: lane-comments.jsonl (one GitHub comment per line: u, at, a, assoc, b), only bot-authored reports used.
Output: episodes.jsonl (one per failing test per PR failure run, with its class) and per-test.tsv.

Classes, per failing test at head H on PR P:
- mutation: the change between fail and pass reverts a deliberate MUTATION / PROOF ONLY commit
- catch-candidate: a later run on P passed the test and P's own commits H..pass changed product code
- wrong-test: ... changed only test files
- rerun-pass: the same head (or no own change) passed later, same next
- next-moved: the same head passed later, next moved in between
- trunk-red: the lane re-ran the test on plain next and it failed there too (collapsed per test per next sha)
- unresolved: no later run on P passed it (PR closed, superseded, merged by other means)
Runner faults (hangs, budgets, missing tests, no slot, build-before-boot) are counted per report, not per test.
"""
import json, re, subprocess, sys, collections, pathlib

REPO = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
HERE = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else 'artifacts/test-trust')
SINCE = sys.argv[3] if len(sys.argv) > 3 else '2026-10-07'
sys.path.insert(0, str(REPO / 'scripts'))
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
NEXT_RED = re.compile(r're-run on plain next ([0-9a-f]{7,}): (.*)')


def reports():
    for line in (HERE / 'lane-comments.jsonl').open():
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


def main():
    rs = sorted(reports(), key=lambda r: r['at'])
    rs = [r for r in rs if r['at'] >= SINCE]
    by_key = collections.defaultdict(list)
    for r in rs:
        by_key[r['key']].append(r)
    episodes, faults, seen_red = [], collections.Counter(), set()
    kinds = {}
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
                        k = (r['head'], closer['head'])
                        if k not in kinds:
                            kinds[k] = lane_ledger.classify(REPO, r['head'], closer['head'])
                        c = kinds[k]
                        if c == 'catch' and MUTATION.search(subprocess.run(
                                ['git', '-C', str(REPO), 'log', '--format=%s', f"{r['head']}~1..{closer['head']}"],
                                capture_output=True, text=True).stdout):
                            c = 'mutation'
                        ep['class'] = {'catch': 'catch-candidate', 'flake': (
                            'next-moved' if r['next'] != closer['next'] else 'rerun-pass')}.get(c, c)
                # a failing run with the same failure set on the same head twice is one episode
                if any(e['test'] == t and e['key'] == key and e['from'] == r['head'] and e.get('class') == ep['class']
                       for e in episodes):
                    continue
                episodes.append(ep)
    with (HERE / 'episodes.jsonl').open('w') as f:
        for e in episodes:
            f.write(json.dumps(e) + '\n')
    per = collections.defaultdict(collections.Counter)
    for e in episodes:
        per[e['test']][e['class']] += 1
    cols = ['catch-candidate', 'mutation', 'wrong-test', 'rerun-pass', 'next-moved', 'trunk-red', 'other', 'unresolved']
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
    print('fault reports by tier', dict(faults))
    print('runs with a named test failure', dict(first))


main()
