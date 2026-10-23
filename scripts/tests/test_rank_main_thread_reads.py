"""scripts/rank_main_thread_reads.py: pricing the audited main-thread reads from the read-cost table (#2513)."""
import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import rank_main_thread_reads as rank  # noqa: E402

ROOT = SCRIPTS.parent

# Two scales' worth of columns, as ReadCostReport.markdown() writes them: name, then ms/rows/bytes per scale.
TABLE = rank.parse_cost_table("""
| read | small: ms | rows | bytes | library: ms | rows | bytes | 3x: ms | rows | bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `loadSessions()` | 1 | 1 | 1 | 6.5 | 361 | 1 | 9 | 1 | 1 |
| `loadSessions(itemId: article)` | 0 | 1 | 1 | 0.04 | 1 | 1 | 0 | 1 | 1 |
| `loadInterjections(sessionId:)` | 0 | 1 | 1 | 0.1 | 1 | 1 | 0 | 1 | 1 |
| `loadInterjections(itemId: mapped)` | 0 | 1 | 1 | 2 | 18 | 1 | 0 | 1 | 1 |
| `loadItem(article)` | 0 | 1 | 1 | 0.06 | 1 | 1 | 0 | 1 | 1 |
| `loadAudioPreparationJobs()` | 0 | 1 | 1 | 0.11 | 12 | 1 | 0 | 1 | 1 |
| `screen: LibraryReadSnapshot.read(store:)` | 0 | 1 | 1 | 72 | 847 | 1 | 0 | 1 | 1 |
| `screen: ItemDetailLoader.load(article)` | 0 | 1 | 1 | 3.9 | 19 | 1 | 0 | 1 | 1 |
""")


def row(reads, frequency="often", basis="unmeasured", fix_class="targeted-refresh"):
    return {"function": "X.f", "file": "App/X.swift", "meter_reads": reads, "frequency": frequency,
            "cost_ms_library": None if basis == "unmeasured" else 1.0, "cost_basis": basis, "fix_class": fix_class,
            "scanner_rows": 1, "score": 0, "trigger": "t", "fix_note": "n", "stay_reason": "", "citations": []}


class ParsingTheTable(unittest.TestCase):
    def test_takes_the_library_scale_column(self):
        self.assertEqual(TABLE["loadSessions()"], 6.5)
        self.assertEqual(TABLE["screen: LibraryReadSnapshot.read(store:)"], 72)

    def test_ignores_headers_and_prose(self):
        self.assertNotIn("read", TABLE)
        self.assertEqual(len(TABLE), 8)


class PricingOneRead(unittest.TestCase):
    def price(self, entry):
        return rank.price_entry(entry, TABLE)[:2]

    def test_a_plain_name_takes_the_no_argument_row(self):
        self.assertEqual(self.price("loadSessions"), ("read", 6.5))

    def test_a_qualifier_picks_the_row_that_says_the_same(self):
        self.assertEqual(self.price("loadSessions(itemId)"), ("read", 0.04))
        self.assertEqual(self.price("loadInterjections(sessionId)"), ("read", 0.1))
        self.assertEqual(self.price("loadItem(detail)"), ("read", 0.06))

    def test_notes_after_the_name_do_not_hide_the_read(self):
        self.assertEqual(self.price("loadSessions (again)"), ("read", 6.5))
        self.assertEqual(self.price("loadAudioPreparationJobs (x5-6)"), ("read", 0.55))
        self.assertEqual(self.price("loadAudioPreparationJobs (again)"), ("read", 0.11))

    def test_a_repeat_count_multiplies(self):
        self.assertEqual(self.price("loadLibraryRows x2 (full snapshot each)"), ("read", 144))
        self.assertEqual(self.price("refreshLibraryRows (full snapshot, twice on the two paths)"), ("read", 144))

    def test_a_whole_screen_is_the_screen_row(self):
        self.assertEqual(self.price("loadItemDetail reads"), ("read", 3.9))

    def test_writes_are_named_but_not_priced(self):
        for entry in ("saveItem", "deleteItems (write)", "updateOwnedOfflineAsset (write, only on a change)",
                      "savePodcastDownload (write via persist)", "reset", "seed(item)"):
            self.assertEqual(self.price(entry), ("write", 0.0), entry)

    def test_a_read_that_runs_more_than_once_is_priced_once_and_marked(self):
        for entry in ("loadItem per trashed item", "loadAudioPreparationJobs (4-7 per chunk)", "loadItem (up to 3)"):
            self.assertEqual(self.price(entry)[0], "lower", entry)
        self.assertEqual(self.price("loadItem x2")[0], "read")

    def test_a_space_before_the_qualifier_still_picks_the_row(self):
        self.assertEqual(self.price("loadSessions (itemId)"), ("read", 0.04))

    def test_a_read_the_fixture_cannot_exercise_is_unpriced(self):
        self.assertEqual(self.price("quarantinedMarginAudioPaths per item"), ("unpriced", 0.0))

    def test_a_read_the_table_lacks_is_unpriced(self):
        self.assertEqual(self.price("ListeningEditionStore file read"), ("unpriced", 0.0))
        self.assertEqual(self.price("SQLiteSessionStore.init"), ("unpriced", 0.0))
        self.assertEqual(self.price("loadSomethingNew"), ("unpriced", 0.0))


