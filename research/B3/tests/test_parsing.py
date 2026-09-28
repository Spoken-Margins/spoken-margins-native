import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from b3 import match, youtube  # noqa: E402
from b3.text import title_similarity  # noqa: E402


class VideoIdTests(unittest.TestCase):
    def test_link_forms(self):
        for link in [
            "https://www.youtube.com/watch?v=s7d2d8FhevU",
            "https://youtu.be/s7d2d8FhevU?si=abc",
            "youtube.com/watch?feature=share&v=s7d2d8FhevU&t=120",
            "https://m.youtube.com/watch?v=s7d2d8FhevU",
            "https://www.youtube.com/live/s7d2d8FhevU?si=x",
            "https://www.youtube.com/shorts/s7d2d8FhevU",
            "https://www.youtube.com/embed/s7d2d8FhevU",
            "https://music.youtube.com/watch?v=s7d2d8FhevU&list=x",
        ]:
            self.assertEqual(youtube.video_id(link), "s7d2d8FhevU", link)

    def test_rejects_other_hosts_and_channels(self):
        self.assertIsNone(youtube.video_id("https://example.com/watch?v=s7d2d8FhevU"))
        self.assertIsNone(youtube.video_id("https://www.youtube.com/@lexfridman"))
        self.assertIsNone(youtube.video_id("https://www.youtube.com/playlist?list=PL123"))

    def test_date_and_duration_text(self):
        self.assertEqual(youtube._iso_date("Aug 12, 2026"), "2026-08-12")
        self.assertEqual(youtube._iso_date("Premiered Sep 3, 2026"), "2026-09-03")
        self.assertEqual(youtube._iso_date("Streamed live on Sep 3, 2026"), "2026-09-03")
        self.assertEqual(youtube._seconds("3:12:58"), 11578)
        self.assertEqual(youtube._seconds("54:53"), 3293)
        self.assertIsNone(youtube._seconds("LIVE"))


class TitleTests(unittest.TestCase):
    def test_episode_numbers(self):
        self.assertEqual(match.episode_numbers("DHH: Future of Programming | Lex Fridman Podcast #501"), {501})
        self.assertEqual(match.episode_numbers("688. When Is a Bet Not a Bet? | Freakonomics Radio"), {688})
        self.assertEqual(match.episode_numbers("Joe Rogan Experience #2558 - Tyler Engle"), {2558})
        self.assertEqual(match.episode_numbers("Episode 12: Hello"), {12})
        # Years and bare numbers in content are not episode numbers.
        self.assertEqual(match.episode_numbers("Mindscape Ask Me Anything | September 2026"), set())
        self.assertEqual(match.episode_numbers("The $10 Trillion Token Economy"), set())

    def test_content_title_drops_show_segments(self):
        t = match.content_title("Gregg Caruso on Living Well Without Free Will | Mindscape 369",
                                ["Sean Carroll", "Sean Carroll's Mindscape: Science, Society, Philosophy, Culture, Arts, and Ideas"])
        self.assertEqual(t, "Gregg Caruso on Living Well Without Free Will")
        t = match.content_title("Benny Blanco | SmartLess", ["SmartLess", "SmartLess"])
        self.assertEqual(t, "Benny Blanco")

    def test_title_similarity_is_order_and_suffix_tolerant(self):
        self.assertGreater(title_similarity(
            "Khabib Nurmagomedov: Dagestan, MMA, UFC, Islam, Conor, Fedor & Football",
            "#500 – Khabib Nurmagomedov: Dagestan, MMA, UFC, Islam, Conor, Fedor & Football"), 0.9)
        self.assertLess(title_similarity("The Art of True Happiness", "The Art of War"), 0.5)


if __name__ == "__main__":
    unittest.main()
