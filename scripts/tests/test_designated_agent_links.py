"""The DMCA designated-agent page and the places that must link to it (#2236, step 2).

17 U.S.C. § 512(c)(2): the safe harbor needs the agent's contact details posted where users can find them. The page
is Site/copyright/. Every static page's footer, the app's Settings and the web app's Settings must reach it, and the
page must keep the details a notice needs.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "Site"
PAGE_URL = "https://spokenmargins.proximitytoprogress.com/copyright/"


class DesignatedAgentPageTests(unittest.TestCase):
    def test_page_names_the_agent_and_how_to_send_a_notice(self):
        html = (SITE / "copyright" / "index.html").read_text(encoding="utf-8")
        for needed in ("Designated agent", "Proximity to Progress LLC", "Phone:", "mailto:", "512(c)(3)", "Counter-notice"):
            self.assertIn(needed, html, f"the designated-agent page lost {needed!r}")
        self.assertRegex(html, r"\d{4} [A-Z]|[A-Z][a-z]+, IL \d{5}", "the page needs the agent's postal address")

    def test_every_static_page_footer_links_to_the_page(self):
        pages = [p for p in SITE.rglob("index.html") if p.parent.name != "copyright"]
        self.assertTrue(pages)
        missing = []
        for page in pages:
            html = page.read_text(encoding="utf-8")
            # A page that carries a footer or a "Beta resources" list must link to the copyright page.
            if "<footer" in html or "Beta resources" in html:
                if not re.search(r'href="[^"]*copyright/"', html):
                    missing.append(str(page.relative_to(ROOT)))
        self.assertEqual(missing, [], "these pages have a footer without the Copyright and DMCA link")

    def test_app_settings_links_to_the_page(self):
        sources = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
        links = (sources / "AppLinks.swift").read_text(encoding="utf-8")
        self.assertIn(PAGE_URL, links)
        self.assertIn("AppLinks.copyright", (sources / "SettingsScreen.swift").read_text(encoding="utf-8"))

    def test_web_app_settings_links_to_the_page(self):
        settings = (ROOT / "Web" / "src" / "app" / "screens" / "Settings.tsx").read_text(encoding="utf-8")
        self.assertIn(PAGE_URL, settings)


if __name__ == "__main__":
    unittest.main()
