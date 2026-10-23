#!/usr/bin/env python3
"""Price the main-thread reads in docs/audit/main-thread-reads-ranked.json from a read-cost table, and render the
markdown beside it (#2513, audit step 4 of #2256).

The read-cost table is what `SESSIONKIT_READ_COST_TABLE=<file> swift test --filter testReadCostTableAtEveryScale`
writes (Packages/SessionKit/Tests/SessionKitCoreTests/ReadCostReport.swift). This script takes its library-scale
millisecond column and, for every audited function whose `cost_basis` is "unmeasured", adds up the reads the audit
lists for it (`meter_reads`):

- a read the table has a row for is priced at that row's milliseconds, times the count the audit wrote ("x2",
  "twice");
- a screen the table measures as a whole ("screen: ..." rows) is priced as that row;
- a write (save, delete, update, mark, move, restore, ...) is not priced: the meter measures reads. A row whose reads
  are all priced is "measured" with a note that its writes are extra;
- anything else (file reads, store opens, AV work) is not priced. A row with some priced reads and some unpriced
  ones is "partial": its cost is a lower bound. A row with no priced read stays "unmeasured".

Rows already "measured" or "estimated" are left alone: the table is a second opinion on them, not a replacement.

    scripts/rank_main_thread_reads.py --cost-table table.md --write     # price, then rewrite the .json and .md
    scripts/rank_main_thread_reads.py --render --write                  # only re-render the .md from the .json
    scripts/rank_main_thread_reads.py --cost-table table.md             # print what would move

stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JSON_PATH = ROOT / "docs" / "audit" / "main-thread-reads-ranked.json"
MD_PATH = ROOT / "docs" / "audit" / "main-thread-reads-ranked.md"

WEIGHT = {"rare": 1, "occasional": 3, "often": 10, "continuous": 30}
FREQUENCY_ORDER = {"continuous": 0, "often": 1, "occasional": 2, "rare": 3}
CLASS_ORDER = ["stays", "async-store", "targeted-refresh", "summary-read", "file-off-main", "cache-once", "label-task",
               "write-behind", "audio-off-main", "other"]
BAR_MS = 16.0   # one frame at 60 Hz: the "stays" bar the audit used

WRITE_PREFIXES = ("save", "delete", "update", "mark", "move", "restore", "invalidate", "settle", "reset", "seed")

# Names the audit used for a whole screen's reads -> the table row that measures it.
SCREENS = {
    "loadItemDetail": "screen: ItemDetailLoader.load(article)",
    "loadItemDetail reads": "screen: ItemDetailLoader.load(article)",
    "loadLibraryRows": "screen: LibraryReadSnapshot.read(store:)",
    "refreshLibraryRows": "screen: LibraryReadSnapshot.read(store:)",
    "refreshAudioPreparationPresentation": "screen: refreshAudioPreparationPresentation",
    "refreshMarginRows": "screen: refreshMarginRows (MarginCollection.build)",
}
SCREEN_LONG_FORM = re.compile(r"^listItemSummaries / loadPreparedAudioManifests / loadAudioPreparationJobs / loadSessions")


def parse_cost_table(text: str) -> dict[str, float]:
    """Row name -> milliseconds at the second scale (the Library's), from the markdown ReadCostReport writes."""
    table: dict[str, float] = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) < 8 or not cells[1].startswith("`"):
            continue
        try:
            table[cells[1].strip("`")] = float(cells[5])
        except ValueError:
            continue
    return table


def base_name(row_name: str) -> str:
    return re.split(r"[( ]", row_name, maxsplit=1)[0]


def lookup(name: str, qualifier: str, table: dict[str, float]) -> tuple[str, float] | None:
    """The table row for a read called `name`, preferring the row whose qualifier says the same thing."""
    candidates = [row for row in table if base_name(row) == name and not row.startswith("screen:")]
    if not candidates:
        return None
    if qualifier:
        for row in candidates:
            if qualifier in row:
                return row, table[row]
    for row in candidates:
        if row.endswith("()"):
            return row, table[row]
    return candidates[0], table[candidates[0]]


