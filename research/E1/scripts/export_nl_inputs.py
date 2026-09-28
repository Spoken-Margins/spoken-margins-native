"""Print every string the portable baseline tags (Margin texts and context sentences) as JSON.

Usage: python scripts/export_nl_inputs.py [--owner <export folder>]
With --owner the output holds the owner's text too; keep it out of git.
"""
import argparse, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from e1eval import data

ap = argparse.ArgumentParser()
ap.add_argument("--owner", help="owner export folder (see e1eval/owner.py)")
args = ap.parse_args()
margins = data.load_public() + data.load_heldout()
if args.owner:
    from e1eval import owner
    margins += owner.load(args.owner)
texts = set()
for m in margins:
    texts.add(m.text)
    texts.update(m.sentences)
print(json.dumps(sorted(texts), ensure_ascii=False))
