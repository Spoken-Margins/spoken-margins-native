#!/usr/bin/env python3
"""Fail when a secret, key file, provisioning profile or build output is tracked (#1838).

Once the repository is public, these are incidents rather than untidiness. The check reads the
tracked files (`git ls-files`) and reports, by path and line, never the matched text.

Known harmless cases (test vectors, a public certificate) are listed in
scripts/public-tree-allowlist.txt, one `path: reason` per line; an entry without a reason, or for a
file that is no longer tracked, fails too, so the list stays honest.

Home-folder paths, the owner's email and Mac model names are not flagged: the owner cleared them to
stay public (#1383, 2026-10-16).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = Path('scripts/public-tree-allowlist.txt')

FORBIDDEN_EXTENSIONS = {
    '.mobileprovision': 'provisioning profile',
    '.provisionprofile': 'provisioning profile',
    '.p12': 'signing identity',
    '.p8': 'signing key',
    '.pem': 'key or certificate file',
    '.pfx': 'signing identity',
}
SECRET_PATTERNS = (
    ('private key block', re.compile(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----')),
    ('Anthropic key', re.compile(r'sk-ant-[A-Za-z0-9_-]{8,}')),
    ('GitHub token', re.compile(r'gh[pousr]_[A-Za-z0-9]{36,}')),
    ('GitHub token', re.compile(r'github_pat_[A-Za-z0-9_]{22,}')),
    ('AWS access key', re.compile(r'A(?:KIA|SIA)[0-9A-Z]{16}')),
)
BINARY_SNIFF_BYTES = 8192
MAX_SCAN_BYTES = 20 * 1024 * 1024


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(['git', 'ls-files', '-z'], cwd=root, check=True, capture_output=True).stdout
    return [name for name in out.decode('utf-8', 'surrogateescape').split('\0') if name]


def parse_allowlist(text: str) -> tuple[dict[str, str], list[str]]:
    """Return ({path: reason}, problems). Blank lines and lines starting with # are ignored."""
    entries: dict[str, str] = {}
    problems: list[str] = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        path, _, reason = line.partition(':')
        path, reason = path.strip(), reason.strip()
        if not path:
            problems.append(f'{ALLOWLIST}:{number}: empty path')
        elif not reason:
            problems.append(f'{ALLOWLIST}:{number}: {path} has no reason')
        else:
            entries[path] = reason
    return entries, problems


def path_problem(name: str) -> str | None:
    parts = name.lower().split('/')
    base = parts[-1]
    if 'artifacts' in parts[:-1]:
        return 'build or test output under artifacts/'
    if any(part.endswith('.xcarchive') for part in parts):
        return 'Xcode archive'
    if base.endswith('.env') or (base.startswith('.env.') and not base.endswith(('.example', '.sample', '.template'))):
        return 'environment file'
    return FORBIDDEN_EXTENSIONS.get(Path(base).suffix.lower())


def content_problems(path: Path) -> list[tuple[int, str]]:
    """Return (line, kind) for each secret-shaped string in a text file; binary files return nothing."""
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_SCAN_BYTES:
            return []
        with path.open('rb') as handle:
            if b'\0' in handle.read(BINARY_SNIFF_BYTES):
                return []
        data = path.read_bytes()
    except OSError:
        return []
    found: list[tuple[int, str]] = []
    for number, line in enumerate(data.decode('utf-8', 'replace').split('\n'), 1):
        for kind, pattern in SECRET_PATTERNS:
            if pattern.search(line):
                found.append((number, kind))
    return found


def check(root: Path, allowlist_text: str) -> list[str]:
    allowed, problems = parse_allowlist(allowlist_text)
    names = tracked_files(root)
    tracked = set(names)
    for name in sorted(set(allowed) - tracked):
        problems.append(f'{ALLOWLIST}: {name} is listed but not tracked; remove the entry')
    for name in names:
        if name in allowed:
            continue
        kind = path_problem(name)
        if kind:
            problems.append(f'{name}: {kind}')
            continue
        for line, kind in content_problems(root / name):
            problems.append(f'{name}:{line}: {kind}')
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    allowlist = args.root / ALLOWLIST
    text = allowlist.read_text(encoding='utf-8') if allowlist.exists() else ''
    problems = check(args.root, text)
    if problems:
        print(f'Public tree check failed ({len(problems)}):', file=sys.stderr)
        for problem in problems:
            print(f'  {problem}', file=sys.stderr)
        print('Remove the file, or add an allowlist entry with a reason if it is a harmless test vector.',
              file=sys.stderr)
        return 1
    print(f'Public tree check passed: {len(tracked_files(args.root))} tracked files scanned, '
          f'{len(parse_allowlist(text)[0])} allowlisted.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
