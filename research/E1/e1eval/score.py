"""Score predictions against gold labels, per category."""
import re
from itertools import combinations
from .data import KINDS, ENTITY_TYPES


def prf(tp, fp, fn):
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    return {"p": round(p, 3), "r": round(r, 3), "f1": round(f, 3), "tp": tp, "fp": fp, "fn": fn}


def norm(s):
    s = s.lower().replace("–", " ").replace("-", " ")
    s = re.sub(r"[’']s\b", "", s)
    s = re.sub(r"^(the|professor|dr|mr|mrs|ms)\s+", "", s)
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", s)).strip()


def ent_match(a, b):
    return norm(a) == norm(b)


def head(topic, lemma):
    return lemma(topic.split()[-1])


def entity_key(e):
    t, ty = e
    n = norm(t)
    return (ty, n.split()[-1]) if ty == "person" else n


def score_kind(margins, preds):
    out = {"accuracy": round(sum(preds[m.id]["kind"] == m.kind for m in margins) / len(margins), 3)}
    for k in KINDS:
        tp = sum(preds[m.id]["kind"] == k and m.kind == k for m in margins)
        fp = sum(preds[m.id]["kind"] == k and m.kind != k for m in margins)
        fn = sum(preds[m.id]["kind"] != k and m.kind == k for m in margins)
        out[k] = prf(tp, fp, fn)
    out["confusion"] = {g: {p: sum(m.kind == g and preds[m.id]["kind"] == p for m in margins) for p in KINDS} for g in KINDS}
    return out


def score_referent(margins, preds):
    exact = near = 0
    by_scope = {}
    for m in margins:
        p, g = tuple(preds[m.id]["referent"]), m.referent
        ok = p == g
        exact += ok
        near += ok or (p[0] == g[0] == "span" and abs(p[1] - g[1]) <= 1)
        s = by_scope.setdefault(g[0], [0, 0])
        s[0] += ok
        s[1] += 1
    n = len(margins)
    return {"accuracy": round(exact / n, 3), "within_one_sentence": round(near / n, 3),
            "by_gold_scope": {k: {"correct": c, "n": t} for k, (c, t) in by_scope.items()},
            "anchor_sentence_baseline": round(sum(m.referent == ("span", m.anchor_index) for m in margins) / n, 3)}


def score_entities(margins, preds):
    out = {}
    for ty in ENTITY_TYPES + ["any"]:
        tp = fp = fn = 0
        for m in margins:
            gold = [e for e in m.entities if ty == "any" or e[1] == ty]
            pred = [e for e in preds[m.id]["entities"] if ty == "any" or e[1] == ty]
            used = set()
            for pe in pred:
                hit = next((i for i, ge in enumerate(gold) if i not in used and ent_match(pe[0], ge[0])), None)
                if hit is None:
                    fp += 1
                else:
                    used.add(hit)
                    tp += 1
            fn += len(gold) - len(used)
        out[ty] = prf(tp, fp, fn)
    # Typed-any: span must match and the type must be right.
    tp = fp = fn = 0
    for m in margins:
        used = set()
        for pe in preds[m.id]["entities"]:
            hit = next((i for i, ge in enumerate(m.entities) if i not in used and ent_match(pe[0], ge[0]) and pe[1] == ge[1]), None)
            if hit is None:
                fp += 1
            else:
                used.add(hit)
                tp += 1
        fn += len(m.entities) - len(used)
    out["typed"] = prf(tp, fp, fn)
    return out


def score_topics(margins, preds, lemma):
    tp_p = n_p = tp_r = n_r = 0
    for m in margins:
        gh = {head(t, lemma) for t in m.topics}
        ph = [head(t, lemma) for t in preds[m.id]["topics"]]
        n_p += len(ph)
        tp_p += sum(h in gh for h in ph)
        n_r += len(gh)
        tp_r += sum(h in set(ph) for h in gh)
    p = tp_p / n_p if n_p else 0
    r = tp_r / n_r if n_r else 0
    return {"p": round(p, 3), "r": round(r, 3), "f1": round(2 * p * r / (p + r) if p + r else 0, 3)}


def links(margins, get, lemma):
    """Derive link sets from a labeling (gold or predicted). get(m) -> dict of fields."""
    L = {"same_entity": set(), "same_referent": set(), "related_topic": set(), "follows_up": set()}
    ek = {m.id: {entity_key(e) for e in get(m)["entities"]} for m in margins}
    tk = {m.id: {head(t, lemma) for t in get(m)["topics"]} for m in margins}
    for a, b in combinations(margins, 2):
        fa, fb = get(a), get(b)
        if ek[a.id] & ek[b.id]:
            L["same_entity"].add((a.id, b.id))
        ra, rb = tuple(fa["referent"]), tuple(fb["referent"])
        # Compare span referents in the base window's numbering, since anchors can be shifted.
        absa = ra if ra[0] != "span" else ("span", (a.base_ctx or a.ctx_id), ra[1] + a.shift)
        absb = rb if rb[0] != "span" else ("span", (b.base_ctx or b.ctx_id), rb[1] + b.shift)
        if a.source_id == b.source_id and ra[0] != "none" and absa == absb:
            L["same_referent"].add((a.id, b.id))
        if tk[a.id] & tk[b.id]:
            L["related_topic"].add((a.id, b.id))
    for m in margins:
        if get(m).get("follows_up"):
            L["follows_up"].add((get(m)["follows_up"], m.id))
    return L


def score_links(margins, preds, lemma):
    gold = links(margins, lambda m: {"entities": m.entities, "referent": m.referent, "topics": m.topics, "follows_up": m.follows_up}, lemma)
    pred = links(margins, lambda m: preds[m.id], lemma)
    return {k: prf(len(gold[k] & pred[k]), len(pred[k] - gold[k]), len(gold[k] - pred[k])) for k in gold}


def score_all(margins, preds, lemma):
    return {
        "n": len(margins),
        "kind": score_kind(margins, preds),
        "referent": score_referent(margins, preds),
        "entities": score_entities(margins, preds),
        "topics": score_topics(margins, preds, lemma),
        "links": score_links(margins, preds, lemma),
    }
