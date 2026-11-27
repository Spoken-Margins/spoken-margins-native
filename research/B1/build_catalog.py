#!/usr/bin/env python3
"""Build the onboarding starter-podcast catalog snapshot (stream B1, seam I2).

The list of shows is hand-picked in research/B1/shows.json: a feed URL, the
subjects it belongs to, and whether it leads its subject's starter row. Each
show's title, author, description, explicit flag, website and artwork URL are
read from that show's own RSS feed. Nothing comes from Apple's charts or
lookup API, and artwork that points at Apple's image servers is never used
(#1732, docs/legal/attorney-questions.md D13).

The head of every feed (everything before its first <item>) and every artwork
check is recorded under research/B1/recorded/<date>/, so the snapshot can be
rebuilt offline (--replay) and audited later.

Persona packs (#4285) come from research/B1/packs.json: for each pack, its
podcasts and newsletters in order, with same-kind alternates. A pack show not
already in shows.json becomes an entry; a candidate whose feed doesn't
resolve, is explicit, has no artwork of its own, has no item in the 60 days
before generatedAt or (for a podcast) carries no audio is replaced by the next
alternate of its kind. Every pack source also gets up to 20 recent publish
dates (recentPublishedAt), which the phone counts to show a pace. The dates
read from each feed are recorded in the fetch log, so --replay still rebuilds
the catalog byte for byte.

Usage:
  .venv/bin/python research/B1/build_catalog.py --content-version 3        # live fetch
  .venv/bin/python research/B1/build_catalog.py --replay recorded/<date>   # offline
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import email.utils
import hashlib
import html
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SITE_DIR = ROOT / "Site" / "onboarding" / "catalog" / "v1"
SHOWS_FILE = HERE / "shows.json"
PACKS_FILE = HERE / "packs.json"
CATALOG_BASE_URL = "https://spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/"

USER_AGENT = "SpokenMarginsCatalogResearch/2 (+https://spokenmargins.proximitytoprogress.com)"
FEED_HEAD_LIMIT = 512 * 1024   # bytes read from a feed while looking for its first <item>
SUMMARY_LIMIT = 300            # characters of a feed's description kept (the schema allows 600)
FEED_DATES_LIMIT = 2 * 1024 * 1024  # bytes read from a pack source's feed for its recent publish dates
RECENT_DATES = 20              # newest publish dates kept per pack source (the schema allows 20)
PACK_FRESH_DAYS = 60           # a pack source with no item this long before generatedAt is replaced
PACK_MIN_SOURCES = 5           # a pack ships only with at least this many sources

# Hosts the catalog must never point at. Apple's image servers carry artwork
# whose terms need a link to Apple's store (#632).
APPLE_HOST_SUFFIXES = ("mzstatic.com", "apple.com", "apple.co", "itunes.com", "apple-dns.net", "aaplimg.com", "cdn-apple.com", "icloud.com")


def is_apple_url(url: str) -> bool:
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    return any(host == suffix or host.endswith("." + suffix) for suffix in APPLE_HOST_SUFFIXES)


# Catalogs never carry private feeds (#168). Mirrors ShareableLinkPolicy's host and
# query checks; its opaque-path check is left out because it flags public
# Amperwave feeds, whose paths end in 32 hex digits.
PRIVATE_HOST_SUFFIXES = ("patreon.com", "patreonusercontent.com", "supercast.com", "supercast.tech",
                         "supportingcast.fm", "memberful.com", "memberfulcontent.com")
CREDENTIAL_QUERY_FRAGMENTS = ("token", "auth", "key", "secret", "sig", "hash", "pass", "pwd",
                              "session", "credential", "jwt", "expire", "policy", "hmac", "access")


def looks_private(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    if parts.username or parts.password:
        return True
    if any(host == suffix or host.endswith("." + suffix) for suffix in PRIVATE_HOST_SUFFIXES):
        return True
    return any(any(f in name.lower() for f in CREDENTIAL_QUERY_FRAGMENTS)
               for name, _ in urllib.parse.parse_qsl(parts.query, keep_blank_values=True))


def fetch(url: str, *, limit: int | None = None, timeout: int = 25) -> tuple[int, bytes, str, str]:
    """(status, body, final URL, content type). Network errors come back as status 0."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(limit) if limit else response.read()
            return response.status, body, response.geturl(), response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as error:
        return error.code, b"", url, ""
    except Exception as error:  # network errors are recorded, not fatal
        return 0, str(error).encode(), url, ""


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower())[:60].strip("-") or "podcast"


