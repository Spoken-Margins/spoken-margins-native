"""The content policy and intimate-image removal pages for share links, and where they are linked (#2238).

Take It Down Act (47 U.S.C. § 223a) asks for a clear and conspicuous notice-and-removal process. Both pages are static
pages under Site/, linked from every static page's footer, every share page (research/B4/server/internal/links) and the
app's Settings. The pages repeat the owner's 2026-10-20 report rules, so a rule changed in one place shows up here.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "Site"
HOST = "https://spokenmargins.proximitytoprogress.com"
PAGES = {"content-policy": "/content-policy/", "intimate-images": "/intimate-images/"}


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class PolicyPageTests(unittest.TestCase):
    def test_pages_exist_with_a_contact_that_works(self):
        for name in PAGES:
            html = text(SITE / name / "index.html")
            self.assertIn("mailto:cole@proximitytoprogress.com", html, name)
            self.assertIn("3547 Dempster St", html, name)
            # The attorney meeting has not happened (#173): the pages say so until counsel marks them up.
            self.assertIn("not been reviewed by an attorney", html, name)

    def test_content_policy_states_the_owners_report_rules(self):
        html = text(SITE / "content-policy" / "index.html")
        for needed in (
            "A link you shared was taken down after a report",
            "Two reported links",
            "within 90 days",
            "Strike 1 pauses link sharing for 1 week",
            "Strike 2 pauses it for 1 month",
            "Strike 3 ends it for good",
            "7 days",
            "One word is enough",
            "Nobody reads the content",
            ".spokenmargins",
        ):
            self.assertIn(needed, html, f"the content policy lost {needed!r}")

    def test_intimate_image_page_promises_48_hours(self):
        html = text(SITE / "intimate-images" / "index.html")
        self.assertIn("48 hours", html)
        self.assertIn("reference number", html)
        self.assertIn("report.cybertip.org", html)

    def test_pages_ask_emailers_to_leave_off_the_key(self):
        for name in PAGES:
            html = text(SITE / name / "index.html")
            self.assertRegex(html, r"Leave off everything after the <code>#</code> sign", name)

    def test_every_static_page_footer_links_to_both(self):
        missing = []
        for page in SITE.rglob("index.html"):
            html = text(page)
            if "<footer" not in html and "Beta resources" not in html:
                continue
            for name in PAGES:
                if page.parent.name != name and not re.search(rf'href="[^"]*{name}/"', html):
                    missing.append(f"{page.relative_to(ROOT)} -> {name}")
        self.assertEqual(missing, [])

    def test_no_page_links_to_a_page_that_is_missing(self):
        for page in (SITE / name / "index.html" for name in PAGES):
            for href in re.findall(r'href="(\.\./[a-z-]+/)"', text(page)):
                self.assertTrue((SITE / href[3:] / "index.html").exists(), f"{page.parent.name} links to missing {href}")

    def test_app_settings_links_to_both(self):
        sources = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
        links, settings = text(sources / "AppLinks.swift"), text(sources / "SettingsScreen.swift")
        for name, path in PAGES.items():
            self.assertIn(HOST + path, links)
        self.assertIn("AppLinks.contentPolicy", settings)
        self.assertIn("AppLinks.intimateImageRemoval", settings)


if __name__ == "__main__":
    unittest.main()
