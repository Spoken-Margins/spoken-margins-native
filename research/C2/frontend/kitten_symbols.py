"""Kitten's symbol table, read from engines/kitten.py without importing it.

engines/kitten.py imports espeak-ng and onnxruntime at module level, which the export scripts neither
have nor want. Its four symbol strings are plain assignments, so they are evaluated from the source.
"""
import ast
from pathlib import Path

_SOURCE = Path(__file__).resolve().parents[1] / "engines" / "kitten.py"


def _load() -> dict[str, int]:
    wanted = {"_pad", "_punct", "_letters", "_ipa"}
    found = {}
    for node in ast.parse(_SOURCE.read_text(encoding="utf-8")).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and getattr(node.targets[0], "id", None) in wanted:
            found[node.targets[0].id] = ast.literal_eval(node.value)
    assert wanted <= found.keys(), "engines/kitten.py no longer defines the symbol strings"
    return {s: i for i, s in enumerate([found["_pad"]] + list(found["_punct"]) + list(found["_letters"]) + list(found["_ipa"]))}


SYMBOLS = _load()
