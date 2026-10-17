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

Usage:
  .venv/bin/python research/B1/build_catalog.py --content-version 3        # live fetch
  .venv/bin/python research/B1/build_catalog.py --replay recorded/<date>   # offline
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
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
CATALOG_BASE_URL = "https://spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/"

USER_AGENT = "SpokenMarginsCatalogResearch/2 (+https://spokenmargins.proximitytoprogress.com)"
FEED_HEAD_LIMIT = 512 * 1024   # bytes read from a feed while looking for its first <item>
SUMMARY_LIMIT = 300            # characters of a feed's description kept (the schema allows 600)

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
    args = parser.parse_args(argv)

    config = json.loads(SHOWS_FILE.read_text())
    shows = config["shows"]
    subject_ids = {s["id"] for s in config["subjects"]}

    if args.replay:
        record_dir = HERE / args.replay
        log = json.loads((record_dir / "fetch-log.json").read_text())
    else:
        record_dir = HERE / "recorded" / dt.date.today().isoformat()
        (record_dir / "feeds").mkdir(parents=True, exist_ok=True)
        log = {"feeds": {}, "artwork": {}}

    # 1. Fetch (or replay) every feed's head, over https.
    feed_urls = [https_form(show["feed"]) for show in shows]
    assert len(feed_urls) == len(set(u.rstrip("/").lower() for u in feed_urls)), "duplicate feed URL in shows.json"
    heads: dict[str, dict] = {}
    if args.replay:
        for url in feed_urls:
            entry = log["feeds"][url]
            entry["head"] = (record_dir / "feeds" / entry["file"]).read_text()
            heads[url] = entry
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            for result in pool.map(feed_head, feed_urls):
                name = hashlib.sha256(result["url"].encode()).hexdigest()[:16] + ".xml"
                (record_dir / "feeds" / name).write_text(result["head"])
                heads[result["url"]] = result
                log["feeds"][result["url"]] = {k: v for k, v in result.items() if k != "head"} | {"file": name}

    # 2. Read each show's own metadata and decide which artwork URL to use.
    parsed: dict[str, dict] = {}
    to_check: list[str] = []
    for show, url in zip(shows, feed_urls):
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

    # 3. Build the entries, in shows.json order.
    entries = []
    dropped = []
    used_ids: set[str] = set()
    fetched_at = max(r["fetchedAt"] for r in log["feeds"].values())
    for show, url in zip(shows, feed_urls):
        label = show.get("name") or url
        if looks_private(url):
            dropped.append({"show": label, "feed": url, "why": "private feed"})
            continue
        if url not in parsed:
            dropped.append({"show": label, "feed": url, "why": f"not a feed (HTTP {heads[url]['status']})"})
            continue
        meta = parsed[url]
        artwork = next((a for a in meta["artwork"] if log["artwork"].get(a, {}).get("ok")), None)
        if not meta["title"] or not artwork:
            dropped.append({"show": label, "feed": url, "why": "no title" if not meta["title"] else "no usable artwork"})
            continue
        for subject in show["subjects"]:
            assert subject in subject_ids, f"{label}: unknown subject {subject}"
        entry_id = show.get("id") or slug(meta["title"])
        if entry_id in used_ids:
            entry_id = f"{entry_id}-{hashlib.sha256(url.encode()).hexdigest()[:6]}"
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
        entries.append(entry)

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
    }, indent=1) + "\n")
    print(f"{len(entries)} entries across {len(config['subjects'])} subjects; {len(dropped)} dropped; "
          f"catalog {len(catalog_bytes)} bytes")
    for item in dropped:
        print(f"  dropped {item['show']}: {item['why']}", file=sys.stderr)
    return 0


def _pair(shows: list[dict], feed_urls: list[str], entries: list[dict]):
    """(show, entry) for every kept show; dropped shows have no entry."""
    by_feed = {e["feedURL"]: e for e in entries}
    return [(show, by_feed[url]) for show, url in zip(shows, feed_urls) if url in by_feed]


if __name__ == "__main__":
    raise SystemExit(main())
