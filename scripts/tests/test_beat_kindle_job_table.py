"""The "Beat Kindle" table (#2710): the counts come from the flow map's edges, not from numbers typed by hand."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
TABLE = ROOT / "docs" / "design" / "live-sessions" / "job-table.py"
SITUATIONS = ROOT / "docs" / "design" / "live-sessions" / "SITUATIONS.md"


def load_table():
    spec = importlib.util.spec_from_file_location("live_sessions_job_table", TABLE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BeatKindleJobTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = load_table()
        cls.rows = {r[0]: r for r in cls.table.kindle_rows(cls.table.prop, cls.table.result)}

    def test_back_tap_as_built_ties_kindles_low_count(self):
        # Back Tap opens the app (#4923), then Save & resume and the move back to the book: 3, as Kindle's low count.
        _, _, taps, _, saved, per_sitting, once_ever = self.rows["L19"]
        self.assertEqual((taps, saved, per_sitting, once_ever), (3, 0, None, None))

    def test_the_as_built_back_tap_route_is_the_one_the_intent_takes(self):
        # L19 counts the intent as it is: it opens the app and starts the live session's recording. If either line
        # leaves the intent, the count no longer describes the code and must be redone.
        intent = (ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp" / "RecordMarginShortcutIntent.swift").read_text(encoding="utf-8")
        edge = next(e for e in self.table.edges if e["id"] == "ls19")
        self.assertIn(edge["anchor"], intent)
        self.assertIn("static let openAppWhenRun = true", intent)
        edges = [e for e in self.table.edges if e["id"] != "ls19"]
        self.assertIsNone(self.table.ct.compute_all(edges, self.table.jobs, self.table.start)["L19"])

    def test_back_tap_in_place_is_two_actions_because_a_pause_never_ends_a_margin(self):
        # Back Tap to start, Back Tap to stop (#3650: silence never ends a Margin).
        _, _, taps, _, saved, per_sitting, once_ever = self.rows["L17"]
        self.assertEqual(taps, 2)
        self.assertEqual(saved, 1)
        self.assertEqual(per_sitting, 2)
        # 6 taps once ever plus the first sitting's 2, over 1 saved per Margin.
        self.assertEqual(once_ever, 8)

    def test_island_without_auto_stop_ties_kindle(self):
        _, _, taps, _, saved, per_sitting, once_ever = self.rows["L18"]
        self.assertEqual((taps, saved, per_sitting, once_ever), (3, 0, None, None))

    def test_a_job_that_does_not_beat_kindles_low_count_has_no_break_even(self):
        prop = dict(self.table.prop)
        prop["reference"] = dict(prop["reference"], taps_low=1)
        rows = {r[0]: r for r in self.table.kindle_rows(prop, self.table.result)}
        self.assertEqual(rows["L17"][4:], (-1, None, None))
        self.assertEqual(rows["L18"][4:], (-2, None, None))

    def test_the_counts_follow_the_edges(self):
        # Without auto-stop the island costs the Record and the Stop (L05); Back Tap has no edge of its own to lose.
        self.assertEqual(self.table.result["L05"][0], 3)
        edges = [e for e in self.table.edges if e["id"] != "ls18"]
        self.assertIsNone(self.table.ct.compute_all(edges, self.table.jobs, self.table.start)["L17"])

    def test_island_count_follows_the_long_press_edge(self):
        edges = [e for e in self.table.edges if e["id"] != "ls11"]
        after = self.table.ct.compute_all(edges, self.table.jobs, self.table.start)
        self.assertNotEqual(after["L18"], self.table.result["L18"])

    def test_every_check_a_job_rests_on_is_in_the_device_check_table(self):
        text = SITUATIONS.read_text(encoding="utf-8")
        for job in self.table.jobs:
            for check in (c.strip() for c in job.get("extra", {}).get("checks", "").split(",") if c.strip()):
                self.assertIn("| %s |" % check, text, "job %s rests on %s, which section 5 does not list" % (job["id"], check))

    def test_situations_table_shows_the_computed_beat_kindle_numbers(self):
        text = SITUATIONS.read_text(encoding="utf-8")
        for jid, name, taps, kindle, saved, per_sitting, once in self.table.kindle_rows(self.table.prop, self.table.result):
            line = "| %s | %s | %s, plus typing | %s | %s | %s |" % (
                name, taps, kindle, saved if saved > 0 else "none",
                per_sitting if per_sitting is not None else "never", once if once is not None else "n/a")
            self.assertIn(line, text)


if __name__ == "__main__":
    unittest.main()
