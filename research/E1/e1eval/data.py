"""Load the E1 evaluation set: labeled Margins joined to their source-context windows."""
import json
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CTX_PREFIX = {
    "ai": "hwhap-ai-at-nasa", "a2": "hwhap-artemis-ii-lunar-science", "a3": "hwhap-artemis-iii-training",
    "wf": "hwhap-callsign-white-flight", "ch": "hwhap-chapea-2-audio-log-2",
    "ct": "hwhap-cosmic-perspectives-with-neil-degrasse-tyson", "ms": "hwhap-iss-results-materials-science",
    "sc": "hwhap-iss-results-stem-cells-in-space", "wy": "hwhap-iss-results-wayfinding",
    "sr": "hwhap-space-runs-in-the-family", "ds": "hwhap-the-future-of-deep-space-communications",
    "mb": "hwhap-the-moon-base", "du": "wiki-dunbar-s-number", "gs": "wiki-great-stink",
    "pc": "wiki-panama-canal", "tm": "wiki-tulip-mania",
}
# Rules were tuned only while looking at errors on these sources; the rest is held out.
DEV_SOURCES = {"ai", "a2", "a3", "wf", "ch"}
KINDS = ["question", "todo", "quote", "connection", "claim", "reaction"]
ENTITY_TYPES = ["person", "place", "org", "work", "other"]


@dataclass
class Margin:
    id: str
    ctx_id: str
    source_id: str
    split: str
    capture: str
    text: str
    sentences: list
    anchor_index: int
    # gold labels (absent for unlabeled sets)
    kind: str = None
    referent: tuple = None  # ("span", i) | ("item", None) | ("none", None)
    entities: list = field(default_factory=list)  # [(text, type)]
    topics: list = field(default_factory=list)
    follows_up: str = None
    base_ctx: str = None  # window before any anchor shift ("#2" for "#2+3")
    shift: int = 0        # how many sentences later than the base window the listener paused


def parse_referent(s):
    return ("span", int(s[1:])) if s.startswith("s") else (s, None)


def load_contexts(path=ROOT / "data" / "contexts.jsonl"):
    return {r["ctx_id"]: r for r in map(json.loads, open(path, encoding="utf-8"))}


def load_public(path=ROOT / "data" / "margins_public.psv", split=None):
    """Load a labeled .psv set. split=None assigns dev/test by source; otherwise every Margin gets split."""
    ctxs = load_contexts()
    out = []
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        mid, ctx, cap, kind, ref, text, ents, topics, follows = line.rstrip("\n").split("|")
        prefix, n = ctx.split("#")
        c = ctxs[f"{CTX_PREFIX[prefix]}#{n}"]
        out.append(Margin(
            id=mid, ctx_id=c["ctx_id"], source_id=c["source_id"],
            split=split or ("dev" if prefix in DEV_SOURCES else "test"),
            capture="spoken" if cap == "s" else "written", text=text,
            sentences=c["sentences"], anchor_index=c["anchor_index"],
            kind=kind, referent=parse_referent(ref),
            entities=[tuple(e.rsplit(":", 1)) for e in ents.split(";") if e],
            topics=[t for t in topics.split(";") if t],
            follows_up=follows or None,
            base_ctx=c["ctx_id"].split("+")[0], shift=int(n.split("+")[1]) if "+" in n else 0,
        ))
    return out


def load_heldout(path=ROOT / "data" / "margins_heldout.psv"):
    """Margins written and labeled by an independent author who never saw the rules."""
    return load_public(path, split="heldout")
