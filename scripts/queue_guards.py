#!/usr/bin/env python3
"""The repository's rule tests, run first in each merge group so a broken rule never takes a hosted Mac.

hosted-portable.yml's `guards` job runs this at the start of every merge group, and the Mac jobs (`sessionkit`,
`app-compile`, `mac-rest`) wait for it and are skipped when it fails. From 2026-11-20 to 2026-11-24, 157 merge groups
failed first in `hosted fast: portable` while their Mac jobs ran beside it, 1,569 hosted-Mac minutes. Most were rules
that read the whole tree and break only once a PR meets newer main: the wall-clock ceiling allowlist, the mini player
keep-out, the outer tap frame. The modules here fail first in 117 of those 157 groups (982 of the minutes); the rest
were Swift guards in SessionKitCoreTests, which need a Linux build that does not fit a two-minute job.

GUARDS is the Swift-source scans (scripts/swift_scan_tests.py SCANS, #5220, which test_swift_scan_tests keeps
complete) plus REPO_RULES, the rule tests about the repository's own layout that failed in the queue and that no
scan list holds. Every module here also runs in `portable`'s runner-tests, which stays the required check: a
failure here skips the Mac jobs (a skipped required check counts as passed), and `portable` failing on the same test
is what fails the group. test_fast_portable checks that no module here is left out of `portable` or moved to the slow
tier.

  python3 scripts/queue_guards.py          run them in one process
  python3 scripts/queue_guards.py --list   print the modules
"""
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
TESTS = SCRIPTS / 'tests'
sys.path.insert(0, str(SCRIPTS))

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


def suite():
    sys.path.insert(0, str(TESTS))
    return unittest.defaultTestLoader.loadTestsFromNames(GUARDS)


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
    result = unittest.TextTestRunner().run(suite())
    return 0 if result.wasSuccessful() and result.testsRun else 1


if __name__ == '__main__':
    sys.exit(main())
