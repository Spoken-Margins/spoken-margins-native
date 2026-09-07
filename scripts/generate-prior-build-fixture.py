#!/usr/bin/env python3
"""Explicit fixture maintenance; never runs as part of ordinary verification."""
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RELEASES = {19: '738c743e202f5e700f4d6975adee52862f63c69f',
            25: '3294438ffba790fa281509bc1fa7b51e379a6c71'}
OUTPUT = ROOT / 'Contracts/fixtures/persistence'


def generate(build, revision):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='spoken-margins-prior-build-') as temporary:
        package = Path(temporary)
        for target in ('SessionKit', 'SessionKitPersistence'):
            prefix = f'Packages/SessionKit/Sources/{target}/'
            paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', revision, prefix], cwd=ROOT, text=True).splitlines()
            for relative in paths:
                destination = package / 'Sources' / target / relative.removeprefix(prefix)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(subprocess.check_output(['git', 'show', f'{revision}:{relative}'], cwd=ROOT))
        (package / 'Sources/Generate').mkdir()
        shutil.copyfile(ROOT / 'scripts/fixtures/generate-prior-build.swift', package / 'Sources/Generate/main.swift')
        (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PriorBuildFixture", platforms: [.macOS(.v15)], targets: [
    .target(name: "SessionKit", swiftSettings: [.unsafeFlags(["-enable-testing"])]),
    .target(name: "SessionKitPersistence", dependencies: ["SessionKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "Generate", dependencies: ["SessionKit", "SessionKitPersistence"])
])
''')
        database = package / f'build{build}.sqlite'
        subprocess.run(['swift', 'run', '--package-path', str(package), 'Generate', str(database)], check=True)
        with sqlite3.connect(database) as connection:
            connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            connection.execute('PRAGMA journal_mode=DELETE')  # Portable, standalone fixture; no WAL sidecars.
            version = int(connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0])
        shutil.copyfile(database, OUTPUT / database.name)
        (OUTPUT / f'build{build}.json').write_text(json.dumps({
            'sourceRevision': revision, 'sourceTag': f'testflight/0.1-build-{build}',
            'database': database.name, 'schemaVersion': version,
            'sha256': hashlib.sha256(database.read_bytes()).hexdigest(),
            'origin': 'Synthetic library written by unmodified prior-release SessionKit and persistence sources on macOS; not device-captured data.',
            'generator': 'scripts/generate-prior-build-fixture.py'
        }, indent=2) + '\n')


if __name__ == '__main__':
    for build, revision in RELEASES.items():
        generate(build, revision)
