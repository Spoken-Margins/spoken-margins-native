#!/usr/bin/env python3
"""The repository's rule tests, run first in each merge group so a broken rule never takes a hosted Mac.

hosted-portable.yml's `guards` job runs this at the start of every merge group, the Mac jobs (`sessionkit`,
`app-compile`, `mac-rest`) wait for it, and a failure here cancels the run. From 2026-11-20 to 2026-11-24, 157 merge groups
failed first in `hosted fast: portable` while their Mac jobs ran beside it, 1,569 hosted-Mac minutes. Most were rules
that read the whole tree and break only once a PR meets newer main: the wall-clock ceiling allowlist, the mini player
keep-out, the outer tap frame. The modules here fail first in 117 of those 157 groups (982 of the minutes); the rest
were Swift guards in SessionKitCoreTests, which need a Linux build that does not fit a two-minute job.

GUARDS is the Swift-source scans (scripts/swift_scan_tests.py SCANS, #5220, which test_swift_scan_tests keeps
complete) plus REPO_RULES, the rule tests about the repository's own layout that failed in the queue and that no
scan list holds. Every module here also runs in `portable`'s runner-tests, which stays the required check, and
test_fast_portable checks that no module here is left out of `portable` or moved to the slow tier. Each module runs
in its own process through parallel_unittest.py, as `portable` runs it, so a test that leans on state an earlier
module left can't fail here and pass there.

  python3 scripts/queue_guards.py          run them, one process per module
  python3 scripts/queue_guards.py --list   print the modules
"""
import json
import os
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import parallel_unittest  # noqa: E402

try:  # #5220's list; before it lands on the trunk only REPO_RULES run
    import swift_scan_tests
    SCANS = tuple(swift_scan_tests.SCANS)
except ImportError:  # pragma: no cover
    SCANS = ()

# Rule tests on the repository's layout, by groups they failed first in (2026-11-20 to 11-24): test_mac_checks_scope
# 18 (no Mac test reads Web/ by path; every workflow with a job off ubuntu is a Mac workflow), test_sessionkit_pass 11
# (package tests reach App/ and research/ files only through the helper).
REPO_RULES = ('test_mac_checks_scope', 'test_sessionkit_pass')
GUARDS = SCANS + tuple(module for module in REPO_RULES if module not in SCANS)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ['--list']:
        print('\n'.join(GUARDS))
        return 0
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    if not SCANS:
        print('scripts/swift_scan_tests.py is not in this tree: running the repository rules only.', flush=True)
    weights = (json.loads(parallel_unittest.WEIGHTS.read_text())['seconds']
               if parallel_unittest.WEIGHTS.exists() else {})
    jobs = min(parallel_unittest.DEFAULT_JOBS, os.cpu_count() or 1)
    results = parallel_unittest.run_all(parallel_unittest.order(GUARDS, weights), jobs, cwd=str(SCRIPTS.parent))
    failed = sorted(module for module in GUARDS if not results.get(module, {}).get('ok'))
    ran = sum(value.get('ran', 0) for value in results.values())
    print(f'Ran {ran} tests in {len(results)} modules', flush=True)
    if failed or not ran:
        print(f'FAILED (modules: {", ".join(failed) or "none ran a test"})', flush=True)
        return 1
    print('OK', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
