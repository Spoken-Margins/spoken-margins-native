"""Remember a SessionKit package-test pass, so a later lane run on the same inputs can skip them (#1328).

The SessionKit build and tests are about 70% of a host-test run. A run that leaves the package alone
(60 of the 132 merges into next from 10-07 to 10-10 didn't touch Packages/SessionKit/) repeats a result
that was already proven. The record is a digest of everything the package tests read, plus the toolchain
and the test runner itself. Nothing is skipped on a guess about what a diff touches: the digest is of the
tree's content, so a change to any input starts a new key and the tests run.

A run records a pass only after the whole package step passed. A lane run that was given the PR's
changed paths looks the key up before building. Runs without that list (the Test Desk's run on next, a
session's own run) never skip, so they remain the backstop for a reader this list misses.
"""
import calendar
import hashlib
import json
import os
import platform
import subprocess
import tempfile
import time
from pathlib import Path

# What the SessionKit tests read: the package itself, and the files its tests open by path from the
# repository root. tests/test_sessionkit_pass.py scans the test and source files for paths outside the
# package and fails when one isn't covered here, so a new reader can't be missed silently.
READS = (
    'Packages/SessionKit/',
    'Contracts/',
    # Source-scraping tests (appSource(...), Gate1AppModel.swift) and the shipped-reader gate that scans the app tests.
    'App/SpokenMarginsApp/Sources/SpokenMarginsApp/',
    'App/SpokenMarginsAppTests/',
    # Supertonic's narration tests read its model from artifacts/voice-catalog/files/ (the supertonicModel input),
    # which is git-ignored: `scripts/voice-catalog fetch` writes it, each file pinned by sha256 in
    # Contracts/voice-models/sources.json, which Contracts/ above covers (#1820).
    # The Kitten fallback voice's tests read the bundled model (the voiceAssets input) and the front end's test vectors (#849).
    'App/SpokenMarginsApp/Resources/Kitten/',
    # Supertonic's pinned hashes (asset-manifest.json) and the catalog snapshot the download card reads (#1820).
    'App/SpokenMarginsApp/Resources/Supertonic/',
    'App/SpokenMarginsApp/Resources/VoiceCatalog/',
    'research/C2/frontend/',
    'research/B2/',
    'research/B4/',
    # Pocket's renderer tests read the committed passages, the PyTorch reference results, and the scoring script
    # (the weights and the Python environment they also use are git-ignored; see NOT_REPOSITORY_READS).
    'research/C2/pocket/',
    'research/C2/passages.json',
    'research/C2/results/darwin/',
    # The published source catalog the catalog tests decode.
    'Site/onboarding/catalog/',
    # The guided tour manifest test decodes the manifest and checks the clip it names (#2051).
    'Site/onboarding/v1/',
    # The trace tests find the repository root by its README.md and traces/ folder.
    'README.md',
    'traces/',
    # Contracts/fixtures and research/B2/fixtures are what the tests name as "fixtures"; the top-level folder
    # is cheap to hash, so a future read of it can't slip past the key.
    'fixtures/',
)
# How the tests run: a change to any of these changes what "the package tests passed" means.
RUNNERS = (
    'scripts/run-sessionkit-tests.sh',
    'scripts/host-test-lane',
    'scripts/verify-tests.py',
    'scripts/sessionkit_pass.py',
)
KEEP = 100  # records kept; each is a few hundred bytes
# A record older than this is not honored, so every Mac runs the whole package at least daily. The scheduled run on
# The trunk's tip is --plan app and never runs these tests, so this bounds how long an input missing from READS can hide.
MAX_AGE_SECONDS = 24 * 3600


def listed(root):
    out = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', *READS, *RUNNERS],
                         cwd=root, capture_output=True, check=True).stdout
    return sorted({path.decode() for path in out.split(b'\0') if path})


def inputs_digest(root):
    """sha256 over the path and content of every file the package tests read, or the marker of a deleted one."""
    root = Path(root)
    digest = hashlib.sha256()
    count = 0
    for relative in listed(root):
        path = root / relative
        digest.update(relative.encode() + b'\0')
        digest.update(path.read_bytes() if path.is_file() else b'<deleted>')
        digest.update(b'\0')
        count += 1
    if not count:
        raise ValueError('no SessionKit inputs found')
    return digest.hexdigest(), count


def toolchain(run=subprocess.run):
    """What builds and runs the tests: Swift, macOS and the machine. None when Swift can't say (not on this machine)."""
    try:
        done = run(['swift', '--version'], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode or not (done.stdout + done.stderr).strip():
        return None
    return '\n'.join([(done.stdout + done.stderr).strip(), platform.machine(), platform.mac_ver()[0]])


def key(root, toolchain_identity):
    """The key for the tree under test, or None when the toolchain is unknown or the inputs can't be read."""
    if not toolchain_identity:
        return None
    try:
        digest, _ = inputs_digest(root)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return hashlib.sha256((digest + '\0' + toolchain_identity).encode()).hexdigest()


def passes_dir(state):
    return Path(state) / 'sessionkit-pass'


def find(state, key_):
    """The record of a pass for this key, or None."""
    if not key_:
        return None
    try:
        record = json.loads((passes_dir(state) / f'{key_}.json').read_text())
    except (OSError, ValueError):
        return None
    if not (isinstance(record, dict) and record.get('key') == key_):
        return None
    try:
        age = time.time() - calendar.timegm(time.strptime(record['passed_at'], '%Y-%m-%dT%H:%M:%SZ'))
    except (KeyError, TypeError, ValueError):
        return None
    return record if -300 <= age <= MAX_AGE_SECONDS else None


def record(state, key_, **details):
    """Write the record of a pass (atomically) and drop the oldest beyond KEEP. Best effort: never fails a run."""
    if not key_:
        return None
    folder = passes_dir(state)
    entry = {'key': key_, 'passed_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), **details}
    try:
        folder.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile('w', dir=folder, suffix='.tmp', delete=False) as handle:
            handle.write(json.dumps(entry, indent=2) + '\n')
        os.replace(handle.name, folder / f'{key_}.json')
        old = sorted(folder.glob('*.json'), key=lambda p: p.stat().st_mtime, reverse=True)[KEEP:]
        for path in old:
            path.unlink(missing_ok=True)
    except OSError:
        return None
    return entry
