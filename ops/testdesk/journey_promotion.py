#!/usr/bin/env python3
"""Which scripted journeys earned `gating`, and which lost it (#1901).

TestPlans/scripted-journeys.json lists every scripted journey as `gating` (can turn the integration run
red) or `probation` (reported only). The rule in docs/workstreams/test-lane.md: a probation script moves to
gating after the Test Desk has seen it pass twice, and a gating script goes back after two bad runs.
Nothing counted those passes, so nothing ever moved. The integration script now keeps a streak per script in
its state file (`journeys` in state.json) and names the scripts that are due in its report. The move itself is
a PR into next, made with this file:

    python3 ops/testdesk/journey_promotion.py --state ~/SpokenMarginsOps/integration-run/state.json          # list
    python3 ops/testdesk/journey_promotion.py --state ... --apply    # rewrite TestPlans/scripted-journeys.json

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

LISTING = Path(__file__).resolve().parents[2] / 'TestPlans' / 'scripted-journeys.json'
PROMOTE_AFTER = 2  # consecutive passing runs on probation
DEMOTE_AFTER = 2   # consecutive bad runs on gating
BAD = ('failed', 'missing')


def update(streaks: dict, results: dict) -> dict:
    """Fold one run's per-script outcomes (`passed`, `failed`, `missing`, `skipped`, `not_run`) into the streaks.

    A pass extends the pass streak and clears the bad one; failed or missing does the reverse. A script that was
    skipped or not run says nothing either way, so its streaks stay as they were. Scripts no longer listed are dropped."""
    fresh = {}
    for test, status in results.items():
        before = streaks.get(test, {})
        passes, bad = before.get('passes', 0), before.get('bad', 0)
        if status == 'passed':
            passes, bad = passes + 1, 0
        elif status in BAD:
            passes, bad = 0, bad + 1
        fresh[test] = {'passes': passes, 'bad': bad}
    return fresh


JOURNEY_LINE = re.compile(r'^\s*scripted journeys \(only those on gating are verdict input\): (.+)$', re.M)
JOURNEY_RESULT = re.compile(r'(\S+) (passed|failed|missing|skipped|not_run)(?:,|$)')


def results_from_report(body: str, listing: dict) -> dict:
    """The per-script outcomes one integration report on #184 lists, as {test selector: status}.

    The report names each script by its last path part (`J1ListenToAnArticleJourneyUITests`, or the method of a
    single test), so they are matched back to the selectors in `listing`. A name the listing no longer has, or that two listed scripts share, is ignored."""
    match = JOURNEY_LINE.search(body or '')
    if not match:
        return {}
    selectors, clashing = {}, set()
    for status in ('gating', 'probation'):
        for entry in listing.get(status, []):
            selector = entry['test'].removesuffix('()')
            name = selector.rsplit('/', 1)[-1]
            if name in selectors and selectors[name] != selector:
                clashing.add(name)  # the report can't tell these apart, so neither is credited
            selectors[name] = selector
    selectors = {name: selector for name, selector in selectors.items() if name not in clashing}
    found = {}
    for chunk in match.group(1).split(', '):
        pair = JOURNEY_RESULT.fullmatch(chunk.strip())
        if pair and pair.group(1) in selectors:
            found[selectors[pair.group(1)]] = pair.group(2)
    return found


def streaks_from_reports(bodies: list, listing: dict) -> dict:
    """Streaks folded from the journey lines of past reports, oldest first, so a run that keeps no state of its own
    (the hosted integration run, #2894) still counts consecutive passes. Whoever ran a report, it counts."""
    streaks: dict = {}
    for body in bodies:
        results = results_from_report(body, listing)
        if results:
            streaks = update(streaks, results)
    return streaks


def due(listing: dict, streaks: dict) -> dict:
    """The scripts to move: {'promote': [...], 'demote': [...]} as test selectors."""
    def tests(status):
        return [entry['test'].removesuffix('()') for entry in listing.get(status, [])]
    return {
        'promote': [t for t in tests('probation') if streaks.get(t, {}).get('passes', 0) >= PROMOTE_AFTER],
        'demote': [t for t in tests('gating') if streaks.get(t, {}).get('bad', 0) >= DEMOTE_AFTER],
    }


def apply(listing: dict, moves: dict) -> dict:
    """The listing with the due scripts moved, entries (journey names included) kept as they were."""
    result = {**listing, 'gating': list(listing.get('gating', [])), 'probation': list(listing.get('probation', []))}
    for source, target, key in (('probation', 'gating', 'promote'), ('gating', 'probation', 'demote')):
        moving = set(moves[key])
        result[target] += [e for e in result[source] if e['test'].removesuffix('()') in moving]
        result[source] = [e for e in result[source] if e['test'].removesuffix('()') not in moving]
    return result


def report_line(moves: dict) -> str | None:
    """The line the integration report carries, or None when nothing is due."""
    parts = []
    for key, words in (('promote', 'passed twice running, move to gating'),
                       ('demote', 'bad twice running, move back to probation')):
        if moves[key]:
            parts.append(f"{', '.join(t.rsplit('/', 1)[-1] for t in moves[key])} {words}")
    if not parts:
        return None
    return ('journeys due to move: ' + '; '.join(parts)
            + ' (python3 ops/testdesk/journey_promotion.py --apply, then a PR into next)')


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--state', type=Path, required=True, help="the integration script's state.json")
    ap.add_argument('--listing', type=Path, default=LISTING)
    ap.add_argument('--apply', action='store_true', help='rewrite the listing instead of only printing')
    args = ap.parse_args(argv)
    listing = json.loads(args.listing.read_text())
    state = json.loads(args.state.read_text()) if args.state.exists() else {}
    moves = due(listing, state.get('journeys', {}))
    print(report_line(moves) or 'No scripted journey is due to move.')
    if args.apply and (moves['promote'] or moves['demote']):
        args.listing.write_text(json.dumps(apply(listing, moves), indent=2) + '\n')
        print(f'rewrote {args.listing}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