def count_in(entry: str) -> int:
    """How many times the audit says the read runs in one go: "x2", "(x5-6)" (the low end), "twice"."""
    match = re.search(r"\bx(\d+)", entry)
    if match:
        return int(match.group(1))
    if "twice" in entry:
        return 2
    return 1


def price_entry(entry: str, table: dict[str, float]) -> tuple[str, float, str]:
    """(kind, ms, matched row): kind is "read", "write" or "unpriced"."""
    if SCREEN_LONG_FORM.match(entry):
        key = SCREENS["refreshAudioPreparationPresentation"]
        return ("read", table[key] * count_in(entry), key) if key in table else ("unpriced", 0.0, "")
    match = re.match(r"[A-Za-z][A-Za-z0-9_]*", entry)
    name = match.group(0) if match else entry
    for screen_name, key in SCREENS.items():
        if entry == screen_name or entry.startswith(screen_name + " ") or entry.startswith(screen_name + "("):
            if key in table:
                return "read", table[key] * count_in(entry), key
    if name.startswith(WRITE_PREFIXES) or "(write" in entry:
        return "write", 0.0, ""
    qualifier_match = re.match(r"[A-Za-z0-9_]+\((itemId|sessionId|detail|article|mapped|all sessions|by item)", entry)
    qualifier = qualifier_match.group(1) if qualifier_match else ""
    if qualifier == "detail":
        qualifier = "article"
    if qualifier == "all sessions":
        qualifier = ""
    found = lookup(name, qualifier, table)
    if found is None:
        return "unpriced", 0.0, ""
    return "read", found[1] * count_in(entry), found[0]


def price_row(row: dict, table: dict[str, float]) -> dict | None:
    """The fields to change on `row`, or None when the table prices nothing of it."""
    priced = writes = unpriced = 0
    total = 0.0
    used: list[str] = []
    for entry in row["meter_reads"]:
        kind, ms, matched = price_entry(entry, table)
        if kind == "read":
            priced += 1
            total += ms
            used.append(matched)
        elif kind == "write":
            writes += 1
        else:
            unpriced += 1
    if priced == 0:
        return None
    ms = round(total, 2)
    note = "read cost table (#2513): " + " + ".join(sorted(set(used)))
    if writes:
        note += f"; {writes} write(s) not priced (the meter reads)"
    if unpriced:
        note += f"; {unpriced} read(s) not in the table, so this is a lower bound"
    return {
        "cost_ms_library": ms,
        "cost_basis": "partial" if unpriced else "measured",
        "cost_note": note,
        "score": round(ms * WEIGHT[row["frequency"]]),
    }


def apply_prices(rows: list[dict], table: dict[str, float]) -> list[dict]:
    """Prices every unmeasured row the table can. Returns the rows that changed, as {before, after}."""
    moved = []
    for row in rows:
        if row["cost_basis"] != "unmeasured":
            continue
        change = price_row(row, table)
        if change is None:
            continue
        before = {key: row.get(key) for key in change}
        row.update(change)
        moved.append({"function": row["function"], "fix_class": row["fix_class"], "before": before, "after": change})
    return moved


# ---------------------------------------------------------------- rendering

def short(text: str, limit: int) -> str:
    return (text or "").replace("\n", " ")[:limit].replace("|", "\\|")


def row_ref(row: dict) -> str:
    cites = [c for c in row.get("citations", []) if c.get("role") == "row"] or row.get("citations", [])
    if not cites:
        return Path(row["file"]).name
    return f"{Path(cites[0]['file']).name}:{cites[0]['line']}"


def name_of(row: dict) -> str:
    """The function, qualified by its file's type when the audit gave a bare name."""
    function = row["function"]
    return function if "." in function else f"{Path(row['file']).stem}.{function}"


