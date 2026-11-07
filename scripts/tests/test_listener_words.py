"""The "item" word guard (#3599): what counts as listener-facing, and that the ratchet only moves down."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import listener_words as lw  # noqa: E402


def rows_of(source: str) -> list[dict]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'Sample.swift'
        path.write_text(source, encoding='utf-8')
        return lw.scan_file(path, 'Sample.swift')


def kinds(source: str) -> list[str]:
    return [row['kind'] for row in rows_of(source)]


class KindTests(unittest.TestCase):
    def test_a_table_of_neighbouring_inputs(self):
        table = [
            ('Text("Skip to the item")', ['words']),
            ('Text("Items already in your Library are kept")', ['words']),
            ('Text("Item")', ['words']),                                    # a lone capitalised word is read
            ('Text("ITEM")', ['words']),
            ('Text("Open item and shared controls")', ['words']),
            ('.accessibilityLabel("Item options")', ['voiceover']),
            ('.accessibilityHint("Opens the item.")', ['voiceover']),
            ('.accessibilityIdentifier("item.lastFailure")', ['identifier']),
            ('.accessibilityIdentifier("item row for the open item")', ['identifier']),
            ('let id = "item.screen"', ['identifier']),                     # identifier-shaped, no spaces
            ('let file = "items.json"', ['identifier']),
            ('logger.info("item finished loading")', ['identifier']),
            ('print("saving the item")', ['identifier']),
            ('fatalError("no item for this id")', ['identifier']),
            ('assertionFailure("item missing")', ['identifier']),
            ('Text("itemId")', []),                                         # a code name, not the word
            ('Text("Item4 is first")', []),
            ('Text("Reitems")', []),
            ('Text("Skip to the episode")', []),
            ('Text("")', []),
            ('// Text("Skip to the item")', []),
            ('/// the item is shown', []),
            ('Text("Skip to the episode") // not the item', []),
            ('Text("A // B item")', ['words']),                             # `//` inside a string is not a comment
            ('Text("one item"); Text("two items")', ['words', 'words']),
            ('Text("It\\"s an item")', ['words']),
        ]
        for source, expected in table:
            self.assertEqual(kinds(source), expected, source)

    def test_the_text_and_position_are_reported(self):
        rows = rows_of('let a = 1\nText("Skip to the item")\n')
        self.assertEqual([(row['line'], row['text']) for row in rows], [(2, 'Skip to the item')])


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.rows = [
            {'kind': 'words', 'text': 'Skip to the item', 'file': 'A.swift', 'line': 1},
            {'kind': 'identifier', 'text': 'item.screen', 'file': 'A.swift', 'line': 2},
        ]
        self.baseline = {('words', 'Skip to the item'): {'kind': 'words', 'text': 'Skip to the item', 'count': 1}}

    def test_what_the_baseline_holds_passes_and_identifiers_never_count(self):
        new, stale = lw.compare(self.rows, self.baseline)
        self.assertEqual((new, stale), ([], []))

    def test_a_new_literal_fails_even_when_it_moves_files(self):
        moved = [{**self.rows[0], 'file': 'B.swift', 'line': 9}]
        self.assertEqual(lw.compare(moved, self.baseline), ([], []))
        added = self.rows + [{'kind': 'words', 'text': 'Open Item', 'file': 'B.swift', 'line': 3}]
        new, _ = lw.compare(added, self.baseline)
        self.assertEqual([row['text'] for row in new], ['Open Item'])

    def test_a_second_copy_of_a_baseline_literal_fails(self):
        twice = self.rows + [{**self.rows[0], 'file': 'C.swift', 'line': 5}]
        new, _ = lw.compare(twice, self.baseline)
        self.assertEqual([row['file'] for row in new], ['C.swift'])

    def test_a_replaced_literal_is_stale_until_the_baseline_is_updated(self):
        _, stale = lw.compare([self.rows[1]], self.baseline)
        self.assertEqual(stale, [('words', 'Skip to the item')])

    def test_the_same_text_as_words_and_as_voiceover_are_separate_rows(self):
        rows = [{'kind': 'voiceover', 'text': 'Skip to the item', 'file': 'A.swift', 'line': 1}]
        new, _ = lw.compare(rows, self.baseline)
        self.assertEqual(len(new), 1)


class RepoTests(unittest.TestCase):
    def test_the_checked_in_baseline_holds_every_literal_in_the_tree(self):
        new, stale = lw.compare(lw.scan(), lw.load_baseline())
        self.assertEqual([f"{r['file']}:{r['line']} {r['text']}" for r in new], [], 'a new listener-facing "item" (#3599)')
        self.assertEqual(stale, [], 'run scripts/listener_words.py --update')

    def test_every_baseline_row_says_why_it_is_there(self):
        data = json.loads(lw.BASELINE.read_text(encoding='utf-8'))
        for entry in data['entries']:
            self.assertTrue(entry.get('reason'), entry)
            self.assertIn(entry['kind'], ('words', 'voiceover'))


if __name__ == '__main__':
    unittest.main()
