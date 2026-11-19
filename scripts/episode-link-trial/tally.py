#!/usr/bin/env python3
"""Resolve every link in the #4673 trial answers with the app's resolver and count the outcomes.

    scripts/episode-link-trial/tally.py

Reads artifacts/episode-link-trial/raw/*.txt (from run_assistants.py), runs
`swift run episode-link-check` on them (PublicPodcastLinkResolver, the app's own resolver), then probes
each link that did not resolve to the right episode to tell an invented link (nothing at that address)
from one the resolver could not use. Writes resolved.jsonl and summary.md next to raw/; prints only counts.

Outcome per link:
  right    resolver made it playable and the episode title matches the one the assistant named
  wrong    playable, but a different episode from the one named
  failed   the address exists, but the resolver could not make an episode of it
  invented nothing at the address (404, unknown Apple episode ID, oEmbed refusal, no such host)
  (unchecked: playable but the line named no title; counted apart)
"""
import collections
import json
import pathlib
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
TRIAL = ROOT / "artifacts" / "episode-link-trial"
RAW = TRIAL / "raw"
PKG = ROOT / "Packages" / "SessionKit"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
KINDS = ["apple_episode", "apple_show", "spotify", "youtube", "substack", "other"]
OUTCOMES = ["right", "wrong", "failed", "invented", "unchecked"]


def fetch(url: str, timeout: int = 15) -> tuple[int, str]:
    request = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en-US"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(2_000_000).decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, ""
    except Exception as error:  # DNS failure, refused, timeout, bad scheme
        return -1, type(error).__name__


def exists(row: dict) -> bool | None:
    """Whether anything is at the link's address. None when the probe itself can't tell."""
    url, kind = row["url"], row["kind"]
    parsed = urllib.parse.urlparse(url)
    if kind in ("apple_episode", "apple_show"):
        show = re.search(r"/id(\d+)", parsed.path)
        episode = urllib.parse.parse_qs(parsed.query).get("i", [None])[0]
        if not show:
            return False
        status, body = fetch(f"https://itunes.apple.com/lookup?id={show.group(1)}&entity=podcast")
        if status != 200:
            return None
        if json.loads(body or "{}").get("resultCount", 0) == 0:
            return False
        if kind == "apple_show":
            return True
        status, body = fetch(f"https://itunes.apple.com/lookup?id={episode}&entity=podcastEpisode")
        if status == 200 and any(r.get("trackId") == int(episode) for r in json.loads(body or "{}").get("results", [])):
            return True
        status, body = fetch(url)
        if status in (404, 410):
            return False
        return (episode in body) if status == 200 else None
    if kind == "spotify":
        status, _ = fetch("https://open.spotify.com/oembed?url=" + urllib.parse.quote(url, safe=""))
        return True if status == 200 else (False if status in (400, 404) else None)
    if kind == "youtube":
        status, _ = fetch("https://www.youtube.com/oembed?format=json&url=" + urllib.parse.quote(url, safe=""))
        return True if status == 200 else (False if status in (400, 404) else None)
    probe = url.replace("http://", "https://", 1) if url.startswith("http://") else url
    status, detail = fetch(probe)
    if status in (404, 410) or (status == -1 and detail in ("URLError", "gaierror")):
        return False
    return True if 200 <= status < 400 else None


def outcome(row: dict) -> str:
    verdict = row["verdict"]
    if verdict == "right_episode":
        return "right"
    if verdict == "wrong_episode":
        return "wrong"
    if verdict == "unchecked":
        return "unchecked"
    row["exists"] = exists(row)
    return "invented" if row["exists"] is False else "failed"


def table(counter: dict, rows_label: str, keys: list) -> str:
    lines = [f"| {rows_label} | tried | right | wrong | failed | invented | unchecked |", "|---|---|---|---|---|---|---|"]
    for key in keys:
        c = counter.get(key, collections.Counter())
        tried = sum(c.values())
        if tried:
            lines.append(f"| {key} | {tried} | " + " | ".join(str(c[o]) for o in OUTCOMES) + " |")
    total = collections.Counter()
    for c in counter.values():
        total.update(c)
    lines.append(f"| **all** | {sum(total.values())} | " + " | ".join(str(total[o]) for o in OUTCOMES) + " |")
    return "\n".join(lines)


def main() -> None:
    answers = sorted(p for p in RAW.glob("*.txt") if not p.name.endswith(".prompt.txt"))
    subprocess.run(["swift", "build", "--product", "episode-link-check"], cwd=PKG, check=True, capture_output=True)
    checker = subprocess.run([str(PKG / ".build/debug/episode-link-check"), *map(str, answers)],
                             capture_output=True, text=True, check=True)
    rows = [json.loads(line) for line in checker.stdout.splitlines() if line.strip()]
    for row in rows:
        stem = row["file"].removesuffix(".txt")
        row["condition"], row["persona"] = stem.rsplit("-", 1)
        row["assistant"] = row["condition"].split("-")[0]
        row["outcome"] = outcome(row)
    (TRIAL / "resolved.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))

    by_kind, by_condition, by_assistant_search = {}, {}, {}
    for row in rows:
        by_kind.setdefault(row["kind"], collections.Counter())[row["outcome"]] += 1
        by_condition.setdefault(row["condition"], collections.Counter())[row["outcome"]] += 1
        if "-search-" in row["condition"]:
            key = f"{row['assistant']} / {row['kind']}"
            by_assistant_search.setdefault(key, collections.Counter())[row["outcome"]] += 1

    answered = collections.Counter()
    empty = collections.Counter()
    for path in answers:
        condition = path.stem.rsplit("-", 1)[0]
        answered[condition] += 1
        if not any(r["file"] == path.name for r in rows):
            empty[condition] += 1
    marked = collections.Counter(r["condition"] for r in rows if r.get("markedShowLink"))
    reasons = collections.Counter(f"{r['kind']}: {r.get('failureReason') or r.get('error') and 'error' or r['status']}" for r in rows if r["outcome"] in ("failed", "invented"))

    conditions = sorted(by_condition)
    summary = [
        "# Episode link trial (#4673) — counts",
        "",
        "## By condition (assistant-search-wording)",
        table(by_condition, "condition", conditions),
        "",
        "Answers with no links at all: " + ", ".join(f"{c} {empty[c]}/{answered[c]}" for c in sorted(answered)),
        "Lines marked (show link): " + (", ".join(f"{c} {n}" for c, n in sorted(marked.items())) or "none"),
        "",
        "## By link kind (all conditions)",
        table(by_kind, "kind", KINDS),
        "",
        "## By assistant and link kind (web search on, both wordings)",
        table(by_assistant_search, "assistant / kind", sorted(by_assistant_search)),
        "",
        "## Failure reasons (failed + invented)",
        *[f"- {reason}: {n}" for reason, n in reasons.most_common()],
    ]
    (TRIAL / "summary.md").write_text("\n".join(summary) + "\n")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
