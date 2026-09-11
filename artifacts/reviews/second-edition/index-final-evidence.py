"""Index existing verification evidence; never creates a passing result."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("verification", ROOT / "scripts/verify-tests.py")
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
identity = v.input_identity()
records = []
for path in sorted((ROOT / "artifacts/test-runs").glob("*/manifest.json")):
    record = json.loads(path.read_text())
    if record.get("input_sha256") != identity:
        continue
    records.append({
        "manifest": str(path.relative_to(ROOT)),
        "plan": record["plan"],
        "status": record["status"],
        "destination": record.get("destination"),
        "steps": [{key: step[key] for key in ("name", "counts", "executed_count", "errors", "seconds", "exit_code") if key in step} for step in record["steps"]]
    })
output = {"head": v.capture(["git", "rev-parse", "HEAD"]), "input_sha256": identity, "runs": records}
out = ROOT / "artifacts/validation/gate-1/second-edition/execution-index.json"
out.write_text(json.dumps(output, indent=2) + "\n")
print(out)
for record in records:
    print(record["plan"], record["status"], record["manifest"])
