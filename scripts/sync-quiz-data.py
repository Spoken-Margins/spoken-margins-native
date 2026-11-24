#!/usr/bin/env python3
"""Keep the quiz page's copy of its questions identical to the canonical file (#4707).

`Contracts/quiz/find-something.v1.json` is the one definition of the "Find an episode to talk about" questions and
prompt. The site serves a byte-for-byte copy at `Site/quiz/v1/find-something.json` so the page needs no server.

    scripts/sync-quiz-data.py           write the copy
    scripts/sync-quiz-data.py --check   exit 1 when the copy differs (the tests run this)
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Contracts" / "quiz" / "find-something.v1.json"
COPY = ROOT / "Site" / "quiz" / "v1" / "find-something.json"
USAGE = "usage: scripts/sync-quiz-data.py [--check]"


def main(arguments):
    if arguments == ["--check"]:
        if COPY.exists() and COPY.read_bytes() == SOURCE.read_bytes():
            return 0
        print(f"{COPY.relative_to(ROOT)} differs from {SOURCE.relative_to(ROOT)}; run scripts/sync-quiz-data.py",
              file=sys.stderr)
        return 1
    if arguments:
        print(USAGE, file=sys.stderr)
        return 2
    COPY.parent.mkdir(parents=True, exist_ok=True)
    COPY.write_bytes(SOURCE.read_bytes())
    print(f"wrote {COPY.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
