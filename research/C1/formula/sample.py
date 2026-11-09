#!/usr/bin/env python3
"""Downloads a reproducible random sample of NBER working papers and arXiv papers for the formula backtest.

  python3 -I research/C1/formula/sample.py <cache dir> --nber 90 --arxiv 90 --seed 20261108

Each paper is randomly put in `dev` (rules may be tuned on it) or `holdout` (only scored). PDFs and arXiv's LaTeXML
HTML (the ground truth for equations) stay in the cache directory, which git ignores. Writes sample.json there.
"""
import argparse, json, pathlib, random, re, sys, time, urllib.error, urllib.parse, urllib.request, xml.etree.ElementTree as ET

UA = {"User-Agent": "SpokenMargins-formula-backtest/1.0 (research sample; low rate)"}
ARXIV_CATEGORIES = ["econ.GN", "econ.TH", "econ.EM", "q-fin.EC", "stat.ME", "stat.ML", "math.PR", "math.OC", "math.AP", "math.NA",
                    "cs.LG", "cs.IT", "cs.GT", "physics.comp-ph", "physics.flu-dyn", "quant-ph", "cond-mat.stat-mech", "q-bio.PE", "eess.SY", "astro-ph.CO"]


def get(url, tries=3, wait=4):
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code in (403, 404, 410):
                raise
            time.sleep(wait * (attempt + 1))
        except Exception:
            time.sleep(wait * (attempt + 1))
    raise RuntimeError("gave up: " + url)


def is_pdf(data):
    return data[:5] == b"%PDF-" and len(data) > 20_000 and len(data) < 30_000_000


def nber(rng, want, out):
    got, tried = [], set()
    while len(got) < want and len(tried) < want * 5:
        number = rng.randint(18000, 34000)
        if number in tried:
            continue
        tried.add(number)
        target = out / f"nber-w{number}.pdf"
        if not target.exists():
            try:
                data = get(f"https://www.nber.org/system/files/working_papers/w{number}/w{number}.pdf")
            except Exception as error:
                print(f"skip w{number}: {error}", file=sys.stderr)
                time.sleep(1)
                continue
            if not is_pdf(data):
                continue
            target.write_bytes(data)
            time.sleep(1.5)
        got.append({"id": target.stem, "source": "nber", "url": f"https://www.nber.org/papers/w{number}"})
    return got


def arxiv(rng, want, out):
    got = []
    per = want // len(ARXIV_CATEGORIES) + 1
    atom = "{http://www.w3.org/2005/Atom}"
    for category in ARXIV_CATEGORIES:
        offset = rng.randint(0, 6000)
        query = urllib.parse.urlencode({"search_query": f"cat:{category}", "start": offset, "max_results": 60, "sortBy": "submittedDate"})
        try:
            feed = ET.fromstring(get(f"https://export.arxiv.org/api/query?{query}"))
        except Exception as error:
            print(f"skip {category}: {error}", file=sys.stderr)
            continue
        time.sleep(3.2)
        ids = [e.find(atom + "id").text.rsplit("/abs/", 1)[1] for e in feed.findall(atom + "entry")]
        rng.shuffle(ids)
        taken = 0
        for raw in ids:
            if taken >= per or len(got) >= want:
                break
            base = re.sub(r"v\d+$", "", raw)
            if "/" in base:
                continue
            target = out / f"arxiv-{base}.pdf"
            if not target.exists():
                try:
                    data = get(f"https://export.arxiv.org/pdf/{base}")
                except Exception as error:
                    print(f"skip {base}: {error}", file=sys.stderr)
                    continue
                time.sleep(3.2)
                if not is_pdf(data):
                    continue
                target.write_bytes(data)
            html = out / f"arxiv-{base}.html"
            if not html.exists():
                try:
                    page = get(f"https://arxiv.org/html/{base}", tries=1)
                    if b"ltx_equation" in page or b"ltx_Math" in page:
                        html.write_bytes(page)
                except Exception:
                    pass
                time.sleep(3.2)
            got.append({"id": target.stem, "source": "arxiv", "category": category, "url": f"https://arxiv.org/abs/{base}", "ground_truth": html.exists()})
            taken += 1
    return got


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cache", type=pathlib.Path)
    parser.add_argument("--nber", type=int, default=90)
    parser.add_argument("--arxiv", type=int, default=90)
    parser.add_argument("--seed", type=int, default=20261108)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    papers = arxiv(random.Random(args.seed), args.arxiv, args.cache)
    json.dump(papers, open(args.cache / "sample.partial.json", "w"))
    papers += nber(random.Random(args.seed + 1), args.nber, args.cache)
    split = random.Random(args.seed + 2)
    for paper in sorted(papers, key=lambda p: p["id"]):
        paper["split"] = "dev" if split.random() < 0.34 else "holdout"
    json.dump(sorted(papers, key=lambda p: p["id"]), open(args.cache / "sample.json", "w"), indent=0)
    print(len(papers), "papers", {s: sum(p["split"] == s for p in papers) for s in ("dev", "holdout")})


main()
