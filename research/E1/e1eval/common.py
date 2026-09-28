"""Pieces both baselines use: referent scoring, follow-up detection, entity post-processing."""
import math, re
from .wordlists import (STOP, ITEM_RE, NONE_RE, FOLLOW_CUE_RE, CELESTIAL_PLACES, ACRONYM_RE,
                        COMMON_ACRONYMS, CALENDAR, WORK_NOUNS, WORK_VERBS)

CONTENT = {"Noun", "Verb", "Adjective", "Number", "OtherWord"}


def content_lemmas(toks):
    return {t.lemma for t in toks if t.lexical_class in CONTENT and t.lemma not in STOP and len(t.lemma) > 1}


def lemma_seq(toks):
    return [t.lemma for t in toks if t.lexical_class not in {"SentenceTerminator", "OtherPunctuation", "OpenQuote", "CloseQuote"}]


def longest_common_run(a, b):
    best, prev = 0, [0] * (len(b) + 1)
    for x in a:
        cur = [0] * (len(b) + 1)
        for j, y in enumerate(b, 1):
            if x == y:
                cur[j] = prev[j - 1] + 1
                best = max(best, cur[j])
        prev = cur
    return best


def referent(m, tagger, extra_sim=None, sim_weight=0.0):
    """Pick the context sentence the Margin is about, or item/none.

    Score = IDF-weighted content-lemma overlap + optional similarity term - distance prior.
    """
    low = m.text.lower()
    if ITEM_RE.search(low):
        return ("item", None)
    mt = tagger.tag(m.text)
    ml = content_lemmas(mt)
    sent_lemmas = [content_lemmas(tagger.tag(s)) for s in m.sentences]
    names = {t.text.lower() for t in mt if t.name_type or (t.text[:1].isupper() and t.start > 0)}
    n = len(m.sentences)
    df = {}
    for sl in sent_lemmas:
        for l in sl:
            df[l] = df.get(l, 0) + 1
    best, best_i, best_overlap = -1e9, m.anchor_index, 0.0
    for i, sl in enumerate(sent_lemmas):
        overlap = sum(math.log(1 + n / df[l]) for l in ml & sl)
        overlap += 0.5 * sum(1 for w in names if w in m.sentences[i].lower())
        score = overlap
        if extra_sim is not None:
            score += sim_weight * extra_sim(m.text, m.sentences[i])
        d = i - m.anchor_index
        score -= 0.12 * abs(d) if d <= 0 else 0.35 * d
        if score > best:
            best, best_i, best_overlap = score, i, overlap
    if best_overlap == 0 and NONE_RE.search(low):
        return ("none", None)
    return ("span", best_i)


def follows_up(margins, preds, tagger):
    """For each Margin, the earlier Margin in the same source it continues, if any."""
    out = {}
    by_source = {}
    for m in margins:
        by_source.setdefault(m.source_id, []).append(m)
    for ms in by_source.values():
        for j, b in enumerate(ms):
            bl = content_lemmas(tagger.tag(b.text))
            be = {e[0].lower() for e in preds[b.id]["entities"]}
            cue = bool(FOLLOW_CUE_RE.search(b.text.lower()))
            for a in reversed(ms[max(0, j - 3):j]):
                al = content_lemmas(tagger.tag(a.text))
                ae = {e[0].lower() for e in preds[a.id]["entities"]}
                shared = len(al & bl) + len(ae & be)
                if shared and (preds[a.id]["kind"] == "question" and preds[b.id]["kind"] in ("claim", "todo", "question") or cue):
                    out[b.id] = a.id
                    break
    return out


def _sentence_initial(text, i):
    before = text[:i].rstrip()
    return not before or before[-1] in ".!?:\"“”"


def pattern_entities(text, taken, context_text, people=()):
    """Word-list and regex entities the NL name tagger doesn't produce.

    Returns (entities, retype) where retype maps an already-tagged span to a better type.
    """
    ents, retype = [], {}
    low_taken = {t.lower() for t in taken}
    for w in re.findall(r"\b[A-Za-z]+\b", text):
        if w.lower() in CELESTIAL_PLACES and w[0].isupper():
            if w.lower() in low_taken:
                retype[w.lower()] = "place"
            else:
                ents.append((w, "place"))
                low_taken.add(w.lower())
    run = r"[A-Z][\w\-’']*(?:\s+(?:[A-Z][\w\-’']*|[IVX]+|\d+))*"
    # Titles: a capitalized run named as a work ("the White Flight episode", "watch Ash").
    for mt in list(re.finditer(rf"({run})\s+{WORK_NOUNS}\b", text)) + list(re.finditer(rf"\b{WORK_VERBS}\s+({run})", text, re.I)):
        span = re.sub(r"[’']s$", "", mt.group(1))
        if span.split()[0].lower() in STOP:
            continue
        if span.lower() in low_taken:
            if span.lower() not in people:  # "the Todd Rose book": a person before a work noun is the author
                retype[span.lower()] = "work"
        else:
            ents.append((span, "work"))
            low_taken.add(span.lower())
    for mt in re.finditer(run, text):
        span = re.sub(r"[’']s$", "", mt.group(0))
        first = span.split()[0]
        if first.lower() in STOP or first.lower() in CALENDAR or span in COMMON_ACRONYMS or span.rstrip("s") in COMMON_ACRONYMS:
            continue
        if any(span.lower() == t or span.lower() in t.split() for t in low_taken):
            continue
        numbered = re.search(r"\s(?:[IVX]+|\d+)$", span)
        acronym = ACRONYM_RE.fullmatch(span)
        if _sentence_initial(text, mt.start()) and not (acronym or numbered):
            continue
        if acronym or numbered or span in context_text:
            # A longer span swallows a shorter tagged one ("Apollo" inside "Apollo 11").
            for t in list(low_taken):
                if t in span.lower().split():
                    retype[t] = None
            ents.append((span, "other"))
            low_taken.add(span.lower())
    return ents, retype


def merge_entities(tagged, text, context_text):
    people = {e.lower() for e, ty in tagged if ty == "person"}
    extra, retype = pattern_entities(text, [e for e, _ in tagged], context_text, people)
    out = []
    for e, ty in tagged:
        if e in COMMON_ACRONYMS or e.lower() in CALENDAR:
            continue
        ty = retype.get(e.lower(), ty)
        if ty:
            out.append((e, ty))
    return out + extra
