import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from evaluate import load_log, main as evaluate_main, metrics, replay, summarize  # noqa: E402
from rank import load_policy, rank_items, source_features  # noqa: E402
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

    def test_listened_share_uses_a_duration_from_any_row(self):
        # The app's item_published rows can lack the duration its listened rows carry.
        published = event("item_published", "a", "a1", 0, 0)
        published["item"]["duration_seconds"] = None
        history = [published, event("listened", "a", "a1", 1, 0, seconds=50)]
        items = [event("item_published", "a", "a2", 1, 1), event("item_published", "b", "b1", 1, 1, hour=9)]
        ranked = rank_items(items, ts(2), history, self.policy)
        self.assertEqual("a2", ranked[0]["item"]["item"]["id"])
        self.assertIn("listen", ranked[0]["reason"])

    def test_future_signals_do_not_change_earlier_ranking(self):
        # Two sources publish together; the later-loved one has the lower id, so
        # it only wins a ranking if a signal about it has leaked in. Nothing is
        # known on days 1 and 2, so the score ranking must equal the newest-first one.
        def log(extra):
            rows = [event("item_published", "src-a", "a1", 0, 0), event("item_published", "src-b", "b1", 0, 0),
                    event("finish", "src-a", "a1", 2, 0, hour=8)] + extra
            return sorted(rows, key=lambda row: row["at"])

        leaked = [event("share", "src-a", "a1", 2, 0, hour=9), event("share", "src-a", "a1", 3, 0)]
        for extra in ([], leaked):
            samples = replay(log(extra), self.policy)
            self.assertEqual(["2026-01-02", "2026-01-03"], [sample["day"] for sample in samples])
            for sample in samples:
                self.assertEqual(sample["newest"], sample["score"], sample["day"])
        # Control: the same share does reorder the two when it is genuinely in the past.
        items = [event("item_published", "src-a", "a1", 0, 0), event("item_published", "src-b", "b1", 0, 0)]
        ranked = rank_items(items, ts(3), [event("share", "src-a", "a1", 2, 0)], self.policy)
        self.assertEqual("a1", ranked[0]["item"]["item"]["id"])

    def test_metrics_match_hand_computed_values(self):
        def order(count):
            return [{"item": {"id": "i%d" % index}} for index in range(count)]

        # Positives at ranks 2 and 7: DCG = 1/log2(3) + 1/log2(8); the ideal puts them at ranks 1 and 2.
        result = metrics(order(10), {"i1", "i6"})
        self.assertAlmostEqual(0.5912352048, result["ndcg@10"], places=9)
        self.assertAlmostEqual(0.2, result["precision@5"])          # one of the top five
        self.assertAlmostEqual(4.5, result["mean_positive_rank"])   # (2 + 7) / 2
        # Both in the top five, and a perfect order.
        self.assertAlmostEqual(0.4, metrics(order(10), {"i0", "i4"})["precision@5"])
        self.assertAlmostEqual(1.0, metrics(order(10), {"i0", "i1"})["ndcg@10"])
        # A positive past rank 10 scores nothing on NDCG and precision, but still has a rank.
        late = metrics(order(15), {"i11"})
        self.assertEqual((0.0, 0.0, 12), (late["ndcg@10"], late["precision@5"], late["mean_positive_rank"]))
        # No positives: zero and no rank.
        none = metrics(order(5), set())
        self.assertEqual((0.0, 0.0, None), (none["ndcg@10"], none["precision@5"], none["mean_positive_rank"]))

    def test_source_features_count_each_signal(self):
        def row(kind, item_id, **extra):
            return event(kind, "src", item_id, 1, 0, **extra)

        history = [row("item_published", "i0"), row("item_published", "i1"), row("item_published", "i2"),
                   row("listened", "i0", seconds=50), row("finish", "i1"),
                   row("share", "i1"), row("margin", "i0", margin_kind="written", length=5),
                   row("margin", "i1", margin_kind="spoken", length=9), row("dismiss", "i2")]
        features = source_features(history)["src"]
        self.assertAlmostEqual(50 / 300, features["listened_share"])  # three items of 100 seconds
        self.assertAlmostEqual(1 / 3, features["finish_rate"])
        self.assertEqual(2, features["margin_count"])
        self.assertEqual(1, features["share_count"])
        self.assertAlmostEqual(1 / 3, features["dismiss_rate"])

        # The duration is the largest any row of the item carries, whichever row comes last.
        short = row("item_published", "j0")
        short["item"]["duration_seconds"] = None
        history = [row("listened", "j0", seconds=25), short]
        self.assertAlmostEqual(25 / 100, source_features(history)["src"]["listened_share"])

    def test_each_signal_alone_reorders_two_otherwise_equal_sources(self):
        # Equal dates; a tie goes to the higher id, so "b1" leads unless a signal says otherwise.
        items = [event("item_published", "src-a", "a1", 3, 3), event("item_published", "src-b", "b1", 3, 3)]
        no_signal = [row["item"]["item"]["id"] for row in rank_items(items, ts(5), [], self.policy)]
        self.assertEqual(["b1", "a1"], no_signal)

        def order(history):
            return [row["item"]["item"]["id"] for row in rank_items(items, ts(5), history, self.policy)]

        past = [event("item_published", "src-a", "a0", 0, 0), event("item_published", "src-b", "b0", 0, 0)]
        self.assertEqual(["a1", "b1"], order(past + [event("share", "src-a", "a0", 1, 0)]), "shares")
        self.assertEqual(["a1", "b1"], order(past + [event("margin", "src-a", "a0", 1, 0, margin_kind="spoken", length=3)]), "margins")
        self.assertEqual(["a1", "b1"], order(past + [event("finish", "src-a", "a0", 1, 0)]), "finishes")
        self.assertEqual(["a1", "b1"], order(past + [event("listened", "src-a", "a0", 1, 0, seconds=80)]), "listening")
        self.assertEqual(["a1", "b1"], order(past + [event("dismiss", "src-b", "b0", 1, 0)]), "dismissals")

    def test_bootstrap_interval_is_the_middle_95_percent(self):
        # Half the days gain nothing and half gain 1.0, so resampled means centre on 0.5 and
        # spread by about 0.11; the 2.5% and 97.5% points are near 0.3 and 0.7, not the extremes.
        samples = [{"newest": {"ndcg@10": 0.0, "precision@5": 0.0, "mean_positive_rank": 5},
                    "score": {"ndcg@10": float(index % 2), "precision@5": 0.0, "mean_positive_rank": 5}}
                   for index in range(20)]
        baseline, score, delta, low, high = summarize(samples)["ndcg@10"]
        self.assertEqual((0.0, 0.5, 0.5), (baseline, score, delta))
        self.assertTrue(0.25 <= low <= 0.35, low)
        self.assertTrue(0.65 <= high <= 0.75, high)

    def test_malformed_log_reports_line(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.jsonl"
            path.write_text('{"schema_version":"wrong"}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, r"bad\.jsonl:1: unsupported schema_version"):
                load_log(path)

    def test_reads_the_apps_recorded_log(self):
        # The published I4 fixture is byte-for-byte what the app's recorder writes
        # (SessionKit ListeningSignalRecorderTests.testRecorderWritesThePublishedFixture).
        fixture = ROOT.parents[1] / "Contracts/fixtures/listening-signals/i4-engagement-sample.jsonl"
        events = load_log(fixture)
        self.assertEqual({"item_published", "listened", "margin", "share", "export", "packet_import",
                          "dismiss", "finish"}, {row["event"] for row in events})
        samples = replay(events, self.policy)
        self.assertEqual(["2026-09-02", "2026-09-03", "2026-09-04"], [s["day"] for s in samples])
        self.assertEqual(0, evaluate_main([str(fixture)]))

    def test_synthetic_log_is_deterministic_and_has_six_signal_types(self):
        first = generate(seed=9, source_count=60, weeks=3)
        self.assertEqual(first, generate(seed=9, source_count=60, weeks=3))
        self.assertEqual(60, len({row["source"]["id"] for row in first}))
        present = {row["event"] for row in first}
        self.assertTrue({"listened", "margin", "share", "export", "packet_import", "dismiss", "finish"} <= present)


if __name__ == "__main__":
    unittest.main()
