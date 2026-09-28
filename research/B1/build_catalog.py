#!/usr/bin/env python3
"""Build the onboarding top-podcast catalog snapshot (stream B1, seam I2).

Source: Apple's public per-genre top-podcast charts (the legacy iTunes RSS
feed, which is the only public Apple chart that filters by genre), then one
iTunes Lookup call per batch of shows to resolve the RSS feed URL and
600px artwork. Every feed URL is fetched once to confirm it answers with
RSS/Atom before the show is kept.

Raw responses are written under research/B1/recorded/<date>/ so the
snapshot can be rebuilt offline (--replay) and audited later.

Usage:
  .venv/bin/python research/B1/build_catalog.py            # live fetch
  .venv/bin/python research/B1/build_catalog.py --replay recorded/2026-09-28
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SITE_DIR = ROOT / "Site" / "onboarding" / "catalog" / "v1"
CATALOG_BASE_URL = "https://spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/"

COUNTRY = "us"
PER_SUBJECT = 16          # chart positions kept per subject, before de-duplication
CHART_DEPTH = 40          # positions fetched per chart, so de-duplication can backfill
USER_AGENT = "SpokenMarginsCatalogResearch/1 (+https://spokenmargins.proximitytoprogress.com)"

# Subject id -> (display title, Apple top-level podcast genre id).
SUBJECTS: list[tuple[str, str, int]] = [
    ("news", "News", 1489),
    ("society-culture", "Society & Culture", 1324),
    ("comedy", "Comedy", 1303),
    ("true-crime", "True Crime", 1488),
    ("business", "Business", 1321),
    ("science", "Science", 1533),
    ("history", "History", 1487),
    ("health-fitness", "Health & Fitness", 1512),
    ("technology", "Technology", 1318),
    ("sports", "Sports", 1545),
    ("education", "Education", 1304),
    ("arts", "Arts", 1301),
]

# Apple primaryGenreName (top-level or sub-genre) -> our subject id. Used to add
# secondary subjects; the chart a show was found in is always its primary subject.
GENRE_TO_SUBJECT = {
    "News": "news", "Daily News": "news", "Politics": "news", "News Commentary": "news",
    "Society & Culture": "society-culture", "Documentary": "society-culture",
    "Personal Journals": "society-culture", "Philosophy": "society-culture",
    "Relationships": "society-culture", "Places & Travel": "society-culture",
    "Comedy": "comedy", "Comedy Interviews": "comedy", "Improv": "comedy", "Stand-Up": "comedy",
    "True Crime": "true-crime",
    "Business": "business", "Investing": "business", "Entrepreneurship": "business",
    "Careers": "business", "Management": "business", "Marketing": "business",
    "Business News": "business",
    "Science": "science", "Natural Sciences": "science", "Social Sciences": "science",
    "Life Sciences": "science", "Physics": "science", "Astronomy": "science",
    "Nature": "science", "Mathematics": "science", "Earth Sciences": "science",
    "Chemistry": "science",
    "History": "history",
    "Health & Fitness": "health-fitness", "Mental Health": "health-fitness",
    "Fitness": "health-fitness", "Nutrition": "health-fitness", "Medicine": "health-fitness",
    "Alternative Health": "health-fitness", "Sexuality": "health-fitness",
    "Technology": "technology", "Tech News": "technology",
    "Sports": "sports", "Football": "sports", "Basketball": "sports", "Baseball": "sports",
    "Soccer": "sports", "Hockey": "sports", "Fantasy Sports": "sports", "Golf": "sports",
    "Sports News": "sports", "Wrestling": "sports",
    "Education": "education", "Self-Improvement": "education", "How To": "education",
    "Language Learning": "education", "Courses": "education",
    "Arts": "arts", "Books": "arts", "Design": "arts", "Performing Arts": "arts",
    "Visual Arts": "arts", "Food": "arts", "Fashion & Beauty": "arts",
}


def chart_url(genre_id: int) -> str:
    return f"https://itunes.apple.com/{COUNTRY}/rss/toppodcasts/limit={CHART_DEPTH}/genre={genre_id}/json"


def lookup_url(ids: list[str]) -> str:
    return f"https://itunes.apple.com/lookup?id={','.join(ids)}&entity=podcast&country={COUNTRY}"


def fetch(url: str, *, limit: int | None = None, timeout: int = 25) -> tuple[int, bytes, str]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(limit) if limit else response.read()
            return response.status, body, response.geturl()
    except urllib.error.HTTPError as error:
        return error.code, b"", url
    except Exception as error:  # network errors are recorded, not fatal
        return 0, str(error).encode(), url


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:48] or "podcast"


FEED_MARKERS = (b"<rss", b"<feed", b"<channel", b"<rdf:RDF")


def check_feed(url: str) -> dict:
    status, body, final_url = fetch(url, limit=64 * 1024, timeout=20)
    head = body[:64 * 1024].lower()
    looks_like_feed = status == 200 and any(marker.lower() in head for marker in FEED_MARKERS)
    return {"url": url, "status": status, "finalURL": final_url, "looksLikeFeed": looks_like_feed}


def artwork_600(result: dict) -> str | None:
    url = result.get("artworkUrl600") or result.get("artworkUrl100")
    if not url:
        return None
    # Apple's image CDN resizes by path; ask for a 600px square JPEG either way.
    return re.sub(r"/\d+x\d+bb\.(jpg|png|webp)$", "/600x600bb.jpg", url)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--replay", help="recorded directory (relative to research/B1) to rebuild from without network")
    parser.add_argument("--content-version", type=int, default=1)
    args = parser.parse_args()

    if args.replay:
        record_dir = HERE / args.replay
        meta = json.loads((record_dir / "fetch-log.json").read_text())
    else:
        record_dir = HERE / "recorded" / dt.date.today().isoformat()
        record_dir.mkdir(parents=True, exist_ok=True)
        meta = {"charts": {}, "lookups": [], "feedChecks": {}}

    # 1. Charts.
    chart_rows: dict[str, list[dict]] = {}
    provenance = []
    for subject_id, _title, genre_id in SUBJECTS:
        path = record_dir / f"chart-{subject_id}.json"
        if args.replay:
            fetched_at = meta["charts"][subject_id]["fetchedAt"]
        else:
            fetched_at = now_iso()
            status, body, _ = fetch(chart_url(genre_id))
            if status != 200:
                print(f"chart {subject_id}: HTTP {status}", file=sys.stderr)
                return 1
            path.write_bytes(body)
            meta["charts"][subject_id] = {"url": chart_url(genre_id), "fetchedAt": fetched_at}
        feed = json.loads(path.read_text())["feed"]
        entries = feed.get("entry", [])
        chart_rows[subject_id] = [
            {"appleId": e["id"]["attributes"]["im:id"], "rank": rank, "name": e["im:name"]["label"]}
            for rank, e in enumerate(entries, start=1)
        ]
        provenance.append({
            "id": f"apple-top-{COUNTRY}-{subject_id}",
            "kind": "apple_top_chart",
            "url": chart_url(genre_id),
            "country": COUNTRY,
            "appleGenreId": genre_id,
            "chartUpdatedAt": feed["updated"]["label"],
            "fetchedAt": fetched_at,
        })

    # 2. Lookups (feed URL + artwork) for every charted show.
    all_ids = sorted({row["appleId"] for rows in chart_rows.values() for row in rows})
    lookup: dict[str, dict] = {}
    batches = [all_ids[i:i + 100] for i in range(0, len(all_ids), 100)]
    for index, batch in enumerate(batches):
        path = record_dir / f"lookup-{index:02d}.json"
        if not args.replay:
            status, body, _ = fetch(lookup_url(batch))
            if status != 200:
                print(f"lookup batch {index}: HTTP {status} (itunes.apple.com blocked?)", file=sys.stderr)
                return 1
            path.write_bytes(body)
            meta["lookups"].append({"url": lookup_url(batch), "fetchedAt": now_iso(), "file": path.name})
        for result in json.loads(path.read_text()).get("results", []):
            lookup[str(result.get("collectionId"))] = result
    lookup_fetched_at = meta["lookups"][0]["fetchedAt"]
    provenance.append({
        "id": "itunes-lookup",
        "kind": "itunes_lookup",
        "url": "https://itunes.apple.com/lookup",
        "country": COUNTRY,
        "fetchedAt": lookup_fetched_at,
    })

    # 3. Select PER_SUBJECT unique shows per subject (a show charted in several
    #    subjects belongs to the first chart it was found in, in SUBJECTS order).
    chosen: list[tuple[str, dict]] = []
    taken: set[str] = set()
    candidates: dict[str, list[dict]] = {}
    for subject_id, *_ in SUBJECTS:
        candidates[subject_id] = [r for r in chart_rows[subject_id] if r["appleId"] in lookup and lookup[r["appleId"]].get("feedUrl")]

    # 4. Check every candidate feed that could be chosen.
    # App Transport Security blocks plain http, so try the https form of any
    # http feed and use it when it answers with a feed.
    for result in lookup.values():
        if result.get("feedUrl", "").startswith("http://"):
            result["httpFeedUrl"] = result["feedUrl"]
            result["feedUrl"] = "https://" + result["feedUrl"][len("http://"):]
    to_check = sorted({lookup[r["appleId"]]["feedUrl"] for rows in candidates.values() for r in rows})
    if not args.replay:
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            for result in pool.map(check_feed, to_check):
                result["checkedAt"] = now_iso()
                meta["feedChecks"][result["url"]] = result
        (record_dir / "fetch-log.json").write_text(json.dumps(meta, indent=1, sort_keys=True) + "\n")

    dropped = []
    for subject_id, *_ in SUBJECTS:
        kept = 0
        for row in candidates[subject_id]:
            if kept >= PER_SUBJECT:
                break
            if row["appleId"] in taken:
                continue
            check = meta["feedChecks"].get(lookup[row["appleId"]]["feedUrl"], {})
            if not check.get("looksLikeFeed"):
                dropped.append({"subject": subject_id, "name": row["name"], "feed": lookup[row["appleId"]]["feedUrl"], "status": check.get("status")})
                continue
            taken.add(row["appleId"])
            chosen.append((subject_id, row))
            kept += 1

    # 5. Build catalog entries.
    entries = []
    used_ids: set[str] = set()
    for subject_id, row in chosen:
        result = lookup[row["appleId"]]
        subjects = [subject_id]
        for genre in result.get("genres", []) + [result.get("primaryGenreName", "")]:
            extra = GENRE_TO_SUBJECT.get(genre)
            if extra and extra not in subjects:
                subjects.append(extra)
        entry_id = f"apple-{row['appleId']}"
        assert entry_id not in used_ids
        used_ids.add(entry_id)
        entry = {
            "id": entry_id,
            "kind": "podcast_feed",
            "contentKind": "podcast",
            "title": result.get("collectionName") or row["name"],
            "author": result.get("artistName"),
            "feedURL": result["feedUrl"],
            "artworkURL": artwork_600(result),
            "subjects": subjects,
            # collectionExplicitness reads "notExplicit" for every show; the
            # advisory rating is the field Apple actually sets.
            "explicit": result.get("contentAdvisoryRating") == "Explicit",
            "chartPositions": [{"provenanceId": f"apple-top-{COUNTRY}-{subject_id}", "rank": row["rank"]}],
            "externalIds": {"applePodcastsId": row["appleId"]},
            "provenanceIds": [f"apple-top-{COUNTRY}-{subject_id}", "itunes-lookup"],
        }
        if not entry["author"]:
            del entry["author"]
        # Other charts the same show appears in (for ranking, not subject assignment).
        for other_subject, rows in chart_rows.items():
            if other_subject == subject_id:
                continue
            for other in rows:
                if other["appleId"] == row["appleId"]:
                    entry["chartPositions"].append({"provenanceId": f"apple-top-{COUNTRY}-{other_subject}", "rank": other["rank"]})
                    if other_subject not in entry["subjects"]:
                        entry["subjects"].append(other_subject)
        entries.append(entry)

    subjects_out = [{"id": sid, "title": title, "appleGenreId": gid} for sid, title, gid in SUBJECTS]
    # Starter rows: the owner edits these in the remote catalog. Seeded with the
    # top five charted shows per subject so the drawer has something on day one.
    starter_rows = [
        {"subjectId": sid, "title": f"Start with {title}",
         "entryIds": [f"apple-{row['appleId']}" for s, row in chosen if s == sid][:5],
         "curatedBy": "chart-seed"}
        for sid, title, _ in SUBJECTS
    ]
    generated_at = max(p["fetchedAt"] for p in provenance)
    catalog = {
        "schemaVersion": "source-catalog.v1",
        "catalogId": "onboarding-top-podcasts",
        "contentVersion": args.content_version,
        "title": "Popular podcasts",
        "generatedAt": generated_at,
        "locale": f"en-{COUNTRY.upper()}",
        "provenance": provenance,
        "subjects": subjects_out,
        "starterRows": starter_rows,
        "entries": entries,
    }
    SITE_DIR.mkdir(parents=True, exist_ok=True)
    catalog_bytes = (json.dumps(catalog, indent=1, ensure_ascii=False) + "\n").encode("utf-8")
    (SITE_DIR / "catalog.json").write_bytes(catalog_bytes)
    manifest = {
        "schemaVersion": "source-catalog-manifest.v1",
        "catalogId": catalog["catalogId"],
        "contentVersion": catalog["contentVersion"],
        "generatedAt": generated_at,
        "catalogURL": CATALOG_BASE_URL + "catalog.json",
        "catalogByteCount": len(catalog_bytes),
        "catalogChecksumSHA256": hashlib.sha256(catalog_bytes).hexdigest(),
        "entryCount": len(entries),
    }
    (SITE_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (HERE / "last-build-report.json").write_text(json.dumps({
        "entries": len(entries),
        "perSubject": {sid: sum(1 for s, _ in chosen if s == sid) for sid, *_ in SUBJECTS},
        "droppedForFeedCheck": dropped,
        "missingFeedUrl": sorted(
            {r["name"] for rows in chart_rows.values() for r in rows if not lookup.get(r["appleId"], {}).get("feedUrl")}
        ),
    }, indent=1) + "\n")
    print(f"{len(entries)} entries across {len(SUBJECTS)} subjects; {len(dropped)} dropped by feed check; "
          f"catalog {len(catalog_bytes)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