def fmt_ms(ms) -> str:
    if ms is None:
        return ""
    return f"{ms:g}"


def render(rows: list[dict], header: str) -> str:
    out = [header.rstrip("\n"), ""]
    classes: dict[str, list] = {}
    for row in rows:
        entry = classes.setdefault(row["fix_class"], [0, 0, 0.0])
        entry[0] += 1
        entry[1] += row["scanner_rows"]
        entry[2] += row["score"] or 0
    out += ["## Fix classes (what clears the rows)", "", "| fix class | functions | scanner rows | summed score |",
            "|---|---:|---:|---:|"]
    for name, (functions, scanner, score) in sorted(classes.items(), key=lambda kv: (CLASS_ORDER.index(kv[0]) if kv[0] in CLASS_ORDER else 99, kv[0])):
        out.append(f"| {name} | {functions} | {scanner} | {round(score)} |")
    out.append("")

    priced = [r for r in rows if r["fix_class"] != "stays" and r["cost_ms_library"] is not None]
    priced.sort(key=lambda r: -(r["score"] or 0))
    out += [f"## Ranked: rows with a cost ({len(priced)} functions)", "",
            "| # | score | function | trigger | freq | ms | basis | fix class | fix | row |",
            "|---:|---:|---|---|---|---:|---|---|---|---|"]
    for number, r in enumerate(priced, 1):
        out.append(f"| {number} | {round(r['score'] or 0)} | `{name_of(r)}` | {short(r['trigger'], 90)} | {r['frequency']} | "
                   f"{fmt_ms(r['cost_ms_library'])} | {r['cost_basis']} | {r['fix_class']} | {short(r['fix_note'], 140)} | {row_ref(r)} |")
    out.append("")

    unpriced = [r for r in rows if r["fix_class"] != "stays" and r["cost_ms_library"] is None]
    unpriced.sort(key=lambda r: (FREQUENCY_ORDER[r["frequency"]], -r["scanner_rows"]))
    out += [f"## Ranked: rows whose cost the meter cannot price yet ({len(unpriced)} functions)", "",
            "These read nothing the read-cost table measures: file and AV work, store opens and writes, or reads of a "
            "table the fixture still does not seed. They are ordered by frequency, then by how many scanner rows they "
            "carry. Their cost is **unmeasured, not zero**.", "",
            "| # | function | trigger | freq | fix class | fix | rows | row |", "|---:|---|---|---|---|---|---:|---|"]
    for number, r in enumerate(unpriced, len(priced) + 1):
        out.append(f"| {number} | `{name_of(r)}` | {short(r['trigger'], 90)} | {r['frequency']} | {r['fix_class']} | "
                   f"{short(r['fix_note'], 140)} | {r['scanner_rows']} | {row_ref(r)} |")
    out.append("")

    stays = [r for r in rows if r["fix_class"] == "stays"]
    stays_priced = [r for r in stays if r["cost_ms_library"] is not None]
    over = [r for r in stays_priced if r["cost_ms_library"] >= BAR_MS]
    top = max((r["cost_ms_library"] for r in stays_priced if r not in over), default=0)
    bar_text = (f"the highest is {top:.1f} ms at Library size, under the {BAR_MS:g} ms bar"
                if not over else
                f"{len(over)} are over the {BAR_MS:g} ms bar ({', '.join('`' + name_of(r) + '`' for r in over)}), kept because "
                f"they are rare, DEBUG-only or a confirmed destructive action, as their reasons say; the highest of the rest is "
                f"{top:.1f} ms")
    out += [f"## Rows that stay ({len(stays)} functions, {sum(r['scanner_rows'] for r in stays)} scanner rows)", "",
            f"Each has a one-line reason. {len(stays_priced)} have a priced cost: {bar_text}. {len(stays) - len(stays_priced)} have no priced store read: "
            "a file or AV call that is trivially small, a by-id read, or a row that is not real main-thread work "
            "(Watch is not built, DEBUG-only, runs in a detached task or another process); the reason says which.", "",
            "| function | freq | ms | reason | row |", "|---|---|---:|---|---|"]
    for r in stays:
        out.append(f"| `{name_of(r)}` | {r['frequency']} | {fmt_ms(r['cost_ms_library'])} | {short(r['stay_reason'], 200)} | {row_ref(r)} |")
    out.append("")
    out += what_changed(rows)
    return "\n".join(out)


