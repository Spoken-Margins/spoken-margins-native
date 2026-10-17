"""The bundled starter-podcast list is built from each show's own feed (#1732): no Apple chart data and no
Apple-hosted artwork, and it still fills the first-run drawer."""
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlsplit

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
CATALOG = ROOT / "Site/onboarding/catalog/v1/catalog.json"
MANIFEST = ROOT / "Site/onboarding/catalog/v1/manifest.json"
B1 = ROOT / "research/B1"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


contracts = load("validate_contracts", SCRIPTS / "validate-contracts.py")
builder = load("build_catalog", B1 / "build_catalog.py")


def published():
    return json.loads(CATALOG.read_text(encoding="utf-8"))


class NoAppleDataTests(unittest.TestCase):
    def errors_for(self, catalog):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "catalog.json"
            path.write_text(json.dumps(catalog), encoding="utf-8")
            return contracts.validate_no_apple_data(path)

    def test_the_published_catalog_has_no_apple_data(self):
        self.assertEqual(contracts.validate_no_apple_data(CATALOG), [])
        self.assertIn((MANIFEST, CATALOG), contracts.SOURCE_CATALOG_PAIRS)
        self.assertEqual(contracts.PUBLISHED_CATALOG, CATALOG)
        # The contracts step runs the same check on the published pair.
        self.assertEqual(contracts.validate_source_catalog_pair(MANIFEST, CATALOG, published=True), [])

    def test_no_artwork_feed_or_website_url_points_at_apple(self):
        for entry in published()["entries"]:
            for field in ("feedURL", "artworkURL", "websiteURL"):
                host = (urlsplit(entry.get(field, "")).hostname or "").lower()
                self.assertFalse(host.endswith("mzstatic.com") or host.endswith("apple.com"), f"{entry['id']} {field}: {host}")

    def test_apple_hosts_are_told_from_neighbours(self):
        for url, expected in (
            ("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb.jpg", True),
            ("https://IS5-SSL.MZSTATIC.COM/a.jpg", True),
            ("https://mzstatic.com/a.jpg", True),
            ("https://podcasts.apple.com/us/podcast/id1", True),
            ("https://apple.com/x", True),
            ("https://itunes.apple.com/lookup?id=1", True),
            ("https://apple.co/abc", True),
            ("https://a1.aaplimg.com/x.jpg", True),
            ("https://cvws.icloud-content.com/x", False),
            ("https://www.icloud.com/x.jpg", True),
            ("https://apple.dwarkesh-podcast.workers.dev/feed.rss", False),
            ("https://notapple.com/a.jpg", False),
            ("https://apple.com.example.org/a.jpg", False),
            ("https://example.org/mzstatic.com/a.jpg", False),
            ("https://image.simplecastcdn.com/images/a/3000x3000/art.jpg", False),
            ("", False),
        ):
            with self.subTest(url=url):
                self.assertEqual(contracts.is_apple_url(url), expected)
                self.assertEqual(builder.is_apple_url(url), expected)
        self.assertEqual(contracts.APPLE_HOST_SUFFIXES, builder.APPLE_HOST_SUFFIXES)

    def test_each_kind_of_apple_data_is_caught(self):
        base = published()
        self.assertEqual(self.errors_for(base), [])

        def with_entry(**changes):
            catalog = copy.deepcopy(base)
            catalog["entries"][0].update(changes)
            return catalog

        cases = {
            "artwork": with_entry(artworkURL="https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg"),
            "feed": with_entry(feedURL="https://podcasts.apple.com/feed"),
            "website": with_entry(websiteURL="https://podcasts.apple.com/us/podcast/id1"),
            "chart rank": with_entry(chartPositions=[{"provenanceId": "hand-picked-shows", "rank": 1}]),
            "apple id": with_entry(externalIds={"applePodcastsId": "1200361736"}),
        }
        chart = copy.deepcopy(base)
        chart["provenance"].append({"id": "apple-top-us-news", "kind": "apple_top_chart", "fetchedAt": base["generatedAt"]})
        cases["chart provenance"] = chart
        lookup = copy.deepcopy(base)
        lookup["provenance"].append({"id": "itunes-lookup", "kind": "itunes_lookup", "fetchedAt": base["generatedAt"]})
        cases["lookup provenance"] = lookup
        named = copy.deepcopy(base)
        named["entries"][0]["id"] = "apple-1200361736"
        cases["apple id in entry id"] = named
        dated = copy.deepcopy(base)
        dated["provenance"][0]["chartUpdatedAt"] = "2026-09-28T05:17:56-07:00"
        cases["chart date"] = dated
        genre = copy.deepcopy(base)
        genre["subjects"][0]["appleGenreId"] = 1489
        cases["genre id"] = genre
        for name, catalog in cases.items():
            with self.subTest(name):
                self.assertTrue(self.errors_for(catalog), f"{name} went unnoticed")

    def test_the_catalog_this_replaced_would_have_failed(self):
        # The chart-built catalog (contentVersion 2): 192 shows with artwork on Apple's image server.
        old = {"provenance": [{"id": "apple-top-us-news", "kind": "apple_top_chart", "fetchedAt": "2026-09-28T12:19:01Z"}],
               "subjects": [{"id": "news", "title": "News", "appleGenreId": 1489}],
               "entries": [{"id": "apple-1200361736", "feedURL": "https://feeds.simplecast.com/Sl5CSM3S",
                            "artworkURL": "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/ab/64/mza.jpg/600x600bb.jpg",
                            "chartPositions": [{"provenanceId": "apple-top-us-news", "rank": 1}],
                            "externalIds": {"applePodcastsId": "1200361736"}}]}
        self.assertEqual(len(self.errors_for(old)), 6)


