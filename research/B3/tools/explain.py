"""Explain the matcher's decision for one or more video ids, offline.

    python3 tools/explain.py VIDEO_ID [...]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from b3 import match as m, youtube  # noqa: E402

for vid in sys.argv[1:]:
    ev = youtube.evidence(vid)
    print(f"### {vid} [{ev.channel}] {ev.title} | {ev.published} {ev.duration_s}s")
    shows = m.find_shows(ev)
    for s in shows:
        print(f"   show {s.strength:.2f} {s.name} ({s.collection_id}) via {s.via[:3]}")
    r = m.match(ev)
    print(f"   -> {r.status}: {r.reason}")
    for c in r.candidates[:4]:
        print(f"      {c.score:.2f} {c.title[:70]} | {c.show[:30]} | {', '.join(c.reasons)}")