def https_form(url: str) -> str:
    # App Transport Security blocks plain http, so a feed or image served over http is
    # used in its https form, which is checked before the show is kept.
    return "https://" + url[len("http://"):] if url.startswith("http://") else url


def feed_head(url: str) -> dict:
    """Read a feed until its first <item>/<entry> (or the byte limit) and keep the channel part."""
    status, body, final_url, _ = fetch(url, limit=FEED_HEAD_LIMIT, timeout=30)
    text = body.decode("utf-8", errors="replace") if status == 200 else ""
    match = re.search(r"<(item|entry)[\s>]", text)
    head = text[:match.start()] if match else text
    looks_like_feed = status == 200 and any(m in head.lower() for m in ("<rss", "<feed", "<channel"))
    return {"url": url, "status": status, "finalURL": final_url, "looksLikeFeed": looks_like_feed,
            "head": head, "fetchedAt": now_iso()}


def feed_key(url: str) -> str:
    """How two spellings of one feed URL are told to be the same (the shows.json duplicate check uses this too)."""
    return https_form(url).rstrip("/").lower()


def parse_feed_date(raw: str) -> dt.datetime | None:
    """An RSS <pubDate> (RFC 822) or an Atom <published>/<updated> (ISO 8601), as an aware UTC time; else None."""
    text = html.unescape(re.sub(r"<!\[CDATA\[(.*?)\]\]>", r"\1", raw or "", flags=re.S)).strip()
    if not text:
        return None
    try:
        parsed = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError):
        parsed = None
    if parsed is None:
        try:
            parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00").replace("z", "+00:00"))
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def iso_utc(moment: dt.datetime) -> str:
    return moment.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def dates_from_feed(text: str, limit: int = RECENT_DATES) -> tuple[list[str], bool]:
    """The newest `limit` publish dates of a feed's first `limit` items, newest first, and whether any of
    those items carries audio. An item's date is its <pubDate> or <published>, else its <updated>."""
    items = re.split(r"<(?:item|entry)[\s>]", text)[1:limit + 1]
    dates: list[dt.datetime] = []
    audio = False
    for item in items:
        found = None
        for tag in ("pubDate", "published", "updated", "dc:date"):
            match = re.search(rf"<{tag}[^>]*>(.*?)</{tag}>", item, re.S | re.I)
            if match and (found := parse_feed_date(match.group(1))):
                break
        if found:
            dates.append(found)
        for enclosure in re.findall(r"<enclosure\b[^>]*>", item, re.I):
            kind = re.search(r'type\s*=\s*["\']([^"\']*)', enclosure, re.I)
            href = re.search(r'url\s*=\s*["\']([^"\']*)', enclosure, re.I)
            if (kind and kind.group(1).lower().startswith("audio/")) or \
               (href and re.search(r"\.(mp3|m4a|aac|ogg|opus|wav)(\?|$)", href.group(1), re.I)):
                audio = True
    return [iso_utc(d) for d in sorted(dates, reverse=True)[:limit]], audio


