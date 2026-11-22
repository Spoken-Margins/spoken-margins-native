"""The hosted app build's path filters match what project.yml builds and bundles (#2596)."""
import fnmatch
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / '.github/workflows/hosted-app-macos.yml').read_text()
PROJECT = (ROOT / 'project.yml').read_text()


def trigger_paths(event):
    block = re.search(r'^  %s:\n(.*?)(?=^  \w)' % event, WORKFLOW, re.S | re.M).group(1)
    inline = re.search(r'^    paths: \[(.*)\]$', block, re.M)
    if inline:
        return [item.strip().strip('\'"') for item in inline.group(1).split(',')]
    listing = re.search(r'^    paths:\n((?:      - .*\n)+)', block, re.M).group(1)
    return [re.sub(r'^      - |[\'"]', '', line).strip() for line in listing.splitlines()]


def glob_match(pattern, path):
    regex = re.escape(pattern).replace(r'\*\*', '\x00').replace(r'\*', '[^/]*').replace('\x00', '.*')
    return re.fullmatch(regex, path) is not None


def built(path, paths):
    hit = False
    for pattern in paths:
        negated = pattern.startswith('!')
        if glob_match(pattern.lstrip('!'), path):
            hit = not negated
    return hit


def project_sources():
    return re.findall(r'^      - path: (\S+)$', PROJECT, re.M)


class HostedAppPaths(unittest.TestCase):
    def test_every_project_source_triggers_a_build(self):
        paths = trigger_paths('push')
        sources = project_sources()
        self.assertIn('Contracts/fixtures/items', sources)
        for source in sources:
            probe = source if '.' in Path(source).name else source + '/probe.file'
            self.assertTrue(built(probe, paths), f'{source} is bundled by project.yml but does not trigger the build')

    def test_it_no_longer_builds_pull_requests(self):
        # Owner, 2026-11-18: no per-PR app build (0 catches in 132 per-PR builds in October). Main's push runs stay, to keep the warm compile cache, and so do hand-started runs.
        self.assertNotRegex(WORKFLOW, r'(?m)^  pull_request:')
        self.assertRegex(WORKFLOW, r'(?m)^  push:\n    branches: \[main\]')
        self.assertRegex(WORKFLOW, r'(?m)^  workflow_dispatch:')

    def test_sessionkit_tests_and_tools_are_skipped(self):
        paths = trigger_paths('push')
        self.assertFalse(built('Packages/SessionKit/Tests/SessionKitTests/Foo.swift', paths))
        self.assertFalse(built('Packages/SessionKitTools/Sources/x.swift', paths))
        self.assertTrue(built('Packages/SessionKit/Sources/SessionKit/Foo.swift', paths))

    def test_markdown_bundled_in_the_app_still_triggers(self):
        self.assertTrue(built('App/SpokenMarginsApp/Resources/Legal/terms.md', trigger_paths('push')))

    def test_sessionkit_tools_is_not_part_of_the_app(self):
        self.assertNotIn('SessionKitTools', PROJECT)
        self.assertNotIn('SessionKitTools', (ROOT / 'Packages/SessionKit/Package.swift').read_text())


if __name__ == '__main__':
    unittest.main()
