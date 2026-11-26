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
        self.assertEqual(len(self.errors_for(old)), 5)


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
        # Pack shows (#4285) not in shows.json join the list only when a pack uses them.
        pack_feeds = {builder.https_form(item["feed"]) for pack in json.loads((B1 / "packs.json").read_text())["packs"]
                      for kind in builder.PACK_LISTS for item in pack[kind] if item.get("feed")}
        used = {e["feedURL"] for e in catalog["entries"] if any(e["id"] in p["entryIds"] for p in catalog["packs"])}
        self.assertEqual({e["feedURL"] for e in catalog["entries"]}, (names - self.dropped()) | (pack_feeds & used))
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


class PublishedPacksTests(unittest.TestCase):
    """The eight persona packs (#4285, Design PR 5) as the first-run drawer gets them."""

    def test_eight_packs_each_with_five_to_twelve_offered_sources(self):
        catalog = published()
        entries = {e["id"]: e for e in catalog["entries"]}
        self.assertEqual(len(catalog["packs"]), 8)
        self.assertEqual(len({p["id"] for p in catalog["packs"]}), 8)
        for pack in catalog["packs"]:
            with self.subTest(pack=pack["id"]):
                self.assertTrue(5 <= len(pack["entryIds"]) <= 12)
                self.assertLessEqual(len(pack["title"]), 40)
                self.assertLessEqual(len(pack["summary"]), 90)
                sources = [entries[i] for i in pack["entryIds"]]
                self.assertFalse(any(s["explicit"] for s in sources))
                kinds = [s["contentKind"] for s in sources]
                self.assertEqual(kinds, sorted(kinds, key=lambda k: k != "podcast"), "podcasts come before newsletters")
                self.assertIn("podcast", kinds)
                for source in sources:
                    self.assertGreaterEqual(len(source.get("recentPublishedAt", [])), 2, source["id"])

    def test_pack_dates_are_utc_newest_first_and_never_after_the_build(self):
        catalog = published()
        for entry in catalog["entries"]:
            dates = entry.get("recentPublishedAt")
            if dates is None:
                continue
            with self.subTest(entry=entry["id"]):
                self.assertLessEqual(len(dates), 20)
                self.assertTrue(all(d.endswith("Z") for d in dates))
                self.assertEqual(dates, sorted(dates, reverse=True))

    def test_new_pack_newsletters_are_writers_and_podcasts_take_their_packs_subjects(self):
        catalog = published()
        config = json.loads((B1 / "shows.json").read_text(encoding="utf-8"))
        listed = {builder.feed_key(s["feed"]) for s in config["shows"]}
        packs = json.loads((B1 / "packs.json").read_text())["packs"]
        for entry in catalog["entries"]:
            if builder.feed_key(entry["feedURL"]) in listed:
                continue
            with self.subTest(entry=entry["id"]):
                if entry["contentKind"] == "newsletter":
                    self.assertEqual(entry["subjects"], ["writers"])
                    self.assertEqual(entry["kind"], "article_feed")
                else:
                    expected = []
                    for pack in packs:
                        if any(entry["id"] in p["entryIds"] for p in catalog["packs"] if p["id"] == pack["id"]):
                            expected += [s for s in pack["subjects"] if s not in expected]
                    self.assertEqual(entry["subjects"], expected)


