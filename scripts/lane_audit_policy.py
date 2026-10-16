"""Existing persistence audit eligibility, shared by the auditor and merge gate.

Execution tiers remain test-scope's concern. A host-domain change can still
require a persistence audit. Keep the auditor's existing path exemptions.
"""
import re

PERSISTENCE_PATTERNS = [
    r"(^|/)SessionKitPersistence/",
    r"sqlite",
    r"migration",
    r"persist",
    r"ledger",
    r"(^|/)SessionEngine[^/]*\.swift$",
    r"^Contracts/fixtures/(persistence|prepared-audio)/",
]

NEVER_RISKY_RE = re.compile(
    r"(^|/)(docs|research|Design)/|(^|/)[^/]*Tests/|\.md$", re.I
)
_PERSISTENCE_RE = [re.compile(pattern, re.I) for pattern in PERSISTENCE_PATTERNS]


def requires_persistence_audit(paths: list[str]) -> bool:
    return any(not NEVER_RISKY_RE.search(path)
               and any(pattern.search(path) for pattern in _PERSISTENCE_RE)
               for path in paths)
