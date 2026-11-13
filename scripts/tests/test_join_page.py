"""The join page (Site/join/index.html) and its line for people who are not on an iPhone (#4170).

Someone who found Spoken Margins by searching and has no iPhone saw three TestFlight steps and nothing else. The
owner said yes on 2026-11-12 ("4170 yes") to linking the web listener from this page, and the line must not promise
share links, which stay behind the build-time flag and the lawyer's answer. The invite flow Build 36 depends on, the
two TestFlight links and the steps, stay as they were.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JOIN = ROOT / "Site" / "join" / "index.html"

WEB_LISTENER = "https://app.spokenmargins.com/"
TESTFLIGHT_APP = "https://apps.apple.com/app/testflight/id899247664"
TESTFLIGHT_INVITE = "https://testflight.apple.com/join/aXR7DWDA"


def page() -> str:
    return JOIN.read_text(encoding="utf-8")


def web_line(html: str) -> str:
    match = re.search(r'<p class="web">(.*?)</p>', html, re.S)
    assert match, 'the join page has no <p class="web"> line'
    return match.group(1)


class JoinPageTests(unittest.TestCase):
    def test_the_web_listener_line_links_to_the_listener(self):
        line = web_line(page())
        self.assertEqual(re.findall(r'href="([^"]+)"', line), [WEB_LISTENER])

    def test_the_line_sits_under_the_hook_and_above_step_one(self):
        html = page()
        hook, line, steps = html.index('class="hook"'), html.index('class="web"'), html.index("<ol>")
        self.assertLess(hook, line)
        self.assertLess(line, steps)

    def test_the_words_are_plain_and_promise_no_share_links(self):
        words = re.sub(r"<[^>]+>", "", web_line(page()))
        self.assertEqual(words, "No iPhone or iPad? Use Spoken Margins in your browser.")
        for banned in ("link", "share", "invite", "friend"):
            self.assertNotIn(banned, words.lower())

    def test_the_testflight_steps_and_links_are_unchanged(self):
        html = page()
        self.assertEqual(html.count(f'href="{TESTFLIGHT_APP}"'), 1)
        self.assertEqual(html.count(f'href="{TESTFLIGHT_INVITE}"'), 1)
        for kept in (
            "Get TestFlight. <b>Then tap again.</b>",
            "Come back here. Tap again.",
            "Already have TestFlight?",
            "Seeing a \"Redeem\" screen?",
            "TestFlight says this beta is full? You can still listen from the link your friend sent. No app needed.",
        ):
            self.assertIn(kept, html)

    def test_the_link_is_not_left_to_colour_alone_and_is_a_44_point_target(self):
        html = page()
        rule = re.search(r"\.web a\{([^}]*)\}", html)
        self.assertIsNotNone(rule, "no .web a style")
        self.assertIn("text-decoration:underline", rule.group(1))
        self.assertIn("min-height:44px", rule.group(1))
        self.assertIn(".web a:focus-visible", html)

    def test_search_gets_a_description_that_names_both_ways_in(self):
        html = page()
        match = re.search(r'<meta name="description" content="([^"]+)">', html)
        self.assertIsNotNone(match, "the page has no meta description")
        self.assertIn("TestFlight", match.group(1))
        self.assertIn("browser", match.group(1))
        self.assertLess(html.index("<title>"), html.index('name="description"'))


if __name__ == "__main__":
    unittest.main()