def feed_dates(url: str) -> dict:
    """Read a pack source's feed (up to FEED_DATES_LIMIT) for its recent publish dates. Only the dates are
    recorded, not the body, so the recorded folder stays small."""
    status, body, final_url, _ = fetch(url, limit=FEED_DATES_LIMIT, timeout=40)
    dates, audio = dates_from_feed(body.decode("utf-8", errors="replace")) if status == 200 else ([], False)
    return {"url": url, "status": status, "finalURL": final_url, "dates": dates, "audio": audio, "fetchedAt": now_iso()}


def check_artwork(url: str) -> dict:
    status, body, final_url, content_type = fetch(url, limit=2048, timeout=25)
    magic = body[:3] == b"\xff\xd8\xff" or body[:4] == b"\x89PNG" or (body[:4] == b"RIFF" and body[8:12] == b"WEBP") or body[:3] == b"GIF"
    # An image that redirected to Apple's servers is still Apple's image.
    ok = status == 200 and not is_apple_url(final_url) and (content_type.lower().startswith("image/") or magic)
    return {"url": url, "status": status, "finalURL": final_url, "contentType": content_type, "ok": ok}


def plain_text(raw: str | None) -> str:
    if not raw:
        return ""
    raw = re.sub(r"<!\[CDATA\[(.*?)\]\]>", r"\1", raw, flags=re.S)
    text = re.sub(r"</?(?:br|p|div|li|ul|ol|h\d)\b[^>]*>", " ", html.unescape(raw), flags=re.I)  # block tags break words
    text = re.sub(r"<[^>]+>", "", text)                                                    # inline tags don't
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def shorten(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0].rstrip(" ,;:-")
    return cut + "…"


def parse_channel(head: str) -> dict:
    """Title, author, summary, website, explicit flag and artwork candidates from a feed's head."""
    meta: dict = {"artwork": []}
    root = None
    try:
        # The head stops before the first <item>; close what is still open so it parses.
        closers = "</channel></rss>" if "<channel" in head and "</channel>" not in head else ""
        root = ET.fromstring(head + closers) if head.lstrip().startswith("<") else None
    except ET.ParseError:
        root = None
    if root is not None:
        channel = root.find("channel")
        if channel is None:
            channel = root
        def text_of(*names: str) -> str:
            for name in names:
                node = channel.find(name)
                if node is not None and (node.text or "").strip():
                    return node.text.strip()
            return ""
        meta["title"] = plain_text(text_of("title", "{*}title"))
        meta["author"] = plain_text(text_of("{*}author"))
        meta["summary"] = plain_text(text_of("{*}summary", "description", "{*}subtitle"))
        meta["website"] = text_of("link")
        meta["explicit"] = text_of("{*}explicit").lower()
        for node in channel.findall("{*}image"):
            href = node.get("href")
            if href:
                meta["artwork"].append(href.strip())
            url_node = node.find("url")
            if url_node is not None and (url_node.text or "").strip():
                meta["artwork"].append(url_node.text.strip())
    else:
        def first(pattern: str) -> str:
            found = re.search(pattern, head, re.S | re.I)
            return found.group(1).strip() if found else ""
        meta["title"] = plain_text(first(r"<title[^>]*>(.*?)</title>"))
        meta["author"] = plain_text(first(r"<itunes:author[^>]*>(.*?)</itunes:author>"))
        meta["summary"] = plain_text(first(r"<description[^>]*>(.*?)</description>"))
        meta["website"] = first(r"<link[^>]*>(https?://[^<]+)</link>")
        meta["explicit"] = first(r"<itunes:explicit[^>]*>(.*?)</itunes:explicit>").lower()
        meta["artwork"] = re.findall(r"<itunes:image[^>]*href=[\"']([^\"']+)[\"']", head, re.I)
    # A feed's author field sometimes holds "name@example.com (Name)"; never publish an address.
    if "@" in meta.get("author", ""):
        meta["author"] = ""
    return meta


def is_explicit(flag: str) -> bool:
    return flag.strip().lower() in ("true", "yes", "explicit")


