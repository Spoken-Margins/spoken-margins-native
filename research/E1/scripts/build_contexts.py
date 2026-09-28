"""Build source-context windows for the E1 evaluation set.

Input: raw source dumps fetched by fetch_sources.py (not committed; re-fetchable).
Output: data/contexts.jsonl, one record per anchor window:
  {ctx_id, source_id, source_kind, title, url, license, anchor_index, sentences[]}
A window is 7 sentences before the anchor, the anchor sentence, and 3 after, which
mirrors the app's before/after anchor context at a smaller scale.
"""
import json, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
RAW = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "raw"
BEFORE, AFTER = 7, 3
FRACTIONS = (0.3, 0.55, 0.8)
# Windows that landed in reference lists rather than prose.
SKIP = {"wiki-dunbar-s-number#3"}

SENT_RE = re.compile(r"(?<=[.!?])[\"”’)]*\s+(?=[\"“(]?[A-Z0-9])")
ABBREV = re.compile(r"\b(?:Dr|Mr|Mrs|Ms|St|vs|etc|e\.g|i\.e|U\.S|No)\.$")

def split_sentences(text):
    parts, buf = [], ""
    for piece in SENT_RE.split(text):
        buf = f"{buf} {piece}".strip() if buf else piece.strip()
        if ABBREV.search(buf):
            continue
        parts.append(buf)
        buf = ""
    if buf:
        parts.append(buf)
    return [p for p in parts if len(p) > 1]

def podcast(path):
    d = json.loads(path.read_text())
    paras = d["paras"][3:]  # skip show blurb paragraphs
    return {
        "source_id": "hwhap-" + path.stem,
        "source_kind": "podcast",
        "title": d["title"].split("|")[0].strip() + " (Houston We Have a Podcast, NASA)",
        "url": d["url"],
        "license": "US government work, public domain",
        "sentences": [s for p in paras for s in split_sentences(p.replace("T his", "This"))],
    }

def wiki(path):
    page = json.loads(path.read_text())["query"]["pages"][0]
    text = re.sub(r"\n+=+[^=\n]+=+\n+", "\n", page["extract"])
    body = text.split("\nSee also")[0].split("\nReferences")[0]
    return {
        "source_id": "wiki-" + re.sub(r"[^a-z0-9]+", "-", page["title"].lower()).strip("-"),
        "source_kind": "article",
        "title": page["title"] + " (Wikipedia)",
        "url": page["fullurl"],
        "license": "CC BY-SA 4.0, Wikipedia contributors",
        "sentences": [s for para in body.split("\n") for s in split_sentences(para)],
    }

def main():
    out = []
    for path in sorted(RAW.glob("*.json")):
        src = wiki(path) if path.name.startswith("wiki_") else podcast(path)
        sents = src.pop("sentences")
        for n, frac in enumerate(FRACTIONS, 1):
            a = int(len(sents) * frac)
            window = sents[a - BEFORE : a + AFTER + 1]
            if f"{src['source_id']}#{n}" in SKIP:
                continue
            out.append({"ctx_id": f"{src['source_id']}#{n}", **src,
                        "anchor_index": BEFORE, "sentences": window})
    dest = HERE / "data" / "contexts.jsonl"
    dest.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in out))
    print(f"{len(out)} windows -> {dest}")

if __name__ == "__main__":
    main()