def what_changed(rows: list[dict]) -> list[str]:
    """The section that says what the read-cost table priced, derived from the rows' own `cost_note`."""
    by_table = [r for r in rows if "#2513" in (r.get("cost_note") or "")]
    if not by_table:
        return []
    measured = [r for r in by_table if r["cost_basis"] == "measured"]
    partial = [r for r in by_table if r["cost_basis"] == "partial"]
    left = [r for r in rows if r["fix_class"] != "stays" and r["cost_ms_library"] is None]
    movers = sorted((r for r in by_table if r["fix_class"] != "stays"), key=lambda r: -(r["score"] or 0))[:10]
    out = ["## What the read-cost table priced (#2513)", "",
           f"{len(by_table)} functions that were unmeasured now carry a cost from the read-cost table ({len(measured)} measured, "
           f"{len(partial)} partial, a lower bound because a read is not in the table). {len(left)} non-stay functions are still "
           "unmeasured: they have no store read the table prices. Notes on how to read the new numbers:", "",
           "- A function's cost is the sum of the reads the audit listed for it, each at the table's Library-scale milliseconds. "
           "A by-id read with no qualifier is priced at the table's row for it (the mapped podcast or one article), so it is a typical "
           "case, not the worst. Writes are not priced.",
           "- The seeded tables are assumptions (see `LibraryFixtureTables.swift`): no export of the owner's job, manifest or "
           "download counts exists. Treat a cost that rests on them (prepared audio manifests above all) as an order of magnitude "
           "until a Mac-side count replaces the assumption.",
           "- Rows already `measured` or `estimated` were left as they were.", "",
           "Highest scores among the newly priced functions:", "",
           "| score | function | freq | ms | fix class |", "|---:|---|---|---:|---|"]
    for r in movers:
        out.append(f"| {round(r['score'] or 0)} | `{name_of(r)}` | {r['frequency']} | {fmt_ms(r['cost_ms_library'])} | {r['fix_class']} |")
    out.append("")
    return out


def header_of(md_text: str) -> str:
    """Everything above the first '## ' heading."""
    return md_text.split("\n## ", 1)[0]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cost-table", type=Path, help="markdown table written by testReadCostTableAtEveryScale")
    parser.add_argument("--render", action="store_true", help="only re-render the .md from the .json")
    parser.add_argument("--write", action="store_true", help="rewrite the .json and .md (default: print a summary)")
    parser.add_argument("--json", type=Path, default=JSON_PATH)
    parser.add_argument("--md", type=Path, default=MD_PATH)
    args = parser.parse_args(argv)

    rows = json.loads(args.json.read_text())
    moved: list[dict] = []
    if args.cost_table:
        moved = apply_prices(rows, parse_cost_table(args.cost_table.read_text()))
    elif not args.render:
        parser.error("give --cost-table or --render")

    for entry in moved:
        after = entry["after"]
        print(f"{entry['function']:70} {entry['fix_class']:18} {after['cost_basis']:8} {after['cost_ms_library']:>8g} ms  score {after['score']}")
    print(f"{len(moved)} function(s) priced", file=sys.stderr)

    if args.write:
        args.json.write_text(json.dumps(rows, indent=1))
        old_md = args.md.read_text()
        args.md.write_text(render(rows, header_of(old_md)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
