"""Upper bound: anything spaCy (en_core_web_md) can do.

A superset of the portable baseline: it starts from the same word lists and adds the
dependency parse, fine-grained tags, the full entity label set, noun chunks and word vectors.
None of these ship on the phone.
"""
import re
from . import common, portable
from .wordlists import TOPIC_STOP, REACTION_WORDS, REASONING_RE

LABEL_MAP = {"PERSON": "person", "GPE": "place", "LOC": "place", "FAC": "place", "ORG": "org",
             "WORK_OF_ART": "work", "PRODUCT": "other", "EVENT": "other", "LAW": "other"}


class SpacyFull:
    def __init__(self, nlp, tagger):
        self.nlp, self.tagger, self._c = nlp, tagger, {}

    def doc(self, text):
        if text not in self._c:
            self._c[text] = self.nlp(text)
        return self._c[text]

    def kind(self, m):
        base = portable.kind(m, self.tagger)
        doc = self.doc(m.text)
        roots = [t for t in doc if t.dep_ == "ROOT"]
        first_root = roots[0] if roots else None
        # Imperative: a base-form root verb with no subject that opens its sentence.
        imperative = any(r.tag_ == "VB" and not any(c.dep_ in ("nsubj", "nsubjpass", "expl") for c in r.children)
                         and r.i - r.sent.start <= 2 for r in roots)
        if base in ("claim", "reaction", "connection") and imperative and first_root is not None and first_root.lemma_ not in ("love", "imagine", "save"):
            return "todo"
        # Subject-auxiliary inversion without a question mark.
        if base in ("claim", "reaction") and any(t.dep_ == "aux" and t.i == t.sent.start and t.head.dep_ == "ROOT" for t in doc):
            return "question"
        # First-person past experience, or a first-person possessive memory.
        if base in ("claim", "reaction"):
            for t in doc:
                if t.dep_ == "nsubj" and t.lower_ in ("i", "we") and t.head.tag_ == "VBD":
                    return "connection"
        if base == "reaction":
            finite = any(t.tag_ in ("VBZ", "VBP", "VBD", "MD") and t.dep_ in ("ROOT", "ccomp") and
                         any(c.dep_ == "nsubj" and c.pos_ != "PRON" for c in t.children) for t in doc)
            if finite and REASONING_RE.search(m.text.lower()):
                return "claim"
        if base == "claim":
            no_finite = not any(t.tag_ in ("VBZ", "VBP", "VBD", "MD") for t in doc)
            if no_finite and any(t.lower_ in REACTION_WORDS for t in doc):
                return "reaction"
        return base

    def entities(self, m):
        doc = self.doc(m.text)
        ents = []
        for e in doc.ents:
            if e.label_ in LABEL_MAP:
                ents.append((re.sub(r"^the\s+", "", re.sub(r"[’']s$", "", e.text), flags=re.I), LABEL_MAP[e.label_]))
        return common.merge_entities(ents, m.text, " ".join(m.sentences))

    def topics(self, m, k=2):
        doc = self.doc(m.text)
        ent_tokens = {t.i for e in doc.ents for t in e}
        ctx = " ".join(m.sentences).lower()
        cands = []
        for ch in doc.noun_chunks:
            span = [t for t in ch if t.pos_ in ("NOUN", "ADJ", "PROPN") and t.i not in ent_tokens
                    and t.lemma_.lower() not in TOPIC_STOP and t.pos_ != "PROPN"]
            if not span or span[-1].pos_ != "NOUN":
                continue
            phrase = " ".join(t.lemma_.lower() for t in span[-3:])
            head = ch.root
            score = len(span) + (1.5 if span[-1].lemma_.lower() in ctx else 0) + (1 if head.dep_ in ("dobj", "pobj", "nsubj", "attr") else 0)
            cands.append((score, ch.start, phrase))
        seen, out = set(), []
        for _, _, p in sorted(cands, key=lambda c: (-c[0], c[1])):
            if p.split()[-1] not in seen:
                seen.add(p.split()[-1])
                out.append(p)
        if not out:
            out = portable.topics(m, self.tagger, k)
        return out[:k]

    def sim(self, a, b):
        da, db = self.doc(a), self.doc(b)
        if not da.vector_norm or not db.vector_norm:
            return 0.0
        return da.similarity(db)

    def predict(self, margins):
        preds = {}
        for m in margins:
            preds[m.id] = {
                "kind": self.kind(m),
                "referent": common.referent(m, self.tagger, extra_sim=self.sim, sim_weight=2.0),
                "entities": self.entities(m),
                "topics": self.topics(m),
            }
        for mid, target in common.follows_up(margins, preds, self.tagger).items():
            preds[mid]["follows_up"] = target
        return preds
