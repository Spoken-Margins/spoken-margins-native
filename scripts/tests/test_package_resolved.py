"""SessionKit's committed Package.resolved must be the Mac's, not the one SwiftPM writes on Linux (#1773).

On Linux, Package.swift swaps in swift-crypto and drops the Apple-only targets, so `swift build` or
`swift test` there rewrites Packages/SessionKit/Package.resolved with different pins. #1758 committed that
copy; on the Mac the lane's `swift build` rewrote it back, the run's inputs no longer matched the hash taken
at its start, and the host-test check failed with "Inputs changed during fast verification" twice on one head.
scripts/run-sessionkit-linux-tests.sh restores the file; this test fails the branch up front if it was committed.
"""
import json
import re
import unittest
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[2] / 'Packages' / 'SessionKit'
DEPENDENCY = re.compile(r'\.package\(\s*url:\s*"([^"]+)"')


def identity(url):
    return url.rstrip('/').rsplit('/', 1)[-1].removesuffix('.git').lower()


def mac_dependencies(manifest):
    """Package identities Package.swift declares for the Mac, before the Linux block rewrites the list."""
    return {identity(url) for url in DEPENDENCY.findall(manifest.split('#if os(Linux)')[0])}


class PackageResolvedTests(unittest.TestCase):
    def test_the_committed_pins_are_the_ones_the_mac_resolves(self):
        declared = mac_dependencies((PACKAGE / 'Package.swift').read_text())
        pinned = {pin['identity'] for pin in json.loads((PACKAGE / 'Package.resolved').read_text())['pins']}
        self.assertTrue(declared, 'Package.swift declares no dependency this test can read')
        self.assertEqual(
            pinned, declared,
            'Packages/SessionKit/Package.resolved does not pin what Package.swift depends on on the Mac. A Linux '
            '`swift test` rewrites it (swift-crypto in, the Apple packages out); restore it with '
            '`git checkout origin/next -- Packages/SessionKit/Package.resolved` and use '
            'scripts/run-sessionkit-linux-tests.sh, which restores it for you.')


if __name__ == '__main__':
    unittest.main()