class FeedDatesTests(unittest.TestCase):
    """feed_dates reads up to 20 items for publish dates, since feed_head stops at the first one."""

    def item(self, date_tag="pubDate", date="Mon, 16 Nov 2026 10:00:00 -0500", enclosure='type="audio/mpeg"'):
        enclosure_tag = f'<enclosure url="https://example.org/a.bin" {enclosure}/>' if enclosure else ""
        date_part = f"<{date_tag}>{date}</{date_tag}>" if date_tag else ""
        return f"<item><title>T</title>{date_part}{enclosure_tag}</item>"

    def test_dates_are_read_the_way_feeds_spell_them(self):
        for tag, raw, expected in (
            ("pubDate", "Mon, 16 Nov 2026 10:00:00 -0500", "2026-11-16T15:00:00Z"),
            ("pubDate", "Mon, 16 Nov 2026 10:00:00 GMT", "2026-11-16T10:00:00Z"),
            ("pubDate", "<![CDATA[Mon, 16 Nov 2026 10:00:00 +0000]]>", "2026-11-16T10:00:00Z"),
            ("pubDate", "  Mon, 16 Nov 2026 10:00:00 +0000\n", "2026-11-16T10:00:00Z"),
            ("published", "2026-11-16T10:00:00Z", "2026-11-16T10:00:00Z"),
            ("published", "2026-11-16T10:00:00.250+01:00", "2026-11-16T09:00:00Z"),
            ("updated", "2026-11-16T10:00:00-08:00", "2026-11-16T18:00:00Z"),
            ("dc:date", "2026-11-16T10:00:00Z", "2026-11-16T10:00:00Z"),
            ("published", "2026-11-16", "2026-11-16T00:00:00Z"),
        ):
            with self.subTest(tag=tag, raw=raw):
                text = "<rss><channel>" + self.item(tag, raw) + "</channel></rss>"
                self.assertEqual(builder.dates_from_feed(text)[0], [expected])

    def test_an_unreadable_or_missing_date_is_dropped(self):
        for tag, raw in (("pubDate", "sometime soon"), ("pubDate", ""), (None, None)):
            with self.subTest(raw=raw):
                text = "<rss>" + self.item(tag, raw) + self.item() + "</rss>"
                self.assertEqual(builder.dates_from_feed(text)[0], ["2026-11-16T15:00:00Z"])

    def test_only_the_first_twenty_items_count_and_dates_come_newest_first(self):
        items = "".join(self.item(date=f"{day:02d} Nov 2026 10:00:00 +0000") for day in (3, 1, 2) + tuple(range(4, 30)))
        dates, _ = builder.dates_from_feed("<rss>" + items + "</rss>")
        self.assertEqual(len(dates), 20)
        self.assertEqual(dates[0], "2026-11-20T10:00:00Z")
        self.assertEqual(dates[-1], "2026-11-01T10:00:00Z")
        self.assertEqual(dates, sorted(dates, reverse=True))

    def test_audio_is_told_by_type_or_file_name(self):
        for enclosure, expected in (('type="audio/mpeg"', True), ("type='AUDIO/x-m4a'", True),
                                    ('type="video/mp4"', False), ('type="image/jpeg"', False), (None, False)):
            with self.subTest(enclosure=enclosure):
                self.assertEqual(builder.dates_from_feed("<rss>" + self.item(enclosure=enclosure) + "</rss>")[1], expected)
        by_name = '<item><enclosure url="https://example.org/ep.mp3?x=1" length="1"/></item>'
        self.assertTrue(builder.dates_from_feed("<rss>" + by_name + "</rss>")[1])

    def test_an_atom_entry_with_both_dates_uses_published(self):
        text = ("<feed><entry><updated>2026-11-20T00:00:00Z</updated><published>2026-11-01T00:00:00Z</published>"
                "</entry></feed>")
        self.assertEqual(builder.dates_from_feed(text)[0], ["2026-11-01T00:00:00Z"])


