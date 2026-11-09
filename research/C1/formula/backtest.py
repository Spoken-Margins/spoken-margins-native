"""Before/after numbers for PDF math speech. Prints counts only; PDF text never leaves artifacts/ or the scratch folder.

python3 -I research/C1/formula/backtest.py <cache> <baseline extractor> <new extractor> <lexicon.tsv> <tokenizer.json> <work dir>
"""
import collections, json, re, subprocess, sys, pathlib

cache, base, new, lex, tok, work = map(pathlib.Path, sys.argv[1:7])
rows = json.load(open(cache / "sample.json"))
vocab = {c for piece, _ in json.load(open(tok))["model"]["vocab"] if not piece.startswith("<") for c in piece}
SPELLED = set("αβγδεζηθικλμνξοπρστυφχψωΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ×÷≤≥=±π")
PUNCT = set("’‘“”—–…•−()[]{}:;+*_")  # Phonon's normalize_text turns these into pauses or words


def run(binary, out, pdfs):
    out.mkdir(parents=True, exist_ok=True)
    for start in range(0, len(pdfs), 8):
        subprocess.run([str(binary), "--dump", str(out), str(lex)] + [str(p) for p in pdfs[start:start + 8]],
                       stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=900)


def fallback(text):
    return sum(1 for c in text if not c.isspace() and c not in vocab and c not in SPELLED and c not in PUNCT)


def muddled(chunk):
    tokens = chunk.split()
    if len(tokens) < 5:
        return False
    singles = sum(1 for t in tokens if len(t.strip(".,;:()")) == 1 and t.strip(".,;:()") not in ("a", "A", "I"))
    return singles / len(tokens) >= 0.3 or len(re.findall(r"[=<>^_{}|\\]", chunk)) >= 3


def words(chunks):
    return collections.Counter(w.lower() for c in chunks for w in re.findall(r"[A-Za-z]{4,}", c))


def stats(doc):
    chunks = doc.get("chunks") or []
    joined = " ".join(chunks)
    return dict(chunks=len(chunks), fallback=fallback(joined), fallback_chunks=sum(1 for c in chunks if fallback(c)),
                notices=joined.count("Equation not read"), muddled=sum(1 for c in chunks if muddled(c)),
                words=sum(len(c.split()) for c in chunks))


for r in rows:
    r["file"] = r["id"] + ".pdf"
rows = [r for r in rows if (cache / r["file"]).exists()]
pdfs = [cache / r["file"] for r in rows]
run(base, work / "base", pdfs)
run(new, work / "new", pdfs)
tot = collections.defaultdict(lambda: collections.Counter())
lost = []
perpaper = []
for r in rows:
    stem = pathlib.Path(r["file"]).stem
    try:
        b = json.load(open(work / "base" / f"{stem}.json"))
        n = json.load(open(work / "new" / f"{stem}.json"))
    except FileNotFoundError:
        tot[r["split"]]["missing"] += 1
        continue
    if not b.get("chunks"):
        tot[r["split"]]["empty"] += 1
        continue
    sb, sn = stats(b), stats(n)
    src = "nber" if stem.startswith("nber") else "arxiv"
    for key in (r["split"], f'{r["split"]}/{src}'):
        tot[key]["papers"] += 1
        tot[key]["with_fallback_before"] += sb["fallback"] > 0
        tot[key]["with_fallback_after"] += sn["fallback"] > 0
        for k, v in sb.items():
            tot[key]["b_" + k] += v
        for k, v in sn.items():
            tot[key]["n_" + k] += v
    wb, wn = words(b["chunks"]), words(n["chunks"])
    gone = sum((wb - wn).values())
    perpaper.append((round(gone / max(1, sum(wb.values())), 4), stem, r["split"]))
    tokens = [w.lower() for c in n["chunks"] for w in re.findall(r"[A-Za-z]{4,}", c)]
    grams = {tuple(tokens[i:i + 3]) for i in range(len(tokens))}
    for chunk in b["chunks"]:
        w = [x.lower() for x in re.findall(r"[A-Za-z]{4,}", chunk)]
        if len(w) >= 6:
            tot[r["split"]]["prose_chunks_before"] += 1
            if not any(tuple(w[i:i + 3]) in grams for i in range(len(w) - 2)):
                tot[r["split"]]["prose_chunks_gone"] += 1
                lost.append((r["split"], stem, chunk))
for key in sorted(tot):
    print(key, dict(sorted(tot[key].items())))
perpaper.sort(reverse=True)
print("largest word loss:", perpaper[:6])
json.dump(lost, open(work / "lost_lines.json", "w"), ensure_ascii=False)
print("baseline spoken lines with prose missing after:", len(lost))
