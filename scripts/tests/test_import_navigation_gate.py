"""An import never moves the listener while a Margin is being recorded or written (the audits on PR #3298, #3291).

A packet import can finish seconds after it started, so a check when it starts is not enough: the listener may begin a
Margin meanwhile. The coordinator has one place that turns an import into navigation, `presentImportedItem`, which
holds the opening while `navigationIsLocked`; `openDeferredItemIfReady` is the only other caller. These tests fail when
a new call to `showImportedItem` appears elsewhere, because it would skip the lock.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'App' / 'SpokenMarginsApp' / 'Sources' / 'SpokenMarginsApp'
COORDINATOR = SOURCES / 'SpokenMarginsPackageImportCoordinator.swift'
CALL = re.compile(r'environment\.showImportedItem\(')
FUNC = re.compile(r'^\s*(?:@\w+\s+)*(?:private\s+)?func (\w+)')


def calls_by_function(text):
    found, current = {}, None
    for line in text.splitlines():
        match = FUNC.match(line)
        if match:
            current = match.group(1)
        if CALL.search(line):
            found.setdefault(current, 0)
            found[current] += 1
    return found


class ImportNavigationGateTests(unittest.TestCase):
    def test_only_the_gate_and_its_release_open_an_imported_item(self):
        self.assertEqual(calls_by_function(COORDINATOR.read_text()),
                         {'presentImportedItem': 1, 'openDeferredItemIfReady': 1})

    def test_nothing_else_in_the_app_calls_the_environment_closure(self):
        for path in SOURCES.glob('*.swift'):
            if path == COORDINATOR:
                continue
            self.assertIsNone(CALL.search(path.read_text()), f'{path.name} opens an imported item past the lock')

    def test_the_gate_checks_the_lock_before_it_navigates(self):
        text = COORDINATOR.read_text()
        body = text[text.index('func presentImportedItem'):text.index('func openDeferredItemIfReady')]
        self.assertLess(body.index('navigationIsLocked()'), body.index('showImportedItem'))


if __name__ == '__main__':
    unittest.main()