class PackChoiceTests(unittest.TestCase):
    """The replacement rule (#4285 PR 4) on a small recorded build: a failed candidate gives way to the next
    usable alternate of the same kind only, and new pack shows take the union of their packs' subjects."""

    BUILT = "2026-11-20T12:00:00Z"
    FRESH = ["2026-11-19T10:00:00Z", "2026-11-12T10:00:00Z", "2026-11-05T10:00:00Z"]

    def head(self, title, explicit="false", art=True):
        image = f'<itunes:image href="https://example.org/{title}.jpg"/>' if art else ""
        return (f'<?xml version="1.0"?><rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
                f"<title>{title}</title><itunes:author>{title} people</itunes:author>"
                f"<itunes:explicit>{explicit}</itunes:explicit>{image}")

    def build(self, feeds, packs, shows=()):
        """feeds: {name: dict(head kwargs + dates/audio/status)}; returns (catalog, report)."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "rec" / "feeds").mkdir(parents=True)
        log = {"feeds": {}, "artwork": {}, "dates": {}}
        for name, spec in feeds.items():
            url = f"https://example.org/{name}.rss"
            (root / "rec" / "feeds" / f"{name}.xml").write_text(
                self.head(name, spec.get("explicit", "false"), spec.get("art", True)))
            log["feeds"][url] = {"url": url, "status": 200, "finalURL": url, "looksLikeFeed": True,
                                 "fetchedAt": self.BUILT, "file": f"{name}.xml"}
            log["artwork"][f"https://example.org/{name}.jpg"] = {"ok": True}
            log["dates"][url] = {"url": url, "status": spec.get("status", 200), "dates": spec.get("dates", self.FRESH),
                                 "audio": spec.get("audio", True)}
        (root / "rec" / "fetch-log.json").write_text(json.dumps(log))
        subjects = [{"id": s, "title": s} for s in ("science", "history", "health-fitness", "writers")]
        (root / "shows.json").write_text(json.dumps({"subjects": subjects, "shows": [
            {"name": n, "id": f"listed-{n}", "feed": f"https://example.org/{n}.rss", "subjects": ["science"]} for n in shows]}))
        (root / "packs.json").write_text(json.dumps({"packs": packs}))
        out = root / "out"
        status = builder.main(["--replay", str(root / "rec"), "--content-version", "9", "--out", str(out),
                               "--shows", str(root / "shows.json"), "--packs", str(root / "packs.json")])
        self.assertEqual(status, 0)
        return json.loads((out / "catalog.json").read_text()), json.loads((out / "build-report.json").read_text())

    @staticmethod
    def pack(pid, podcasts, alternates=(), newsletters=(), newsletter_alternates=(), subjects=("science",)):
        item = lambda n: {"title": n.title(), "feed": f"https://example.org/{n}.rss"} if not n.startswith("nofeed") \
            else {"title": n}
        return {"id": pid, "title": pid.title(), "summary": "For testing.", "subjects": list(subjects),
                "podcasts": [item(n) for n in podcasts], "podcastAlternates": [item(n) for n in alternates],
                "newsletters": [item(n) for n in newsletters], "newsletterAlternates": [item(n) for n in newsletter_alternates]}

    def ids(self, catalog, pid):
        titles = {e["id"]: e["title"] for e in catalog["entries"]}
        return [titles[i] for i in next(p for p in catalog["packs"] if p["id"] == pid)["entryIds"]]

    def test_each_failure_is_replaced_in_place_by_the_next_usable_alternate(self):
        feeds = {n: {} for n in ("p1", "p2", "p3", "p4", "p5", "a1", "a2", "a3", "n1", "na1")}
        feeds["p2"] = {"explicit": "true"}
        feeds["p3"] = {"dates": ["2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z"]}     # nothing in the last 60 days
        feeds["a1"] = {"audio": False}                                                  # not a podcast
        feeds["p5"] = {"art": False}
        catalog, report = self.build(feeds, [self.pack("one", ["p1", "p2", "p3", "nofeed", "p4", "p5"], ["a1", "a2", "a3"],
                                                       ["n1"], ["na1"])])
        self.assertEqual(self.ids(catalog, "one"), ["p1", "a2", "a3", "p4", "n1"])
        whys = [(r["replaced"], r["why"], r["by"]) for r in report["packReplacements"]]
        self.assertEqual(whys, [("P2", "explicit", "A2"), ("P3", "no item in the 60 days before the build", "A3"),
                                ("nofeed", "no publisher feed found", None), ("P5", "no usable artwork", None)])

    def test_a_podcast_is_never_replaced_by_a_newsletter_or_the_other_way(self):
        feeds = {n: {} for n in ("p1", "p2", "p3", "p4", "n1", "n2", "na1")}
        feeds["p4"] = {"status": 404}
        feeds["n2"] = {"dates": []}
        catalog, report = self.build(feeds, [self.pack("one", ["p1", "p2", "p3", "p4"], [], ["n1", "n2"], ["na1"])])
        # p4 has no podcast alternate, so the spare newsletter alternate only fills n2's place.
        self.assertEqual(self.ids(catalog, "one"), ["p1", "p2", "p3", "n1", "na1"])
        kinds = {e["title"]: e["contentKind"] for e in catalog["entries"]}
        self.assertEqual(kinds["na1"], "newsletter")
        self.assertIn(("P4", None), [(r["replaced"], r["by"]) for r in report["packReplacements"]])

    def test_a_pack_left_with_fewer_than_five_sources_does_not_ship(self):
        feeds = {n: {} for n in ("p1", "p2", "p3", "n1")}
        catalog, report = self.build(feeds, [self.pack("small", ["p1", "p2", "p3", "nofeed"], [], ["n1"])])
        self.assertNotIn("packs", catalog)
        self.assertEqual(report["packs"], {})
        self.assertEqual(report["packReplacements"][-1]["replaced"], "the whole pack")
        self.assertEqual(len(catalog["entries"]), 0, "no pack, so its shows don't join the list")

    def test_new_shows_take_the_union_of_their_packs_subjects_and_listed_shows_keep_theirs(self):
        feeds = {n: {} for n in ("p1", "p2", "p3", "p4", "shared", "listed", "n1", "spare")}
        packs = [self.pack("one", ["p1", "p2", "shared", "listed"], ["spare"], ["n1"], subjects=("science",)),
                 self.pack("two", ["p3", "p4", "shared", "listed"], [], ["n1"], subjects=("history", "science"))]
        catalog, _ = self.build(feeds, packs, shows=["listed"])
        entries = {e["title"]: e for e in catalog["entries"]}
        self.assertEqual(entries["shared"]["subjects"], ["science", "history"])
        self.assertEqual(entries["p3"]["subjects"], ["history", "science"])
        self.assertEqual(entries["listed"]["subjects"], ["science"])
        self.assertEqual(entries["listed"]["id"], "listed-listed", "a listed show keeps its entry; the pack names its id")
        self.assertEqual(entries["n1"]["subjects"], ["writers"])
        self.assertNotIn("spare", entries, "an unused alternate never joins the list")
        self.assertEqual(entries["shared"]["recentPublishedAt"], self.FRESH)
        self.assertNotIn("recentPublishedAt", {k for e in catalog["entries"] if e["title"] == "spare" for k in e})

    def test_replay_rebuilds_the_same_bytes(self):
        feeds = {n: {} for n in ("p1", "p2", "p3", "p4", "n1")}
        first, _ = self.build(feeds, [self.pack("one", ["p1", "p2", "p3", "p4"], [], ["n1"])])
        second, _ = self.build(feeds, [self.pack("one", ["p1", "p2", "p3", "p4"], [], ["n1"])])
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
