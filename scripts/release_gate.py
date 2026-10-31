#!/usr/bin/env python3
"""Refuse an external TestFlight build with share-link creation on while the gate record is incomplete (#2236).

Owner's calls, 2026-10-20 and 2026-10-28 (docs/decisions.md): share-link creation may be on for the internal
group, but no such build goes to the external group until

  1. the Illinois LLC exists;
  2. the DMCA designated agent is registered in the LLC's name (number and date recorded, not past the
     three-year registration, 37 C.F.R. 201.38) and the designated-agent page is live;
  3. insurance is in place, or the owner's waiver holds: no revenue and fewer than 100 external testers.
     Crossing either limit without recorded insurance refuses the build.

Run it in the release steps before a build is assigned to the external group (AGENTS.md "Releasing a build"):

  scripts/release_gate.py --destination external path/to/SpokenMargins.xcarchive

The build argument is an archive, an app bundle or an Info.plist. Share-link creation is on when the plist's
`SMShareLinkCreation` is true. A missing key means off (builds before the build setting exist); a key that
isn't a boolean refuses the build. A build with creation off is always allowed, and so is any build for the
internal group. Exit 0 allowed, 1 refused, 2 the inputs couldn't be read. Stdlib only.
"""
from __future__ import annotations

import argparse
import datetime
import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RECORD = ROOT / "docs" / "legal" / "gate-record.json"
PLIST_KEY = "SMShareLinkCreation"
TESTER_LIMIT = 100  # the waiver holds below this many external testers


class InputError(Exception):
    """The build or the record couldn't be read, so no verdict is possible."""


def share_links_on(plist: dict) -> tuple[bool, str | None]:
    """(creation is on, a problem). A non-boolean value is a problem and counts as on."""
    if PLIST_KEY not in plist:
        return False, None
    value = plist[PLIST_KEY]
    if isinstance(value, bool):
        return value, None
    return True, f"{PLIST_KEY} is {value!r}, not a boolean"


def find_info_plist(path: Path) -> Path:
    if path.is_file():
        return path
    if path.is_dir():
        if path.suffix == ".xcarchive":
            apps = sorted((path / "Products" / "Applications").glob("*.app"))
            if len(apps) != 1:
                raise InputError(f"expected one app in {path}/Products/Applications, found {len(apps)}")
            path = apps[0]
        plist = path / "Info.plist"
        if plist.is_file():
            return plist
    raise InputError(f"no Info.plist found for {path}")


def read_plist(path: Path) -> dict:
    try:
        with find_info_plist(path).open("rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise InputError(f"can't read the build's Info.plist: {error}") from error
    if not isinstance(data, dict):
        raise InputError("the build's Info.plist isn't a dictionary")
    return data


def read_record(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise InputError(f"can't read the gate record {path}: {error}") from error
    if not isinstance(data, dict):
        raise InputError(f"the gate record {path} isn't an object")
    return data


def _section(record: dict, name: str) -> dict:
    section = record.get(name)
    return section if isinstance(section, dict) else {}


def _text(value) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _date(value) -> datetime.date | None:
    if not _text(value):
        return None
    try:
        return datetime.date.fromisoformat(value.strip())
    except ValueError:
        return None


def registration_expires(registered_on: datetime.date) -> datetime.date:
    """The day the three-year designation lapses (Feb 29 rolls to Mar 1)."""
    try:
        return registered_on.replace(year=registered_on.year + 3)
    except ValueError:
        return datetime.date(registered_on.year + 3, 3, 1)


def missing_items(record: dict, today: datetime.date) -> list[str]:
    """What keeps the gate closed. Empty means complete. Anything unclear counts as missing."""
    missing = []
    if _section(record, "llc").get("formed") is not True:
        missing.append("the Illinois LLC isn't recorded as formed")

    agent = _section(record, "dmca_agent")
    if agent.get("registered") is not True:
        missing.append("the DMCA designated agent isn't recorded as registered")
    if not _text(agent.get("registration_number")):
        missing.append("the agent registration number is missing")
    registered_on = _date(agent.get("registered_on"))
    if registered_on is None:
        missing.append("the agent registration date is missing or isn't YYYY-MM-DD")
    elif today >= registration_expires(registered_on):
        missing.append(f"the agent registration lapsed on {registration_expires(registered_on)}; renew it")
    if not _text(agent.get("page_url")) or agent.get("page_live") is not True:
        missing.append("the designated-agent page URL isn't recorded as live")

    if _section(record, "insurance").get("in_place") is not True:
        waiver = _section(record, "waiver")
        testers = waiver.get("external_testers")
        if _date(waiver.get("granted_on")) is None:
            missing.append("no insurance and no dated waiver recorded")
        elif waiver.get("no_revenue") is not True:
            missing.append("no insurance, and the waiver's no-revenue condition no longer holds")
        elif not isinstance(testers, int) or isinstance(testers, bool) or testers < 0:
            missing.append("no insurance, and the external tester count isn't a number")
        elif testers >= TESTER_LIMIT:
            missing.append(f"no insurance, and {testers} external testers is not under {TESTER_LIMIT}")
    return missing


def decide(destination: str, plist: dict, record: dict, today: datetime.date) -> tuple[bool, list[str]]:
    """(allowed, reasons). Reasons explain a refusal, or note why an allowed build passed."""
    if destination != "external":
        return True, ["internal group: the gate doesn't apply"]
    on, problem = share_links_on(plist)
    if not on:
        return True, [f"share-link creation is off ({PLIST_KEY})"]
    reasons = [problem] if problem else []
    reasons += missing_items(record, today)
    if reasons:
        return False, ["share-link creation is on for an external build, and the gate is open:"] + reasons
    return True, ["share-link creation is on and the gate record is complete"]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("build", type=Path, help="an .xcarchive, a .app bundle or an Info.plist")
    parser.add_argument("--destination", required=True, choices=["external", "internal"],
                        help="the TestFlight group the build is about to be assigned to")
    parser.add_argument("--record", type=Path, default=DEFAULT_RECORD, help="the gate record (default: %(default)s)")
    parser.add_argument("--today", type=datetime.date.fromisoformat, default=None, help="override today's date (tests)")
    args = parser.parse_args(argv)
    try:
        plist = read_plist(args.build)
        record = read_record(args.record)
    except InputError as error:
        print(f"release gate: {error}", file=sys.stderr)
        return 2
    allowed, reasons = decide(args.destination, plist, record, args.today or datetime.date.today())
    stream = sys.stdout if allowed else sys.stderr
    print(("release gate: allowed. " if allowed else "release gate: REFUSED. ") + reasons[0], file=stream)
    for reason in reasons[1:]:
        print(f"  - {reason}", file=stream)
    return 0 if allowed else 1


if __name__ == "__main__":
    sys.exit(main())
