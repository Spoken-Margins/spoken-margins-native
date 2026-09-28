"""Print every string the portable baseline tags (Margin texts and context sentences) as JSON."""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from e1eval import data

texts = set()
for m in data.load_public() + data.load_heldout():
    texts.add(m.text)
    texts.update(m.sentences)
print(json.dumps(sorted(texts), ensure_ascii=False))
