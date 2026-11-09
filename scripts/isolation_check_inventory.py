#!/usr/bin/env python3
"""List every Swift isolation check in a built app, named by function and source line (#3513).

Under Swift 6 a main-actor closure handed to an Apple API whose header doesn't say `@Sendable` keeps its main-actor
isolation, and the compiler puts a check at its start (`bl _swift_task_isCurrentExecutor`). If the API calls it on
another thread, the check stops the app. That is how the Watch app crashed at every launch (#2964): the reply handler
of `WCSession.sendMessage` ran on a WatchConnectivity queue. Nothing in the source text marks these sites, so the
inventory comes from the compiled binary: disassemble each Mach-O, find each call to the check, name the function it
sits in, and ask `atos` for the source line (inlined frames included) from the dSYM.

  scripts/isolation_check_inventory.py BUILD_PRODUCTS_DIR             a table: binary, function, source line
  scripts/isolation_check_inventory.py BUILD_PRODUCTS_DIR --json F    every site to F

BUILD_PRODUCTS_DIR is a Release (or Debug) `Build/Products/<config>-iphoneos` folder that holds the `.app` and its
`.dSYM` bundles (build with DEBUG_INFORMATION_FORMAT=dwarf-with-dsym). A site is a candidate when a system framework
calls the function, not our own code: a SwiftUI body or a `@MainActor` method called from `@MainActor` code is
checked and fine. The verdicts for the phone app, its extensions and the Watch app are on #3513; the source guard
that keeps new instances out is scripts/system_callback_isolation.py. Rerun this when code hands a closure to a kind
of system callback that guard doesn't list yet.

Stdlib only; needs Xcode's command-line tools (otool, atos, swift-demangle). Takes about a minute.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

CHECK = re.compile(r'^([0-9a-f]+)\s+bl\s.*symbol stub for: _swift_task_isCurrentExecutor$')
FUNCTION = re.compile(r'^([^\s:][^\s]*):$')


def mach_os(products: Path):
    """(binary, dSYM DWARF file) for each app and extension executable in the products folder."""
    seen = set()
    # Embedded copies first (the .app and its PlugIns, Watch), so a loose duplicate beside them is skipped.
    for bundle in sorted(list(products.rglob('*.app')) + list(products.rglob('*.appex'))):
        if '.dSYM' in str(bundle) or bundle.is_symlink():
            continue
        plist = bundle / 'Info.plist'
        if not plist.exists():
            continue
        name = subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleExecutable', str(plist)],
                              capture_output=True, text=True).stdout.strip()
        binary = bundle / name
        if not binary.exists() or name in seen:
            continue
        seen.add(name)
        # The Watch app's dSYM sits beside its own products folder (Release-watchos), not inside the phone's.
        dsyms = [folder / f'{bundle.name}.dSYM' / 'Contents' / 'Resources' / 'DWARF' / name
                 for folder in [products, *sorted(products.parent.iterdir())]]
        yield binary, next((d for d in dsyms if d.exists()), None)


def check_sites(binary: Path):
    """(address, enclosing symbol) for each call to the isolation check in the binary's text."""
    # otool names the call through its stub on every architecture we ship (objdump misses the phone's stubs).
    # The Watch app is fat (arm64 and arm64_32); the arm64 slice carries the same closures.
    out = subprocess.run(['xcrun', 'otool', '-arch', 'arm64', '-tvV', str(binary)],
                         capture_output=True, text=True, check=True).stdout
    current, sites = '?', []
    for line in out.splitlines()[1:]:
        match = FUNCTION.match(line)
        if match:
            current = match.group(1)
            continue
        match = CHECK.match(line)
        if match:
            sites.append((int(match.group(1), 16), current))
    return sites


def demangle(names):
    if not names:
        return []
    out = subprocess.run(['xcrun', 'swift-demangle', '--simplified'], input='\n'.join(names),
                         capture_output=True, text=True).stdout.splitlines()
    return out if len(out) == len(names) else names


FRAME = re.compile(r'^(.*) \(in [^)]+\) (?:\(([^()]*):(\d+)\)|\+ \d+)$')


def frame_source(block):
    """The innermost function atos names, and the outermost real `file:line` among the inlined frames.

    The check sits in a compiler-made prologue (line 0, `<compiler-generated>`), so the line that says where the
    closure was written is the first real one walking outward."""
    names, where = [], ''
    for line in block:
        match = FRAME.match(line.strip())
        if not match:
            continue
        names.append(match.group(1))
        file, number = match.group(2), match.group(3)
        if file and number and number != '0' and not file.startswith(('/<compiler', '<stdin', '@__swiftmacro')):
            where = where or f'{Path(file).name}:{number}'
    return (names[0] if names else ''), where


def source_lines(dsym: Path | None, addresses):
    """(innermost function, source line) from the dSYM for each address, inlined frames included."""
    if dsym is None or not addresses:
        return [('', '') for _ in addresses]
    out = subprocess.run(['xcrun', 'atos', '-o', str(dsym), '-arch', 'arm64', '-l', '0x100000000', '-i',
                          *[hex(a) for a in addresses]], capture_output=True, text=True).stdout
    # With -i, atos prints one block per address, separated by a blank line.
    blocks = [b.strip().splitlines() for b in out.strip().split('\n\n')]
    if len(blocks) != len(addresses):
        return [('', '') for _ in addresses]
    return [frame_source(block) for block in blocks]


def inventory(products: Path):
    rows = []
    for binary, dsym in mach_os(products):
        sites = check_sites(binary)
        names = demangle([s[1] for s in sites])
        lines = source_lines(dsym, [s[0] for s in sites])
        for (address, mangled), name, (inner, where) in zip(sites, names, lines):
            rows.append({'binary': binary.name, 'address': hex(address), 'symbol': mangled, 'function': name,
                         'inlined': inner if inner and inner != name else '', 'source': where})
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('products', type=Path)
    parser.add_argument('--json', type=Path)
    args = parser.parse_args(argv)
    rows = inventory(args.products)
    if args.json:
        args.json.write_text(json.dumps(rows, indent=1) + '\n')
    for row in rows:
        print(f"{row['binary']}\t{row['inlined'] or row['function']}\t{row['source']}")
    print(f'{len(rows)} isolation checks', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
