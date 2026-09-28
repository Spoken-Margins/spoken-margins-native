"""Portable baseline: only what the phone can reproduce without a model.

Inputs: the Margin text, its context window, NaturalLanguage-shaped tags (tagger.py),
word lists and regular expressions (wordlists.py). No parse, no vectors, no proper-noun class.
"""
import re
from . import common
from .wordlists import (TODO_VERBS, TODO_RE, WH_AUX, QUESTION_RE, QUOTE_RE, CONNECTION_RE,
                        REACTION_WORDS, REASONING_RE, TOPIC_STOP)

LEAD_FILLERS = {"ok", "okay", "so", "and", "oh", "um", "uh", "hey", "also", "then", "first"}
NAME_MAP = {"person": "person", "place": "place", "org": "org"}


def words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def kind(m, tagger):
    low = m.text.lower()
    w = words(low)
    while w and w[0] in LEAD_FILLERS:
        w = w[1:]
    first = w[0] if w else ""
    toks = tagger.tag(m.text)
    if first in TODO_VERBS or TODO_RE.search(low):
        return "todo"
    if QUESTION_RE.search(low) or (first in WH_AUX and len(w) > 2):
        return "question"
    ctx = [common.lemma_seq(tagger.tag(s)) for s in m.sentences]
    if QUOTE_RE.search(m.text) or max(common.longest_common_run(common.lemma_seq(toks), c) for c in ctx) >= 5:
        return "quote"
    if CONNECTION_RE.search(low):
        return "connection"
    content = [t for t in toks if t.lexical_class in common.CONTENT and t.lemma not in common.STOP]
    evaluative = any(x in REACTION_WORDS for x in w) or "!" in m.text
    if evaluative and not REASONING_RE.search(low) and len(content) <= 7:
        return "reaction"
    return "claim"


def entities(m, tagger):
    toks = tagger.tag(m.text)
    ents, cur, cur_type = [], [], None
    for t in toks + [None]:
        nt = t.name_type if t is not None else None
        if nt and nt == cur_type and cur:
            cur.append(t)
            continue
        if cur:
            ents.append((m.text[cur[0].start:cur[-1].start + len(cur[-1].text)], NAME_MAP[cur_type]))
        cur, cur_type = ([t], nt) if nt else ([], None)
    ents = [(re.sub(r"[’']s$", "", e), ty) for e, ty in ents]
    return common.merge_entities(ents, m.text, " ".join(m.sentences))


def topics(m, tagger, k=2):
    """Adjective/noun runs ending in a noun, found by a regex over lexical classes."""
    toks = tagger.tag(m.text)
    tags = "".join("A" if t.lexical_class == "Adjective" else "N" if t.lexical_class == "Noun" else "x" for t in toks)
    ctx = " ".join(m.sentences).lower()
    cands = []
    for mt in re.finditer(r"A*N+", tags):
        span = [t for t in toks[mt.start():mt.end()]
                if t.lemma not in TOPIC_STOP and not t.name_type and not t.text[:1].isupper()]
        if not span or span[-1].lexical_class != "Noun":
            continue
        phrase = " ".join(t.lemma for t in span[-3:])
        score = len(span) + (1.5 if span[-1].lemma in ctx else 0)
        cands.append((score, mt.start(), phrase))
    seen, out = set(), []
    for _, _, p in sorted(cands, key=lambda c: (-c[0], c[1])):
        if p.split()[-1] not in seen:
            seen.add(p.split()[-1])
            out.append(p)
    return out[:k]


def predict(margins, tagger):
    preds = {}
    for m in margins:
        preds[m.id] = {
            "kind": kind(m, tagger),
            "referent": common.referent(m, tagger),
            "entities": entities(m, tagger),
            "topics": topics(m, tagger),
        }
    for mid, target in common.follows_up(margins, preds, tagger).items():
        preds[mid]["follows_up"] = target
    return preds
