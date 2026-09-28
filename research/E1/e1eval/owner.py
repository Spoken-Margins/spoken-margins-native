"""Owner's exported Margins as a second evaluation set, without committing any of their text.

The export (a zip of Markdown files) stays outside git. Only labels keyed by Margin ID are
committed, in data/labels_owner.psv, and they hold character offsets into the Margin text
rather than the text itself:

  id | capture | kind | referent | entities (start:end:type;...) | topics (start:end;...) | follows_up

Two export shapes are read (see SessionKit/SessionExport.swift):
  - Notes folder, one `Margin-<sha>.md` per Margin (`renderMargin`): the key is `m-` + the
    first 16 hex of that sha, sha256("<Session>:<Margin>"), since `Margin:` ids repeat per session.
  - Margins tab → Export Sessions, one `<title> — <date>.md` per session: has no Margin id,
    so the key is `x-` + sha256(file name, position heading, ordinal)[:16], stable across runs.
"""
import hashlib, re
from pathlib import Path
from .data import Margin, parse_referent, ROOT
from .tagger import SpacyNLEmulator  # noqa: F401  (documented dependency of callers)

SENT_RE = re.compile(r"(?<=[.!?])[\"”’)]*\s+(?=[\"“(]?[A-Z0-9])")
LABELS = ROOT / "data" / "labels_owner.psv"
BEFORE, AFTER = 7, 3


def _sents(text):
    return [s.strip() for s in SENT_RE.split(re.sub(r"\s+", " ", text or "").strip()) if s.strip()]


def _window(before, after):
    b, a = _sents(before)[-(BEFORE + 1):], _sents(after)[:AFTER]
    return b + a, max(len(b) - 1, 0)


def _section(md, heading):
    m = re.search(rf"^## {re.escape(heading)}\n\n(.*?)(?=\n## |\Z)", md, re.S | re.M)
    return m.group(1).strip() if m else ""


def read_margin_note(path):
    md = path.read_text(encoding="utf-8")
    # `Margin:` ids (ij-001, ...) repeat across sessions. The app names the file
    # Margin-<sha256(session:margin)>.md (AutomaticMarginNoteGatherer), so key on that digest.
    local = re.search(r"^Margin: (.+)$", md, re.M).group(1).strip()
    sess = re.search(r"^Session: (.+)$", md, re.M).group(1).strip()
    mid = "m-" + hashlib.sha256(f"{sess}:{local}".encode()).hexdigest()[:16]
    title = md.splitlines()[0].lstrip("# ").strip()
    written = "## Written Margin" in md
    text = _section(md, "Written Margin" if written else "Listener Margin")
    sents, anchor = _window(_section(md, "Context before"), _section(md, "Context after"))
    src = hashlib.sha256(title.encode()).hexdigest()[:12]
    return [dict(id=mid, source_id=src, session=sess,
                 capture="written" if written else "spoken", text=text, sentences=sents, anchor_index=anchor)]


def read_session_export(path):
    md = path.read_text(encoding="utf-8")
    title = md.splitlines()[0].replace("# Spoken Margins AI Handoff:", "").strip()
    src = hashlib.sha256(title.encode()).hexdigest()[:12]
    out = []
    # Walk the context/interjection blocks in order, tracking the latest context text.
    blocks = re.split(r"^(#### .+? — Listener interjection)$", md, flags=re.M)
    ctx_before = ""
    for i in range(1, len(blocks), 2):
        pre, heading, body = blocks[i - 1], blocks[i], blocks[i + 1]
        for label in ("Source context:", "Later source context:", "Turn context:", "Later turn context:", "Source continues:", "Turn continues:"):
            if label in pre:
                ctx_before = pre.split(label)[-1].split("\n###")[0].strip()
        body_main = re.split(r"^(?:Source continues:|Later source context:|Turn continues:|Later turn context:|### )", body, flags=re.M)[0]
        written = body_main.lstrip().startswith("Written Margin:")
        text = body_main.replace("Written Margin:", "", 1).strip()
        if not text or text.startswith("Transcript: "):
            continue
        after = ""
        m = re.search(r"^(?:Source continues:|Turn continues:)\n(.*?)(?=\n\n|\Z)", body, re.S | re.M)
        if m:
            after = m.group(1)
        sents, anchor = _window(ctx_before, after)
        key = hashlib.sha256(f"{path.name}|{heading}|{i // 2}".encode()).hexdigest()[:16]
        out.append(dict(id="x-" + key, source_id=src, session=path.stem, capture="written" if written else "spoken",
                        text=text, sentences=sents, anchor_index=anchor))
    return out


def read_export(folder):
    rows = []
    for p in sorted(Path(folder).rglob("*.md")):
        head = p.read_text(encoding="utf-8")[:4000]
        if re.search(r"^Margin: ", head, re.M):
            rows += read_margin_note(p)
        elif head.startswith("# Spoken Margins AI Handoff:"):
            rows += read_session_export(p)
    seen, out = set(), []
    for r in rows:  # the same Margin can appear in both export shapes
        k = (r["text"], r["source_id"])
        if k not in seen:
            seen.add(k)
            out.append(r)
    return out


def _spans(field, text):
    out = []
    for part in filter(None, field.split(";")):
        bits = part.split(":")
        s, e = int(bits[0]), int(bits[1])
        out.append((text[s:e], bits[2]) if len(bits) > 2 else text[s:e])
    return out


def load(folder, labels=LABELS):
    """Join the local export with committed labels; unlabeled Margins are skipped."""
    rows = {r["id"]: r for r in read_export(folder)}
    out = []
    for line in open(labels, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        mid, cap, kind, ref, ents, topics, follows = line.rstrip("\n").split("|")
        r = rows.get(mid)
        if r is None:
            continue
        out.append(Margin(id=mid, ctx_id=f"{r['source_id']}:{mid}", source_id=r["source_id"], split="owner",
                          capture=r["capture"], text=r["text"], sentences=r["sentences"],
                          anchor_index=r["anchor_index"], kind=kind, referent=parse_referent(ref),
                          entities=_spans(ents, r["text"]), topics=_spans(topics, r["text"]),
                          follows_up=follows or None))
    return out
