"""Rules that keep the matcher from being confidently wrong.

Each test names a way a wrong show or episode once looked right."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from b3 import match as m  # noqa: E402
from b3.youtube import VideoEvidence  # noqa: E402


def video(title, channel, desc="", published="2026-09-20", duration=3600):
    return VideoEvidence(video_id="x" * 11, title=title, channel=channel,
                         published=published, duration_s=duration, description=desc)


def support(show_name, artist, v, searched=None):
    return m._name_support({"collectionName": show_name, "artistName": artist},
                           m.show_sources(v), searched)


class ShowSupportTests(unittest.TestCase):
    def test_channel_named_show_is_identified(self):
        v = video("Benny Blanco | SmartLess", "SmartLess")
        self.assertEqual(support("SmartLess", "Jason Bateman, Sean Hayes, Will Arnett", v, "SmartLess"), 1.0)

    def test_publisher_suffix_ignored(self):
        v = video("Anthropic IPO at Risk", "All-In Podcast")
        self.assertEqual(support("All-In with Chamath, Jason, Sacks & Friedberg", "All-In Podcast, LLC", v), 1.0)

    def test_keyword_stuffed_show_name_is_not_identified(self):
        v = video("The Art of True Happiness | Dr. Arthur Brooks", "Andrew Huberman")
        stuffed = ("High Capacity - Nervous System Regulation, Stress, Burnout Recovery, "
                   "Andrew Huberman, Joe Rogan, Anxiety, Boundaries")
        self.assertLess(support(stuffed, "Someone Else", v, "Andrew Huberman"), 0.8)

    def test_guest_in_title_tail_does_not_identify_guests_show(self):
        v = video("Essentials: Optimal Protocols | Dr. Andy Galpin", "Andrew Huberman")
        self.assertLess(support("Perform with Dr. Andy Galpin", "Andy Galpin", v, "Dr. Andy Galpin"), 0.8)

    def test_exact_show_name_in_title_tail_is_identified(self):
        v = video("Matthew McConaughey (Full Episode) | Conan O'Brien Needs A Friend", "Team Coco")
        self.assertEqual(support("Conan O'Brien Needs A Friend", "Team Coco & Earwolf", v), 1.0)

    def test_search_hit_alone_does_not_identify(self):
        v = video("AI Realist vs 20 AI Optimists | Surrounded", "Jubilee")
        self.assertLess(support("Jubilee Church Sermons Weekly Messages From Pastor", "Jubilee Church", v), 0.8)


class ConfidenceGateTests(unittest.TestCase):
    def sig(self, **kw):
        base = dict(title=1.0, desc=1.0, days=0, duration="match", number=None)
        base.update(kw)
        return m.Signals(**base)

    def show(self, strength=1.0):
        return m.ShowCandidate(1, "Show", "Pub", strength, [])

    def test_perfect_match_is_confident(self):
        self.assertTrue(m._is_confident(self.sig(), self.show())[0])

    def test_clip_length_blocks(self):
        self.assertFalse(m._is_confident(self.sig(duration="mismatch"), self.show())[0])

    def test_unbacked_show_blocks(self):
        self.assertFalse(m._is_confident(self.sig(), None)[0])

    def test_conflicting_episode_number_blocks(self):
        self.assertFalse(m._is_confident(self.sig(number=False), self.show())[0])

    def test_rerelease_years_apart_blocks(self):
        # SmartLess re-release: same title, description and length as the 2023 original.
        self.assertFalse(m._is_confident(self.sig(days=1214), self.show())[0])

    def test_loose_show_needs_unmistakable_episode(self):
        self.assertFalse(m._is_confident(self.sig(desc=0.5), self.show(0.6))[0])
        self.assertTrue(m._is_confident(self.sig(desc=0.9), self.show(0.6))[0])


class DescriptionTests(unittest.TestCase):
    def test_shared_boilerplate_does_not_count(self):
        boiler = ("Subscribe to our newsletter for weekly updates. Follow us on TikTok Instagram and "
                  "Threads. Thanks to our sponsors Athletic Greens Eight Sleep and Helix Sleep. "
                  "Produced by the team with editing by our wonderful audio engineers and staff.")
        a = "A conversation about volcanoes and plate tectonics in Iceland. " + boiler
        b = "Why the stock market rallied after the central bank meeting this week. " + boiler
        eps = [{"collectionId": 7, "description": f"Episode {i} topic words {i}x. " + boiler} for i in range(10)]
        bp = m._boilerplate(eps)[7]
        self.assertLess(m._description_overlap(a, b, bp), 0.4)

    def test_same_opening_paragraph_counts(self):
        para = ("This week, we break down why everyone is suddenly talking about A.I. safety, why "
                "frontier A.I. companies are asking for regulation and why the administration is "
                "rejecting them. And then, to close out this chapter, we answer all your questions.")
        a = para + " FOLLOW US ON SOCIAL TikTok Instagram hosts' handles and more links here."
        b = para + " Additional Reading: several articles about the researcher whose rebellion matters."
        # Above the 0.6 the confidence gate treats as strong.
        self.assertGreaterEqual(m._description_overlap(a, b), 0.8)


if __name__ == "__main__":
    unittest.main()
