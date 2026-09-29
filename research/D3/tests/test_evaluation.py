import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from evaluate import load_log, metrics, replay, summarize  # noqa: E402
from rank import load_policy, rank_items  # noqa: E402
from synth import generate  # noqa: E402


def ts(day, hour=8):
    return datetime(2026, 1, 1, hour, tzinfo=timezone.utc) + timedelta(days=day)


def event(kind, source_id, item_id, day, published_day, **extra):
    source = {"id": source_id, "title": source_id, "subscription_kind": "podcast_feed",
              "content_kind": "podcast", "categories": ["test"]}
    item = {"id": item_id, "title": item_id, "published_at": ts(published_day).isoformat(),
            "duration_seconds": 100}
    return dict({"schema_version": "i4-engagement.draft-1", "event": kind,
                 "at": ts(day, extra.pop("hour", 8)).isoformat(), "source": source, "item": item}, **extra)


class RankingTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_policy(ROOT / "policy.json")

    def test_no_signals_matches_newest_and_metrics(self):
        as_of = ts(5)
        items = [event("item_published", "a", "old", 1, 1),
                 event("item_published", "b", "new", 3, 3)]
        newest = sorted(items, key=lambda row: row["item"]["published_at"], reverse=True)
        scored = [row["item"] for row in rank_items(items, as_of, [], self.policy)]
        self.assertEqual([r["item"]["id"] for r in newest], [r["item"]["id"] for r in scored])
        self.assertEqual(metrics(newest, {"old"}), metrics(scored, {"old"}))

    def test_planted_preference_beats_date(self):
        rows = []
        # Establish a strong preference for source love before the evaluated day.
        for index in range(5):
            rows += [event("item_published", "love", "past%d" % index, -8 + index, -8 + index),
                     event("listened", "love", "past%d" % index, -7 + index, -8 + index, seconds=100),
                     event("finish", "love", "past%d" % index, -7 + index, -8 + index),
                     event("margin", "love", "past%d" % index, -7 + index, -8 + index,
                           margin_kind="written", length=20, length_unit="characters")]
        # On day 1, ten newer distractors sit above the positive from the loved source.
        rows.append(event("item_published", "love", "wanted", 0, 0))
        for index in range(10):
            distractor = event("item_published", "other%d" % index, "noise%d" % index, 0, 0,
                               hour=9 + index % 10)
            distractor["item"]["published_at"] = ts(0, 9 + index % 10).isoformat()
            rows.append(distractor)
        rows.append(event("finish", "love", "wanted", 2, 0))
        samples = replay(sorted(rows, key=lambda row: row["at"]), self.policy)
        result = summarize(samples, bootstrap=200)
        self.assertGreater(result["ndcg@10"][1], result["ndcg@10"][0])
        self.assertLess(result["mean_positive_rank"][1], result["mean_positive_rank"][0])

    def test_future_signals_do_not_change_earlier_ranking(self):
        items = [event("item_published", "a", "a1", 0, 0), event("item_published", "b", "b1", 0, 0, hour=9)]
        as_of = ts(1)
        future = [event("share", "a", "a1", 3, 0)]
        before = rank_items(items, as_of, [row for row in future if datetime.fromisoformat(row["at"]) < as_of], self.policy)
        after = rank_items(items, as_of, [], self.policy)
        self.assertEqual([(r["item"]["item"]["id"], r["score"]) for r in before],
                         [(r["item"]["item"]["id"], r["score"]) for r in after])

    def test_malformed_log_reports_line(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.jsonl"
            path.write_text('{"schema_version":"wrong"}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, r"bad\.jsonl:1: unsupported schema_version"):
                load_log(path)

    def test_synthetic_log_is_deterministic_and_has_six_signal_types(self):
        first = generate(seed=9, source_count=60, weeks=3)
        self.assertEqual(first, generate(seed=9, source_count=60, weeks=3))
        self.assertEqual(60, len({row["source"]["id"] for row in first}))
        present = {row["event"] for row in first}
        self.assertTrue({"listened", "margin", "share", "export", "packet_import", "dismiss", "finish"} <= present)


if __name__ == "__main__":
    unittest.main()
