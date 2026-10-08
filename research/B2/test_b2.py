"""Host tests for B2, offline against recorded responses in fixtures/.

  cd research/B2 && python3 -m unittest -v test_b2
"""

from __future__ import annotations

import inspect
import json
import re
import unittest
from pathlib import Path

import current_app
from current_app import CurrentApp, item_url_key
import fetcher as fetcher_module
from fetcher import Fetcher, FixtureMiss, fixture_path
from run_cases import item_references, run
from substack_resolver import (SubstackResolver, is_private_feed_url, page_is_paywalled, redact,
                               strip_tracking)

HERE = Path(__file__).resolve().parent
CASES = json.loads((HERE / "urls.json").read_text())["cases"]
REPO = HERE.parents[1]
COORDINATOR = REPO / "App/SpokenMarginsApp/Sources/SpokenMarginsApp/FollowedSourceCoordinator.swift"
FEED_PARSER = REPO / "Packages/SessionKit/Sources/SessionKitFeeds/FeedParser.swift"
PUBLIC_PODCAST = "https://api.substack.com/feed/podcast/69345.rss"
# Shape of the link a paid subscriber copies from Substack; the token here is fake.
FAKE_PRIVATE = "https://api.substack.com/feed/podcast/69345/private/0f0f0f0f-test-not-a-token.rss"


class AliasFetcher(Fetcher):
    """Replay fetcher that serves one recorded response under another URL."""

    def __init__(self, aliases: dict):
        super().__init__("replay")
        self.aliases = aliases

    def hop(self, url, kind):
        return super().hop(self.aliases.get(url, url), kind)


class TestSet(unittest.TestCase):
    def test_at_least_30_substack_urls_with_every_category(self):
        substack = [c for c in CASES if c["expect_feed"]]
        self.assertGreaterEqual(len(substack), 30)
        categories = " ".join(c["category"] for c in substack)
        for needed in ("tracking", "old post", "home page", "/feed link", "share link"):
            self.assertIn(needed, categories)
        self.assertTrue(any("substack.com" not in c["url"] for c in substack), "custom domains")

    def test_every_case_is_recorded(self):
        # Replaying the whole run raises FixtureMiss if any request was not recorded.
        run("replay")


class TestResolver(unittest.TestCase):
    rows = None

    @classmethod
    def setUpClass(cls):
        cls.rows = {r["id"]: r for r in run("replay")}

    def test_every_case_resolves_to_expected_feed(self):
        failures = {i: (r["resolver"] or {}).get("feed") for i, r in self.rows.items() if not r["resolver_ok"]}
        self.assertEqual(failures, {})

    def test_non_substack_sites_are_left_to_generic_discovery(self):
        self.assertIsNone(self.rows["control-ghost-site"]["resolver"])
        self.assertTrue(self.rows["control-ghost-site"]["following_tab"]["ok"])

    def test_profile_candidates_are_not_presented_as_certain(self):
        # lennysnewsletter.substack.com redirects to an unrelated person's profile.
        trap = self.rows["profile-subdomain-redirect"]["resolver"]
        self.assertLess(trap["confidence"], 0.9)
        self.assertIn("profile", trap["reason"])

    def test_old_and_tracked_posts_resolve_without_feed_membership(self):
        for case in ("post-custom-old-2022", "post-subdomain-old-utm", "post-custom-email-utm"):
            self.assertFalse(self.rows[case]["suggest_safari"]["ok"], case)  # today
            self.assertTrue(self.rows[case]["resolver_ok"], case)  # resolver


class TestTodayBaseline(unittest.TestCase):
    """Pins the failures the M1 fix must remove, so a stale table is noticed."""

    def setUp(self):
        self.app = CurrentApp(Fetcher("replay"))

    def test_tracking_query_breaks_membership(self):
        self.assertNotEqual(item_url_key("https://x.com/p/a?utm_source=substack"), item_url_key("https://x.com/p/a"))
        result = self.app.suggestion("https://www.astralcodexten.com/p/the-specter-of-neuralese"
                                     "?utm_source=substack&utm_medium=email&utm_content=share")
        self.assertFalse(result["ok"])
        self.assertIn("77-80", result["check"])

    def test_home_page_over_1mb_aborts_before_feed_heuristics(self):
        result = self.app.following_tab("https://www.thefp.com/")
        self.assertFalse(result["ok"])
        self.assertIn(":261", result["check"])

    def test_substack_app_share_links_find_nothing(self):
        result = self.app.following_tab("https://substack.com/home/post/p-210681369")
        self.assertFalse(result["ok"])

    def test_articles_never_get_manual_follow(self):
        self.assertFalse(CurrentApp.manual_button("text")[0])


