"""Help for someone a friend sent Margins to (#5268).

A stuck receiver's only route was to ask the sender. The app's Help gained a section of their questions, each stuck
screen gained one tap to it, and the site gained the same questions on `Site/friends/`. These checks keep the parts a
host test can see: Help still makes no network request, each stuck screen keeps its Get Help, the site pages keep their
links, and the site's answers stay in a receiver's words. `FriendHelpTests` in SessionKit holds the app's questions and
the site's headings together.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
SITE = ROOT / "Site"

BANNED_WORDS = ("packet", "layer", "import", "anchor", "manifest", "session", "source")
NETWORK_CALLS = ("Link(", "AsyncImage", "URLSession", "openURL")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class FriendHelpAppTests(unittest.TestCase):
    def test_help_carries_the_friend_section_and_drops_the_needs_the_app_line(self):
        help_screen = read(APP / "HelpScreen.swift")
        self.assertIn("FriendHelpSection(focus: nil)", help_screen)
        self.assertNotIn("also has Spoken Margins", help_screen)

    def test_help_screens_make_no_network_request(self):
        for name in ("HelpScreen.swift", "FriendHelpScreen.swift"):
            source = read(APP / name)
            for call in NETWORK_CALLS:
                self.assertNotIn(call, source, f"{name} has {call}")

    def test_the_friend_help_reads_no_model(self):
        self.assertNotIn("EnvironmentObject", read(APP / "FriendHelpScreen.swift"))

    def test_each_stuck_screen_offers_get_help(self):
        for name, identifier in (
            ("PacketOpenFailureSheet.swift", "packetOpenFailure.help"),
            ("Build23RecipientSharingExperience.swift", "build23.recipient.help"),
            ("ExperienceItemDetailScreen.swift", "item.podcastDownload.help"),
        ):
            source = read(APP / name)
            self.assertIn(f'"{identifier}"', source, name)
            self.assertIn("FriendHelpScreen(focus:", source, name)


class FriendHelpSiteTests(unittest.TestCase):
    def test_join_support_and_home_link_the_friends_page(self):
        for relative, href in (("join/index.html", "../friends/"), ("support/index.html", "../friends/"), ("index.html", "friends/")):
            self.assertIn(f'href="{href}"', read(SITE / relative), relative)

    def test_the_friends_page_is_plain_and_links_the_policies(self):
        page = read(SITE / "friends" / "index.html")
        self.assertNotIn("<script", page)
        self.assertNotIn("<img", page)
        for href in ("../content-policy/", "../copyright/", "../support/"):
            self.assertIn(f'href="{href}"', page)

    def test_the_site_answers_use_a_receivers_words(self):
        page = read(SITE / "friends" / "index.html")
        answers = re.findall(r'<h2 id="[^"]+">[^<]*</h2>\s*<p>(.*?)</p>', page, re.S)
        self.assertEqual(len(answers), 10)
        for answer in answers:
            # Hrefs aren't read out: `app.spokenmargins.com` is an address, not a word.
            text = re.sub(r"<[^>]+>", "", answer).lower()
            for word in BANNED_WORDS:
                self.assertNotIn(word, text, answer[:60])
            self.assertNotIn("’", answer)
            self.assertNotIn("&#39;", answer)


if __name__ == "__main__":
    unittest.main()
