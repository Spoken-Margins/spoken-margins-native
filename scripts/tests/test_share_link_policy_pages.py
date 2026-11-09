"""The content policy page for share links, and where it is linked (#2238).

The page is a static page under Site/, linked from every static page's footer, every share page
(research/B4/server/internal/links) and the app's Settings. It repeats the owner's 2026-10-20 report rules, so a rule
changed in one place shows up here. There is no intimate-image removal page: share links carry voice and text, never
images (#3867), and a test below keeps it, and every link to it, gone. The report form and the policy keep a line
against non-consensual intimate content, worded for recordings, text and faked voices.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "Site"
HOST = "https://spokenmargins.proximitytoprogress.com"
PAGES = {"content-policy": "/content-policy/"}


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

    def test_no_intimate_image_page_and_nothing_links_to_one(self):
        """Share links carry voice and text, never images (#3867): the removal page and every pointer to it are gone."""
        self.assertFalse((SITE / "intimate-images").exists())
        sources = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
        server = ROOT / "research" / "B4" / "server"
        offenders = []
        for path in [*SITE.rglob("*.html"), ROOT / "scripts" / "voice_catalog.py", sources / "AppLinks.swift",
                     sources / "SettingsScreen.swift", server / "internal" / "links" / "preview.go"]:
            if re.search(r"intimate-images/|removing intimate images|intimateImageRemoval", text(path), re.IGNORECASE):
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [])

    def test_policy_and_form_keep_a_line_against_intimate_content_worded_for_what_we_carry(self):
        html = text(SITE / "content-policy" / "index.html")
        self.assertIn("Sexual or intimate content about a real person shared without their consent, including "
                      "recordings, text, and faked or altered voices.", html)
        # Nothing promises the 48-hour image process that was removed.
        self.assertNotIn("48 hours", html)
        form = text(ROOT / "research" / "B4" / "server" / "internal" / "links" / "preview.go")
        self.assertIn('<option value="intimate_images">Intimate content shared without consent</option>', form)
        self.assertNotIn("Intimate images shared", form)

    def test_pages_ask_emailers_to_leave_off_the_key(self):
        for name in PAGES:
            html = text(SITE / name / "index.html")
            self.assertRegex(html, r"Leave off everything after the <code>#</code> sign", name)

    def test_every_static_page_footer_links_to_the_content_policy(self):
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

    def test_app_settings_links_to_the_content_policy(self):
        sources = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
        links, settings = text(sources / "AppLinks.swift"), text(sources / "SettingsScreen.swift")
        for name, path in PAGES.items():
            self.assertIn(HOST + path, links)
        self.assertIn("AppLinks.contentPolicy", settings)


if __name__ == "__main__":
    unittest.main()