class TestPortMatchesTheSwiftItEmulates(unittest.TestCase):
    """current_app.py is a hand-made Python copy of the app's discovery code, so it can
    drift without any test noticing: the "today" column of results.md is only as good
    as the copy. These read the Swift source and compare the numbers and lists the
    copy hard-codes. They do not cover the line numbers in the port's `check` strings,
    which are already stale, or the Follow button rules in Gate1AppModel.swift."""

    @classmethod
    def setUpClass(cls):
        if not COORDINATOR.exists() or not FEED_PARSER.exists():
            raise unittest.SkipTest("the app source is not next to research/B2")
        cls.swift = COORDINATOR.read_text()
        cls.feed_parser = FEED_PARSER.read_text()

    def find(self, pattern, text=None):
        match = re.search(pattern, self.swift if text is None else text)
        self.assertIsNotNone(match, f"the Swift no longer contains {pattern!r}")
        return match

    def test_same_origin_heuristic_paths(self):
        listed = self.find(r"for path in \[([^\]]*)\] \{").group(1)
        self.assertEqual(re.findall(r'"([^"]+)"', listed), current_app.HEURISTIC_PATHS)

    def test_html_and_feed_size_limits(self):
        megabytes = int(self.find(r"data\.count <= (\d+) \* 1_024 \* 1_024 else \{ throw FollowedSourceError\.htmlResponseTooLarge").group(1))
        self.assertEqual(megabytes * 1024 * 1024, current_app.MAX_HTML_BYTES)
        megabytes = int(self.find(r"defaultMaximumBytes = (\d+) \* 1_024 \* 1_024", self.feed_parser).group(1))
        self.assertEqual(megabytes * 1024 * 1024, current_app.MAX_FEED_BYTES)

    def test_candidate_limit_and_redirect_limit(self):
        swift_limit = self.find(r"evidence\.prefix\((\d+)\)").group(1)
        self.assertIn(f"evidence[:{swift_limit}]", inspect.getsource(CurrentApp.discover))
        self.assertEqual(int(self.find(r"BoundedRedirectDelegate\(maximumRedirects: (\d+)\)").group(1)),
                         fetcher_module.MAX_REDIRECTS)

    def test_item_url_key_drops_only_the_fragment_and_case(self):
        body = self.find(r"(?s)private static func itemURLKey\(_ raw: String\?\) -> String\? \{(.*?)\n    \}", None).group(1)
        body = re.sub(r"//.*", "", body)  # a commented-out line must not count
        self.assertIn("url.fragment = nil", body)
        self.assertIn("url.host = url.host?.lowercased()", body)
        self.assertIn("url.scheme = url.scheme?.lowercased()", body)
        self.assertNotIn("query", body)  # tracking parameters are kept, which is why they break membership
        self.assertNotEqual(item_url_key("https://X.com/p/a?r=1#frag"), item_url_key("https://x.com/p/a"))
        self.assertEqual(item_url_key("https://X.com/p/a?r=1#frag"), "https://x.com/p/a?r=1")

    def test_only_https_is_discovered(self):
        self.find(r'guard url\.scheme\?\.lowercased\(\) == "https", let host = url\.host\?\.lowercased\(\) else \{ throw FollowedSourceError\.insecureURL \}')
        with self.assertRaises(current_app.FollowError):
            CurrentApp(Fetcher("replay")).discover("http://example.com/")


class TestPaidAccessPrototype(unittest.TestCase):
    def test_private_feed_links_are_recognised_and_redacted(self):
        self.assertTrue(is_private_feed_url(FAKE_PRIVATE))
        self.assertFalse(is_private_feed_url(PUBLIC_PODCAST))
        self.assertFalse(is_private_feed_url("https://www.astralcodexten.com/feed"))
        self.assertNotIn("test-not-a-token", redact(FAKE_PRIVATE))

    def test_private_feed_becomes_private_candidate_without_leaking_token(self):
        fetcher = AliasFetcher({FAKE_PRIVATE: PUBLIC_PODCAST})
        candidate = SubstackResolver(fetcher).resolve(FAKE_PRIVATE)
        self.assertIsNotNone(candidate)
        self.assertTrue(candidate.private)
        self.assertEqual(candidate.kind, "substack_private_feed")
        self.assertGreater(candidate.audio_items, 0)
        self.assertNotIn("test-not-a-token", candidate.reason)

    def test_paywalled_capture_is_detected(self):
        fetcher = Fetcher("replay")
        paid = next(c for c in CASES if c["id"] == "post-paid-truncated")["url"]
        self.assertTrue(page_is_paywalled(fetcher.get(paid, "html").body))
        free = next(c for c in CASES if c["id"] == "post-custom-clean")["url"]
        self.assertFalse(page_is_paywalled(fetcher.get(free, "html").body))

    def test_strip_tracking_keeps_meaningful_query(self):
        self.assertEqual(strip_tracking("https://x.com/p/a?utm_source=s&r=1&page=2#f"), "https://x.com/p/a?page=2")


class TestReplayIsOffline(unittest.TestCase):
    def test_unrecorded_url_is_a_miss_not_a_network_call(self):
        with self.assertRaises(FixtureMiss):
            Fetcher("replay").get("https://unrecorded.example/", "html")
        self.assertFalse(fixture_path("https://unrecorded.example/", "html").exists())


if __name__ == "__main__":
    unittest.main()
