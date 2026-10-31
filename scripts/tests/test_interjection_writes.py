"""A saved Margin is changed only through SQLiteSessionStore.updateInterjection (#2509).

Loading a Margin and saving it back whole, outside one transaction, lets another thread's save of the same Margin
(the anchor-evidence edits run off the main thread) land in between and be erased by the stale copy. Two audits of
#3080 found that race in five places; `updateInterjection(id:sessionId:)` closes it in one transaction. This test
fails when code outside the list below calls `saveInterjection(`, so a new caller has to either use the helper or be
listed here with the reason it only saves a Margin it just made.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# file (relative to the repo root) -> why a direct save is safe there
ALLOWED = {
    'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel+UITestingSeeds.swift': 'seeds a new Margin for UI tests',
    'Packages/SessionKit/Sources/SessionKit/Protocols.swift': 'the protocol declarations',
    'Packages/SessionKit/Sources/SessionKit/InMemoryRepository.swift': 'the in-memory repository (tests)',
    'Packages/SessionKit/Sources/SessionKit/SessionEngine.swift': 'new Margins; updates go through updateInterjection, in one transaction',
    'Packages/SessionKit/Sources/SessionKit/RecordingDraftJournal.swift': 'saves the Margin it just made from a draft',
    'Packages/SessionKit/Sources/SessionKit/LiveSessionMarginPlacer.swift': 'saves a Margin right after it creates it, before any capture can finish',
    'Packages/SessionKit/Sources/SessionKitSharing/SharingFoundation.swift': 'imports new Margins; recordExport runs in one transaction',
    'Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift': 'the store itself',
    'Packages/SessionKit/Sources/SessionKitPersistence/InterjectionUpdate.swift': 'the helper',
}

CALL = re.compile(r'\bsaveInterjection\(')


class InterjectionWritesTests(unittest.TestCase):
    def test_margins_are_saved_only_where_listed(self):
        found = {}
        for base in ('App', 'Packages/SessionKit/Sources'):
            for path in (ROOT / base).rglob('*.swift'):
                rel = path.relative_to(ROOT).as_posix()
                if any(part.endswith('Tests') for part in path.relative_to(ROOT).parts):
                    continue
                if CALL.search(path.read_text(encoding='utf-8', errors='replace')):
                    found[rel] = True
        unexpected = sorted(set(found) - set(ALLOWED))
        self.assertEqual(unexpected, [], 'use store.updateInterjection(id:sessionId:) to change a saved Margin, or list the file in ALLOWED with the reason')

    def test_the_list_holds_no_stale_files(self):
        for rel in ALLOWED:
            self.assertTrue((ROOT / rel).exists(), f'{rel} is gone; remove it from ALLOWED')


if __name__ == '__main__':
    unittest.main()