class PublishedStarterListTests(unittest.TestCase):
    """The first-run drawer's bar (SourceCatalogTests): a full list, artwork on every tile, explicit shows hidden."""

    def test_the_drawer_still_has_a_full_starter_list(self):
        catalog = published()
        offered = [e for e in catalog["entries"] if e.get("explicit") is not True]
        self.assertGreaterEqual(len([e for e in offered if e["kind"] == "podcast_feed"]), 100)
        self.assertTrue(any(e.get("explicit") for e in catalog["entries"]), "the explicit-show filter (#544) needs some to hide")
        for subject in catalog["subjects"]:
            with self.subTest(subject=subject["id"]):
                self.assertGreaterEqual(len([e for e in offered if subject["id"] in e["subjects"]]), 5)
        for entry in catalog["entries"]:
            self.assertTrue(entry["artworkURL"].startswith("https://"), entry["id"])
            self.assertTrue(entry["feedURL"].startswith("https://"), entry["id"])
        known = {e["id"] for e in catalog["entries"]}
        for row in catalog["starterRows"]:
            self.assertTrue(row["entryIds"], row["subjectId"])
            self.assertTrue(set(row["entryIds"]) <= known, row["subjectId"])
            self.assertEqual(len(row["entryIds"]), len(set(row["entryIds"])))

    def test_every_show_is_one_the_list_names_and_every_entry_says_where_it_came_from(self):
        catalog = published()
        config = json.loads((B1 / "shows.json").read_text(encoding="utf-8"))
        names = {builder.https_form(s["feed"]) for s in config["shows"]}
        self.assertEqual({e["feedURL"] for e in catalog["entries"]}, names - self.dropped())
        provenance = {p["id"] for p in catalog["provenance"]}
        self.assertEqual(provenance, {"hand-picked-shows", "publisher-feeds"})
        for entry in catalog["entries"]:
            self.assertEqual(set(entry["provenanceIds"]), provenance)

    @staticmethod
    def dropped():
        report = json.loads((B1 / "last-build-report.json").read_text(encoding="utf-8"))
        return {item["feed"] for item in report["dropped"]}

    def test_the_shows_file_is_well_formed(self):
        config = json.loads((B1 / "shows.json").read_text(encoding="utf-8"))
        subjects = {s["id"] for s in config["subjects"]}
        feeds = [builder.https_form(s["feed"]).rstrip("/").lower() for s in config["shows"]]
        self.assertEqual(len(feeds), len(set(feeds)), "a feed is listed twice")
        for show in config["shows"]:
            with self.subTest(show=show["name"]):
                self.assertTrue(show["feed"].startswith(("https://", "http://")))
                self.assertFalse(builder.is_apple_url(show["feed"]))
                self.assertFalse(builder.looks_private(show["feed"]))
                self.assertTrue(show["subjects"] and set(show["subjects"]) <= subjects)

    def test_the_build_script_rebuilds_the_published_list_from_the_recorded_feeds(self):
        recorded = sorted((B1 / "recorded").iterdir())
        self.assertTrue(recorded, "the feed heads the list was built from are kept so it can be rebuilt offline")
        version = published()["contentVersion"]
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            status = builder.main(["--replay", f"recorded/{recorded[-1].name}", "--content-version", str(version), "--out", str(out)])
            self.assertEqual(status, 0)
            self.assertEqual((out / "catalog.json").read_bytes(), CATALOG.read_bytes())
            self.assertEqual((out / "manifest.json").read_text(), MANIFEST.read_text())


