"""A small trained statement-kind classifier (spaCy textcat), scored with cross-validation.

This is the "small bundled model" option for statement kind: if it clearly beats the rules,
M2 should consider shipping a tiny classifier (Core ML) rather than rules alone. Folds are
grouped by source so a Margin is never scored by a model trained on its own episode.
"""
import random
import spacy
from spacy.training import Example
from .data import KINDS


def train(margins, epochs=25, seed=0):
    random.seed(seed)
    spacy.util.fix_random_seed(seed)
    nlp = spacy.blank("en")
    tc = nlp.add_pipe("textcat", config={"model": {"@architectures": "spacy.TextCatBOW.v3",
                                                   "exclusive_classes": True, "ngram_size": 2,
                                                   "no_output_layer": False}})
    for k in KINDS:
        tc.add_label(k)
    ex = [Example.from_dict(nlp.make_doc(m.text), {"cats": {k: float(k == m.kind) for k in KINDS}}) for m in margins]
    opt = nlp.initialize(lambda: ex)
    for _ in range(epochs):
        random.shuffle(ex)
        for i in range(0, len(ex), 8):
            nlp.update(ex[i:i + 8], sgd=opt, drop=0.2)
    return nlp


def predict(nlp, margins):
    return {m.id: max(nlp(m.text).cats.items(), key=lambda kv: kv[1])[0] for m in margins}


def cross_validate(margins, folds=4):
    sources = sorted({m.source_id for m in margins})
    random.Random(0).shuffle(sources)
    out = {}
    for f in range(folds):
        held = set(sources[f::folds])
        model = train([m for m in margins if m.source_id not in held])
        out.update(predict(model, [m for m in margins if m.source_id in held]))
    return out