class PricingARow(unittest.TestCase):
    def test_sums_the_reads_and_scores_by_frequency(self):
        change = rank.price_row(row(["loadSessions", "loadItem", "saveSession"]), TABLE)
        self.assertEqual(change["cost_ms_library"], 6.56)
        self.assertEqual(change["cost_basis"], "measured")
        self.assertEqual(change["score"], 66)   # 6.56 ms x often (10)
        self.assertIn("1 write(s) not priced", change["cost_note"])

    def test_one_unpriced_read_makes_it_a_lower_bound(self):
        change = rank.price_row(row(["loadSessions", "SQLiteSessionStore.init"], frequency="rare"), TABLE)
        self.assertEqual(change["cost_basis"], "partial")
        self.assertEqual(change["score"], 6)
        self.assertIn("lower bound", change["cost_note"])

    def test_a_plus_entry_prices_both_reads(self):
        change = rank.price_row(row(["loadSessions + loadItem"]), TABLE)
        self.assertEqual(change["cost_ms_library"], 6.56)

    def test_a_repeated_read_makes_the_row_a_lower_bound(self):
        self.assertEqual(rank.price_row(row(["loadItem per trashed item"]), TABLE)["cost_basis"], "partial")

    def test_nothing_priced_leaves_the_row_alone(self):
        self.assertIsNone(rank.price_row(row(["saveItem", "ListeningEditionStore file read"]), TABLE))
        self.assertIsNone(rank.price_row(row([]), TABLE))

    def test_measured_and_estimated_rows_are_not_touched(self):
        rows = [row(["loadSessions"], basis="measured"), row(["loadSessions"], basis="estimated"), row(["loadSessions"])]
        moved = rank.apply_prices(rows, TABLE)
        self.assertEqual(len(moved), 1)
        self.assertEqual(rows[0]["cost_ms_library"], 1.0)
        self.assertEqual(rows[2]["cost_basis"], "measured")

    def test_an_unmeasured_row_with_a_placeholder_floor_is_priced(self):
        floor = row(["loadSessions"])
        floor["cost_ms_library"] = 0.04
        rank.apply_prices([floor], TABLE)
        self.assertEqual((floor["cost_ms_library"], floor["cost_basis"]), (6.5, "measured"))

    def test_an_estimated_row_with_no_number_is_priced(self):
        empty = row(["loadSessions"], basis="estimated")
        empty["cost_ms_library"] = None
        self.assertEqual(len(rank.apply_prices([empty], TABLE)), 1)
        self.assertEqual(empty["cost_ms_library"], 6.5)
        self.assertEqual(empty["cost_basis"], "measured")


class TheCommittedAudit(unittest.TestCase):
    def test_the_markdown_is_what_the_script_renders_from_the_json(self):
        rows = json.loads((ROOT / "docs/audit/main-thread-reads-ranked.json").read_text())
        md = (ROOT / "docs/audit/main-thread-reads-ranked.md").read_text()
        self.assertEqual(md, rank.render(rows, rank.header_of(md)),
                         "run scripts/rank_main_thread_reads.py --render --write after editing the json")

    def test_every_priced_row_agrees_with_its_score(self):
        rows = json.loads((ROOT / "docs/audit/main-thread-reads-ranked.json").read_text())
        for r in rows:
            if r["cost_ms_library"] is not None:
                self.assertEqual(round(r["score"]), round(r["cost_ms_library"] * rank.WEIGHT[r["frequency"]]), r["function"])


if __name__ == "__main__":
    unittest.main()
