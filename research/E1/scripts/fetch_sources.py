"""Fetch the public sources behind the E1 evaluation set into a local raw folder.

Podcasts: Houston We Have a Podcast transcripts (NASA, US government work, public domain).
Articles: English Wikipedia (CC BY-SA 4.0). Wikipedia rate-limits bursts; rerun for 429s.

Usage: python scripts/fetch_sources.py <raw-dir>   (raw-dir is not committed)
Then:  python scripts/build_contexts.py <raw-dir>
"""
import json, sys, time, urllib.parse, urllib.request
from pathlib import Path

PODCASTS = [
    "ai-at-nasa", "artemis-ii-lunar-science", "artemis-iii-training", "callsign-white-flight",
    "iss-results-materials-science", "iss-results-stem-cells-in-space", "iss-results-wayfinding",
    "space-runs-in-the-family", "the-future-of-deep-space-communications", "the-moon-base",
    "cosmic-perspectives-with-neil-degrasse-tyson", "chapea-2-audio-log-2",
]
ARTICLES = ["Great_Stink", "Tulip_mania", "Dunbar's_number", "Panama_Canal"]
UA = {"User-Agent": "SpokenMarginsResearch/0.1 (E1 evaluation set)"}

def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read()

def main(out):
    from bs4 import BeautifulSoup
    out.mkdir(parents=True, exist_ok=True)
    for slug in PODCASTS:
        url = f"https://www.nasa.gov/podcasts/houston-we-have-a-podcast/{slug}/"
        soup = BeautifulSoup(get(url), "html.parser")
        paras = [p.get_text(" ", strip=True) for p in soup.find_all("p")]
        doc = {"url": url, "title": soup.title.get_text(strip=True), "paras": [p for p in paras if len(p) > 40]}
        (out / f"{slug}.json").write_text(json.dumps(doc, indent=1))
    for title in ARTICLES:
        q = urllib.parse.urlencode({"action": "query", "prop": "extracts|info", "inprop": "url",
                                    "explaintext": 1, "redirects": 1, "titles": title,
                                    "format": "json", "formatversion": 2})
        (out / f"wiki_{urllib.parse.quote(title)}.json").write_bytes(get(f"https://en.wikipedia.org/w/api.php?{q}"))
        time.sleep(5)

if __name__ == "__main__":
    main(Path(sys.argv[1]))
