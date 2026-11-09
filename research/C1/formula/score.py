"""Scores a c1-extract --dump folder against LaTeXML: equations silenced, prose kept. Prints counts only; PDF text stays in the dump folder.

python research/C1/formula/score.py <dump dir> <dev|holdout|all> <cache dir> (needs lxml)
"""
import json,re,sys,pathlib,collections

sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent.parent/"tools"))
import groundtruth as gt
C=pathlib.Path(sys.argv[3])
d=pathlib.Path(sys.argv[1]); split=sys.argv[2]
rows=[r for r in json.load(open(C/"sample.json")) if split in("all",r["split"])]
tot=collections.Counter()
WS=re.compile(r"[A-Za-z]+")
def toks(s): return [w.lower() for w in WS.findall(s)]
def long(s): return re.findall(r"[A-Za-z]{4,}",s)
GTCACHE=C/"gt-segments"; GTCACHE.mkdir(exist_ok=True)
def segs(i):
    f=GTCACHE/(i+".json")
    if f.exists(): return json.load(open(f))
    s=gt.latexml_segments(open(C/(i+".html"),"rb").read()); json.dump(s,open(f,"w")); return s
def muddled(chunk):
    t=chunk.split()
    if len(t)<5: return False
    sing=sum(1 for x in t if len(x.strip(".,;:()"))==1 and x.strip(".,;:()") not in("a","A","I"))
    return sing/len(t)>=0.3 or len(re.findall(r"[=<>^_{}|\\]",chunk))>=3
for r in rows:
    f=d/(r["id"]+".json")
    if not f.exists(): tot["missing"]+=1; continue
    D=json.load(open(f))
    if not D.get("chunks"): tot["empty"]+=1; continue
    ch=D["chunks"]; tot["papers"]+=1
    tot["words_lines"]+=sum(len(long(x)) for x in D["spoken_lines"]); tot["words_chunks"]+=sum(len(long(x)) for x in ch)
    tot["muddled"]+=sum(muddled(c) for c in ch); tot["notices"]+=" ".join(ch).count("Equation not read"); tot["chunks"]+=len(ch)
    sp=" ".join(ch).replace("Equation not read."," zzeqnotice ")
    T=toks(sp); LT=[x.lower() for x in long(sp)]; gr3={tuple(LT[i:i+3]) for i in range(len(LT))}
    for l in D["lines"]:
        if l["r"]=="body":
            w=[x.lower() for x in long(l["t"])]
            if len(w)>=6:
                tot["bodylines"]+=1
                if not any(tuple(w[i:i+3]) in gr3 for i in range(len(w)-2)): tot["bodylines_gone"]+=1
    if not r.get("ground_truth") or not (C/(r["id"]+".html")).exists(): continue
    S=segs(r["id"]); tot["gt_papers"]+=1
    pos=collections.defaultdict(list)
    for i in range(len(T)-3): pos[tuple(T[i:i+4])].append(i)
    # prose recall
    for s in S:
        if s["role"] in("body","abstract"):
            w=[x.lower() for x in long(s["text"])]
            if len(w)>=6:
                tot["gt_prose"]+=1
                n=sum(1 for i in range(len(w)-2) if tuple(w[i:i+3]) in gr3)
                tot["gt_grams"]+=len(w)-2; tot["gt_grams_hit"]+=n
                if n==0: tot["gt_prose_gone"]+=1
    # display equations, as runs
    i=0
    while i<len(S):
        if S[i]["role"]!="equation": i+=1; continue
        j=i
        while j+1<len(S) and S[j+1]["role"]=="equation": j+=1
        p=next((S[k] for k in range(i-1,-1,-1) if S[k]["role"] in("body","abstract")),None)
        n=next((S[k] for k in range(j+1,len(S)) if S[k]["role"] in("body","abstract")),None)
        i=j+1; tot["eq_runs"]+=1
        if not p or not n: tot["eq_noanchor"]+=1; continue
        pw=toks(p["text"])[-16:]; nw=toks(n["text"])[:16]
        best=None
        ends=[x+len(pw)-a for a in range(len(pw)-3) for x in pos.get(tuple(pw[a:a+4]),[])]
        starts=[x-a for a in range(len(nw)-3) for x in pos.get(tuple(nw[a:a+4]),[])]
        for e in ends:
            for st in starts:
                if 0<=st-e<500 and (best is None or st-e<best[1]-best[0]): best=(e,st)
        if not best: tot["eq_unlocated"]+=1; continue
        tot["eq_located"]+=1
        # anchors may overlap the gap's edge words; trim to words outside the 16-word contexts
        gap=[x for x in T[best[0]:best[1]]]
        notice=gap.count("zzeqnotice"); leak=len(gap)-notice
        tot["eq_leaked_tokens"]+=leak
        if leak<=2: tot["eq_silent"]+=1; tot["eq_announced"]+=notice>0
        elif notice: tot["eq_partial"]+=1
        else: tot["eq_read_out"]+=1
print({k:v for k,v in sorted(tot.items())})
if tot["words_lines"]: print("coverage chunks/lines %.3f"%(tot["words_chunks"]/tot["words_lines"]))
if tot["eq_located"]: print("eq silent %.3f partial %.3f read_out %.3f"%(tot["eq_silent"]/tot["eq_located"],tot["eq_partial"]/tot["eq_located"],tot["eq_read_out"]/tot["eq_located"]))
if tot["gt_grams"]: print("gt prose gram recall %.4f; gone %d/%d"%(tot["gt_grams_hit"]/tot["gt_grams"],tot["gt_prose_gone"],tot["gt_prose"]))

