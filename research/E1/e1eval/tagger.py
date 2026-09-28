"""What the phone can see: Apple NaturalLanguage-shaped token tags.

The portable baseline may only read these fields per token:
  text, lemma, lexical_class (NLTag lexical classes), name_type (person/place/org/None)
plus the raw string (for word lists and regular expressions). NLTagger has no proper-noun
class, no dependency parse, no noun chunks, no vectors and only three name types, so those
are not exposed here.

Two sources of tags:
  SpacyNLEmulator  - spaCy tags squeezed into the NaturalLanguage shape (cloud, M1).
  RecordedNLTags   - tags recorded by running NLTagger on a Mac (swift/NLTagDump.swift, M2),
                     so the same portable rules can be re-scored with Apple's real tagger.
"""
import json
from dataclasses import dataclass

UPOS_TO_NL = {
    "NOUN": "Noun", "PROPN": "Noun", "VERB": "Verb", "AUX": "Verb", "ADJ": "Adjective",
    "ADV": "Adverb", "PRON": "Pronoun", "DET": "Determiner", "PART": "Particle",
    "ADP": "Preposition", "NUM": "Number", "CCONJ": "Conjunction", "SCONJ": "Conjunction",
    "INTJ": "Interjection", "X": "OtherWord", "SYM": "OtherWord", "SPACE": "Whitespace",
}
NER_TO_NL = {"PERSON": "person", "GPE": "place", "LOC": "place", "ORG": "org"}


@dataclass
class Tok:
    text: str
    lemma: str
    lexical_class: str
    name_type: str = None
    start: int = 0


def _punct_class(t):
    if t in ".?!":
        return "SentenceTerminator"
    if t in "\"“‘":
        return "OpenQuote"
    if t in "”’":
        return "CloseQuote"
    return "OtherPunctuation"


class SpacyNLEmulator:
    def __init__(self, nlp):
        self.nlp = nlp
        self._cache = {}

    def tag(self, text):
        if text not in self._cache:
            doc = self.nlp(text.replace("’", "'"))
            self._cache[text] = [
                Tok(t.text, t.lemma_.lower(),
                    _punct_class(t.text) if t.pos_ == "PUNCT" else UPOS_TO_NL.get(t.pos_, "OtherWord"),
                    NER_TO_NL.get(t.ent_type_), t.idx)
                for t in doc if not t.is_space
            ]
        return self._cache[text]


class RecordedNLTags:
    """Tags recorded from NLTagger: {text: [[token, lemma, lexicalClass, nameType|null, offset], ...]}."""

    def __init__(self, path):
        self.table = json.load(open(path, encoding="utf-8"))

    def tag(self, text):
        return [Tok(t, (l or t).lower(), c, n, o) for t, l, c, n, o in self.table[text]]