def artwork_candidates(urls: list[str]) -> list[str]:
    """The artwork URLs a build may use, in the feed's order: https, and never on Apple's servers."""
    return [https_form(u) for u in urls if u and not is_apple_url(https_form(u))]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--replay", help="recorded directory (relative to research/B1) to rebuild from without network")
    parser.add_argument("--content-version", type=int, required=True, help="bump on every published change; apps keep the higher version")
    parser.add_argument("--out", type=Path, default=SITE_DIR, help="where catalog.json and manifest.json go (default: Site/onboarding/catalog/v1)")
    parser.add_argument("--shows", type=Path, default=SHOWS_FILE, help=argparse.SUPPRESS)
    parser.add_argument("--packs", type=Path, default=PACKS_FILE, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    config = json.loads(args.shows.read_text())
    shows = config["shows"]
    subject_ids = {s["id"] for s in config["subjects"]}
    packs_config = json.loads(args.packs.read_text())["packs"] if args.packs.exists() else []

    if args.replay:
        record_dir = HERE / args.replay
        log = json.loads((record_dir / "fetch-log.json").read_text())
    else:
        record_dir = HERE / "recorded" / dt.date.today().isoformat()
        (record_dir / "feeds").mkdir(parents=True, exist_ok=True)
        log = {"feeds": {}, "artwork": {}}
    if packs_config:
        log.setdefault("dates", {})

    # 1. Fetch (or replay) every feed's head, over https: the shows, then any pack show not among them.
    feed_urls = [https_form(show["feed"]) for show in shows]
    assert len(feed_urls) == len(set(feed_key(u) for u in feed_urls)), "duplicate feed URL in shows.json"
    show_by_key = {feed_key(url): (show, url) for show, url in zip(shows, feed_urls)}
    pack_urls: list[str] = []      # every pack candidate's feed, as the entry will spell it, in packs.json order
    extra: dict[str, dict] = {}    # pack shows not in shows.json, by feed URL
    for pack in packs_config:
        for kind in PACK_LISTS:
            for item in pack[kind]:
                if not item.get("feed"):
                    continue
                key = feed_key(item["feed"])
                url = show_by_key[key][1] if key in show_by_key else https_form(item["feed"])
                if url not in pack_urls:
                    pack_urls.append(url)
                if key not in show_by_key:
                    extra.setdefault(url, item)
    head_urls = feed_urls + list(extra)
    heads: dict[str, dict] = {}
    if args.replay:
        for url in head_urls:
            entry = log["feeds"][url]
            entry["head"] = (record_dir / "feeds" / entry["file"]).read_text()
            heads[url] = entry
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            for result in pool.map(feed_head, head_urls):
                name = hashlib.sha256(result["url"].encode()).hexdigest()[:16] + ".xml"
                (record_dir / "feeds" / name).write_text(result["head"])
                heads[result["url"]] = result
                log["feeds"][result["url"]] = {k: v for k, v in result.items() if k != "head"} | {"file": name}
            for result in pool.map(feed_dates, pack_urls):
                log["dates"][result["url"]] = result

    # 2. Read each show's own metadata and decide which artwork URL to use.
    parsed: dict[str, dict] = {}
    to_check: list[str] = []
    for url in head_urls:
        result = heads[url]
        if not result["looksLikeFeed"]:
            continue
        meta = parse_channel(result["head"])
        meta["artwork"] = artwork_candidates(meta["artwork"])
        parsed[url] = meta
        to_check += meta["artwork"][:2]
    if not args.replay:
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            for result in pool.map(check_artwork, sorted(set(to_check))):
                log["artwork"][result["url"]] = result
        (record_dir / "fetch-log.json").write_text(json.dumps(log, indent=1, sort_keys=True) + "\n")

    used_ids: set[str] = set()

    def build_entry(show: dict, url: str, reserve: bool = True) -> tuple[dict | None, str]:
        """The catalog entry for one show, or None and why it can't be one. reserve=False only looks."""
        label = show.get("name") or show.get("title") or url
        if looks_private(url):
            return None, "private feed"
        if url not in parsed:
            return None, f"not a feed (HTTP {heads[url]['status']})"
        meta = parsed[url]
        artwork = next((a for a in meta["artwork"] if log["artwork"].get(a, {}).get("ok")), None)
        if not meta["title"] or not artwork:
            return None, "no title" if not meta["title"] else "no usable artwork"
        for subject in show["subjects"]:
            assert subject in subject_ids, f"{label}: unknown subject {subject}"
        entry_id = show.get("id") or slug(show.get("title") or meta["title"])
        if entry_id in used_ids:
            entry_id = f"{entry_id}-{hashlib.sha256(url.encode()).hexdigest()[:6]}"
        if reserve:
            used_ids.add(entry_id)
        entry = {
            "id": entry_id,
            "kind": show.get("kind", "podcast_feed"),
            "contentKind": show.get("contentKind", "podcast"),
            "title": meta["title"],
            "feedURL": url,
            "artworkURL": artwork,
            "subjects": show["subjects"],
            "explicit": show["explicit"] if "explicit" in show else is_explicit(meta["explicit"]),
            "provenanceIds": ["hand-picked-shows", "publisher-feeds"],
        }
        author = show.get("author") or meta["author"]
        if author:
            entry["author"] = author
        website = https_form(meta["website"]) if meta["website"] else ""
        if website.startswith("https://") and not is_apple_url(website):
            entry["websiteURL"] = website
        summary = show.get("summary") or shorten(meta["summary"], SUMMARY_LIMIT)
        if summary:
            entry["summary"] = summary
        return entry, ""

    # 3. Build the entries, in shows.json order.
    entries = []
    dropped = []
    fetched_at = max(r["fetchedAt"] for r in log["feeds"].values())
    for show, url in zip(shows, feed_urls):
        entry, why = build_entry(show, url)
        if entry is None:
            dropped.append({"show": show.get("name") or url, "feed": url, "why": why})
        else:
            entries.append(entry)

    # 3a. Packs: choose each pack's sources, then add the pack shows the list doesn't already have.
    by_feed = {e["feedURL"]: e for e in entries}
    generated = parse_feed_date(fetched_at)
    def look(item: dict, kind: str, url: str) -> tuple[dict | None, str]:
        show = {"title": item["title"], "subjects": [], **({"explicit": item["explicit"]} if "explicit" in item else {})}
        return build_entry(show, url, reserve=False)

    pack_rows, replacements, new_shows = choose_pack_sources(
        packs_config, show_by_key, by_feed, look, log.get("dates", {}), generated)
    for url, (item, kind, subjects) in new_shows.items():
        show = {"title": item["title"], "subjects": subjects, **({"id": item["id"]} if item.get("id") else {})}
        if kind == "newsletter":
            show |= {"kind": "article_feed", "contentKind": "newsletter"}
        entry, why = build_entry(show, url)
        assert entry is not None, f"{item['title']}: chosen for a pack but {why}"
        entries.append(entry)
        by_feed[url] = entry
    packs = []
    for pack, urls in pack_rows:
        for url in urls:
            by_feed[url]["recentPublishedAt"] = log["dates"][url]["dates"]
        packs.append({"id": pack["id"], "title": pack["title"], "summary": pack["summary"],
                      "entryIds": [by_feed[url]["id"] for url in urls]})

    # The "All" list is the entries in this order, so interleave the subjects (first show of each, then the
    # second of each, ...) instead of listing all of News first. Newsletters come last, as before.
    positions: dict[str, int] = {}
    ranked = []
    for entry in entries:
        subject = entry["subjects"][0]
        positions[subject] = positions.get(subject, 0) + 1
        ranked.append((entry["contentKind"] != "podcast", positions[subject], len(ranked), entry))
    entries = [item[3] for item in sorted(ranked, key=lambda item: item[:3])]

    # 4. Starter rows: the shows marked "starter", in shows.json order.
    starter_rows = []
    for subject in config["subjects"]:
        ids = [e["id"] for show, e in _pair(shows, feed_urls, entries) if show.get("starter") and e["subjects"][0] == subject["id"]]
        if ids:
            starter_rows.append({"subjectId": subject["id"], "title": f"Start with {subject['title']}",
                                 "entryIds": ids, "curatedBy": "hand-picked"})

    provenance = [
        {"id": "hand-picked-shows", "kind": "hand_curated", "fetchedAt": fetched_at,
         "note": "Which shows, and which lead each subject, is chosen by hand in research/B1/shows.json. Edit it freely."},
        {"id": "publisher-feeds", "kind": "publisher_feed", "fetchedAt": fetched_at,
         "note": "Title, author, description, explicit flag, website and artwork URL are read from each show's own RSS feed."},
    ]
    catalog = {
        "schemaVersion": "source-catalog.v1",
        "catalogId": "onboarding-top-podcasts",
        "contentVersion": args.content_version,
        "title": "Popular podcasts",
        "generatedAt": fetched_at,
        "locale": "en-US",
        "provenance": provenance,
        "subjects": config["subjects"],
        "starterRows": starter_rows,
        "entries": entries,
    }
    if packs:
        catalog["packs"] = packs
    args.out.mkdir(parents=True, exist_ok=True)
    catalog_bytes = (json.dumps(catalog, indent=1, ensure_ascii=False) + "\n").encode("utf-8")
    (args.out / "catalog.json").write_bytes(catalog_bytes)
    manifest = {
        "schemaVersion": "source-catalog-manifest.v1",
        "catalogId": catalog["catalogId"],
        "contentVersion": catalog["contentVersion"],
        "generatedAt": fetched_at,
        "catalogURL": CATALOG_BASE_URL + "catalog.json",
        "catalogByteCount": len(catalog_bytes),
        "catalogChecksumSHA256": hashlib.sha256(catalog_bytes).hexdigest(),
        "entryCount": len(entries),
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    report_path = HERE / "last-build-report.json" if args.out == SITE_DIR else args.out / "build-report.json"
    report_path.write_text(json.dumps({
        "entries": len(entries),
        "perSubject": {s["id"]: sum(1 for e in entries if e["subjects"][0] == s["id"]) for s in config["subjects"]},
        "explicit": sum(1 for e in entries if e["explicit"]),
        "noExplicitFlagInFeed": sorted(e["title"] for show, e in _pair(shows, feed_urls, entries)
                                       if "explicit" not in show and not parsed[e["feedURL"]]["explicit"]),
        "dropped": dropped,
        **({"packs": {p["id"]: len(p["entryIds"]) for p in packs}, "packReplacements": replacements} if packs_config else {}),
    }, indent=1) + "\n")
    print(f"{len(entries)} entries across {len(config['subjects'])} subjects; {len(dropped)} dropped; "
          f"catalog {len(catalog_bytes)} bytes")
    for item in dropped:
        print(f"  dropped {item['show']}: {item['why']}", file=sys.stderr)
    for item in replacements:
        print(f"  pack {item['pack']}: {item['replaced']} ({item['why']}) -> {item['by'] or 'nothing left'}", file=sys.stderr)
    return 0


PACK_LISTS = ("podcasts", "podcastAlternates", "newsletters", "newsletterAlternates")


def pack_source_problem(url: str | None, entry: dict | None, why_not_entry: str, kind: str,
                        dates: dict, generated: dt.datetime | None) -> str:
    """Why a pack candidate can't be used, or "" when it can (Design, #4285 PR 4: the replacement rule)."""
    if not url:
        return "no publisher feed found"
    if entry is None:
        return why_not_entry or "feed doesn't resolve"
    if entry.get("explicit"):
        return "explicit"
    record = dates.get(url) or {}
    if record.get("status") != 200:
        return f"feed doesn't resolve (HTTP {record.get('status', 0)})"
    if kind == "podcast" and not record.get("audio"):
        return "no audio in its feed"
    moments = [m for m in (parse_feed_date(d) for d in record.get("dates", [])) if m]
    if generated is None or not any(generated - dt.timedelta(days=PACK_FRESH_DAYS) <= m <= generated for m in moments):
        return f"no item in the {PACK_FRESH_DAYS} days before the build"
    return ""


def choose_pack_sources(packs_config: list[dict], show_by_key: dict, by_feed: dict, look, dates: dict,
                        generated: dt.datetime | None):
    """For each pack, its sources' feed URLs (podcasts first, then newsletters, each in packs.json order with a
    failed candidate replaced by the next usable alternate of the same kind), the replacements made, and the
    pack shows not in shows.json with the subjects their entries take."""
    subjects_by_kind = {"podcast": None, "newsletter": ["writers"]}
    checked: dict[tuple[str, str], str] = {}

    def problem(item: dict, kind: str) -> tuple[str | None, str]:
        if not item.get("feed"):
            return None, pack_source_problem(None, None, "", kind, dates, generated)
        key = feed_key(item["feed"])
        url = show_by_key[key][1] if key in show_by_key else https_form(item["feed"])
        if (url, kind) not in checked:
            if key in show_by_key:
                entry = by_feed.get(url)
                why = "" if entry else "dropped from the show list"
            else:
                entry, why = look(item, kind, url)
            checked[(url, kind)] = pack_source_problem(url, entry, why, kind, dates, generated)
        return url, checked[(url, kind)]

    rows, replacements, new_shows = [], [], {}
    for pack in packs_config:
        chosen: list[str] = []
        for kind, primary, alternates in (("podcast", "podcasts", "podcastAlternates"),
                                          ("newsletter", "newsletters", "newsletterAlternates")):
            spare = list(pack[alternates])
            for item in pack[primary]:
                url, why = problem(item, kind)
                if not why and url not in chosen:
                    chosen.append(url)
                    continue
                why = why or "already in this pack"
                replacement = None
                while spare:
                    candidate = spare.pop(0)
                    alt_url, alt_why = problem(candidate, kind)
                    if not alt_why and alt_url not in chosen:
                        replacement = (candidate, alt_url)
                        break
                if replacement:
                    chosen.append(replacement[1])
                replacements.append({"pack": pack["id"], "replaced": item["title"], "why": why,
                                     "by": replacement[0]["title"] if replacement else None})
        if len(chosen) < PACK_MIN_SOURCES:
            replacements.append({"pack": pack["id"], "replaced": "the whole pack",
                                 "why": f"only {len(chosen)} usable sources", "by": None})
            continue
        rows.append((pack, chosen))
        for kind_list, kind in (("podcasts", "podcast"), ("podcastAlternates", "podcast"),
                                ("newsletters", "newsletter"), ("newsletterAlternates", "newsletter")):
            for item in pack[kind_list]:
                if not item.get("feed"):
                    continue
                key = feed_key(item["feed"])
                url = https_form(item["feed"])
                if key in show_by_key or url not in chosen:
                    continue
                _, _, subjects = new_shows.setdefault(url, (item, kind, []))
                for subject in subjects_by_kind[kind] or pack["subjects"]:
                    if subject not in subjects:
                        subjects.append(subject)
    return rows, replacements, new_shows


def _pair(shows: list[dict], feed_urls: list[str], entries: list[dict]):
    """(show, entry) for every kept show; dropped shows have no entry."""
    by_feed = {e["feedURL"]: e for e in entries}
    return [(show, by_feed[url]) for show, url in zip(shows, feed_urls) if url in by_feed]


if __name__ == "__main__":
    raise SystemExit(main())
