"""Scores tidy-eval results (#4339). Usage: python3 fixtures/margin-tidy/score.py results.jsonl [more.jsonl] [--show]

Per variant it reports:
  offered   rows the app would show as an AI proposal (a reply that passed MarginTidyGuard and differs from the words)
  kept      rows whose reply keeps every mustKeep term and none of mustNotContain (meaning check, run on every reply)
  clean     replies with no filler left, no preamble or refusal, ending in punctuation, in the Margin's language
  good      offered AND kept AND clean: what the author would see and could accept
  errors    model errors (context, guardrail, refusal)
"""
import json, re, sys, pathlib, collections

CASES = {c["id"]: c for c in json.loads(pathlib.Path(__file__).with_name("eval-cases.json").read_text())["cases"]}
FILLERS = re.compile(r"\b(um+|uh+|uhm|erm?|ah+|you know|i mean|kind of, kind of|o sea|eh)\b", re.I)
PREAMBLE = re.compile(r"^(sure|here('s| is)|certainly|rewritten|the rewritten|spoken note|note:|i('m| am) sorry|sorry|i can('t|not))", re.I)
SPANISH = re.compile(r"\b(esto|estudio|sueño|midieron|dice|que)\b", re.I)

def norm(s):
    return s.replace("’", "'").replace("“", '"').replace("”", '"').lower()

def bare(s):
    return re.sub(r"[^a-z0-9'.% ]+", " ", norm(s)).replace(" .", " ").split()

NUMBER_WORDS = {"forty two": "42", "two thousand": "2,000", "twelve": "12", "two hundred": "200"}

def score(row):
    case = CASES[row["caseId"]]
    reply = row.get("reply") or ""
    if not reply and not row.get("error") and not row.get("guardRejection"):
        reply = case["transcript"]  # the app path offers nothing when the tidy is the same words
    r = norm(reply)
    rb = " " + " ".join(w.strip(".") for w in bare(reply)) + " "
    for words, digits in NUMBER_WORDS.items():  # a number kept as digits still counts as kept
        if " " + digits + " " in rb: rb += words + " "
    def has(t):
        forms = [t] + ([NUMBER_WORDS[t.lower()]] if t.lower() in NUMBER_WORDS else [])
        return any(" " + " ".join(w.strip(".") for w in bare(f)) + " " in rb for f in forms)
    missing = [t for t in case["mustKeep"] if t != "?" and not has(t)] + \
              (["?"] if "?" in case["mustKeep"] and "?" not in reply else [])
    corrected = all(norm(b) in r for b in case.get("betterWith", [])) and bool(case.get("betterWith"))
    present = [t for t in case["mustNotContain"] if norm(t) in r]
    problems = []
    if FILLERS.search(reply): problems.append("filler")
    if PREAMBLE.search(reply.strip()): problems.append("preamble")
    if reply and reply.strip()[-1] not in ".?!\"'”": problems.append("no-end-punct")
    if case["language"] == "es" and not SPANISH.search(reply): problems.append("translated")
    if re.search(r"(passage|spoken note)", reply, re.I) and not re.search(r"passage", case["transcript"], re.I): problems.append("meta")
    t = norm(case["transcript"])
    tw = set(re.findall(r"[a-z0-9']+", t))
    # Names the reply brings in that the speaker never said (a capitalised word, not first in a sentence).
    added = []
    for m in re.finditer(r"(?<![.!?]\s)(?<!^)\b([A-Z][a-z]+)\b", reply.strip()):
        w = m.group(1).lower()
        if w not in tw and w not in ("i",): added.append(m.group(1))
    if added: problems.append("added-name:" + ",".join(added))
    # Longer words taken from the passage that the speaker never said.
    pw = set(re.findall(r"[a-z]{6,}", norm(case["before"] + " " + case["after"])))
    lifted = sorted({w for w in re.findall(r"[a-z]{6,}", r) if w in pw and w not in tw and w[:5] not in {x[:5] for x in tw}})
    if len(lifted) >= 2: problems.append("passage-words:" + ",".join(lifted[:6]))
    same = reply.strip().lower() == case["transcript"].strip().lower()
    offered = bool(reply) and not row.get("guardRejection") and not same
    kept = bool(reply) and not missing and not present
    clean = bool(reply) and not problems
    good = offered and kept and clean
    if case["kind"] == "short" and case["id"] == "already-clean":
        good = kept and clean  # nothing to tidy: the same words back is right
    return dict(offered=offered, kept=kept, clean=clean, good=good, corrected=corrected,
                missing=missing, present=present, problems=problems)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show = "--show" in sys.argv
    rows = [json.loads(l) for a in args for l in open(a) if l.strip()]
    by = collections.defaultdict(list)
    for row in rows: by[row["variant"]].append(row)
    print(f"{'variant':28} {'n':>3} {'offered':>7} {'kept':>5} {'clean':>5} {'good':>5} {'errors':>6} {'guard-rej':>9} {'sec/avg':>7} {'asr-fix':>7}")
    for v, rs in by.items():
        sc = [score(r) for r in rs]
        n = len(rs)
        print(f"{v:28} {n:>3} {sum(s['offered'] for s in sc):>7} {sum(s['kept'] for s in sc):>5} {sum(s['clean'] for s in sc):>5} "
              f"{sum(s['good'] for s in sc):>5} {sum(1 for r in rs if r.get('error')):>6} {sum(1 for r in rs if r.get('guardRejection')):>9} "
              f"{sum(r['seconds'] for r in rs)/n:>7.1f} {sum(s['corrected'] for s in sc):>7}")
        if show:
            for r, s in zip(rs, sc):
                flag = "GOOD" if s["good"] else "----"
                print(f"  [{flag}] {r['caseId']}: {r.get('error') or ''}{('guard=' + r['guardRejection']) if r.get('guardRejection') else ''} "
                      f"miss={s['missing']} bad={s['present']} prob={s['problems']}")
                print(f"      IN : {r['transcript'][:300]}")
                print(f"      OUT: {(r.get('reply') or '')[:300]}")

main()