class FeedReadingTests(unittest.TestCase):
    HEAD = """<?xml version="1.0"?><rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom" version="2.0"><channel>
<title><![CDATA[Sample &amp; Show]]></title><link>http://example.org/show</link>
<atom:link href="https://example.org/feed" rel="self"/>
<description><![CDATA[<p>Hello   <b>there</b>.</p>]]></description>
<itunes:author>Sam Pull</itunes:author><itunes:explicit>{explicit}</itunes:explicit>
<itunes:image href="{image}"/><image><url>https://example.org/channel.png</url><title>Sample</title></image>
"""

    def parse(self, explicit="true", image="https://example.org/art.jpg"):
        return builder.parse_channel(self.HEAD.format(explicit=explicit, image=image))

    def test_title_author_summary_website_and_explicit_come_from_the_feed(self):
        meta = self.parse()
        self.assertEqual(meta["title"], "Sample & Show")
        self.assertEqual(meta["author"], "Sam Pull")
        self.assertEqual(meta["summary"], "Hello there.")
        self.assertEqual(meta["website"], "http://example.org/show")
        self.assertEqual(meta["explicit"], "true")
        self.assertEqual(meta["artwork"], ["https://example.org/art.jpg", "https://example.org/channel.png"])

    def test_artwork_on_apple_servers_is_never_a_candidate(self):
        # The build keeps https non-Apple candidates only; the first survivor is checked and used.
        candidates = self.parse(image="http://is1-ssl.mzstatic.com/a.jpg")["artwork"]
        self.assertEqual(builder.artwork_candidates(candidates), ["https://example.org/channel.png"])
        self.assertEqual(builder.artwork_candidates(["", "https://podcasts.apple.com/a.png", "http://example.org/b.png"]),
                         ["https://example.org/b.png"])

    def test_http_artwork_is_used_over_https(self):
        self.assertEqual(builder.https_form("http://example.org/a.jpg"), "https://example.org/a.jpg")
        self.assertEqual(builder.https_form("https://example.org/a.jpg"), "https://example.org/a.jpg")

    def test_a_head_that_will_not_parse_falls_back_to_the_tags(self):
        meta = builder.parse_channel("<rss><channel><title>Plain</title><itunes:author>A &amp; B</itunes:author>"
                                     "<itunes:image href='https://example.org/x.jpg'/>")
        self.assertEqual((meta["title"], meta["author"], meta["artwork"]), ("Plain", "A & B", ["https://example.org/x.jpg"]))

    def test_explicit_flags_read_the_way_feeds_spell_them(self):
        for flag, expected in (("true", True), ("Yes", True), (" explicit ", True), ("false", False), ("no", False),
                               ("clean", False), ("", False)):
            with self.subTest(flag=flag):
                self.assertEqual(builder.is_explicit(flag), expected)

    def test_an_author_address_is_never_published(self):
        meta = builder.parse_channel("<rss xmlns:itunes='http://www.itunes.com/dtds/podcast-1.0.dtd'><channel><title>T</title>"
                                     "<itunes:author>bob@example.com (Bob)</itunes:author></channel></rss>")
        self.assertEqual(meta["author"], "")

    def test_a_cdata_title_survives_the_fallback_parser(self):
        meta = builder.parse_channel("<rss><channel><title><![CDATA[Cdata & Co]]></title><itunes:author>X")
        self.assertEqual(meta["title"], "Cdata & Co")

    def test_ids_do_not_end_in_a_hyphen(self):
        self.assertEqual(builder.slug("Young and Profiting (YAP) with Hala Taha: Entrepreneurship and Self-Improvement Podcast"),
                         "young-and-profiting-yap-with-hala-taha-entrepreneurship-and")

    def test_long_descriptions_are_cut_at_a_word(self):
        text = "word " * 200
        cut = builder.shorten(text.strip(), 300)
        self.assertLessEqual(len(cut), 301)
        self.assertTrue(cut.endswith("word…"))
        self.assertEqual(builder.shorten("short", 300), "short")


if __name__ == "__main__":
    unittest.main()
