# Test trust score

`score.py` scores every lane test failure from the lane report comments (#2376): for each failing test on a PR, it
finds the next run on that PR that ran and passed the test, and classifies the PR's own commits in between with
`scripts/lane_ledger.classify`. Usage is in the script's docstring; output (`episodes.jsonl`, `per-test.tsv`) goes to
the git-ignored `artifacts/test-trust/`.

What it can't tell (Opus review, 2026-10-21):
- `catch-candidate` means product code changed, not that the change fixed what the test checks. Sample them by hand.
- `next-moved` mixes noise with a test broken on the trunk and fixed there.
- Environment faults (a wedged audio service) read as test failures unless the test probes for them.

The lane ledger (`scripts/lane_ledger.py`, `test-catches.jsonl`) does the same classification live from 10-17 on;
this script covers the earlier lane reports and tags deliberate MUTATION / PROOF ONLY runs, which the ledger counts
as catches.
