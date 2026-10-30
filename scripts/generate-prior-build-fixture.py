#!/usr/bin/env python3
"""Explicit fixture maintenance; never runs as part of ordinary verification.

    generate-prior-build-fixture.py [BUILD ...]   # default: every build below
"""
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RELEASES = {19: '738c743e202f5e700f4d6975adee52862f63c69f',
            25: '3294438ffba790fa281509bc1fa7b51e379a6c71',
            29: 'fcc4974feb082d0fbf2e608ef2792427fefafc9a',
            32: 'ec940321c8505c39430b18324b76f4fd9a183294',
            34: '485b144961133f0baeaa8717821a252c294dddbe'}
# Build 29's Library holds podcasts as that build left them (#352), and Build 34's a podcast with a download and
# a linked episode (#1900); the others hold one article read in two sessions.
GENERATORS = {29: 'generate-build29-podcasts.swift', 34: 'generate-build34-podcasts.swift'}
OUTPUT = ROOT / 'Contracts/fixtures/persistence'
LINUX = platform.system() == 'Linux'


def linux_shims(package):
    """CryptoKit, SQLite3 and URLSession are Apple modules. On Linux, swift-crypto
    stands in for CryptoKit, a system-library target for SQLite3, and
    FoundationNetworking is imported beside Foundation. The sources are otherwise
    unchanged."""
    (package / 'Sources/SQLite3').mkdir(parents=True)
    (package / 'Sources/SQLite3/module.modulemap').write_text('module SQLite3 [system] {\n    header "shim.h"\n    link "sqlite3"\n    export *\n}\n')
    (package / 'Sources/SQLite3/shim.h').write_text('#include <sqlite3.h>\n')
    (package / 'Sources/CryptoKit').mkdir(parents=True)
    (package / 'Sources/CryptoKit/CryptoKit.swift').write_text('@_exported import Crypto\n')
    for source in (package / 'Sources').glob('SessionKit*/**/*.swift'):
        source.write_text(re.sub(r'^import Foundation$', 'import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif',
                                 source.read_text(), count=1, flags=re.M))


def package_manifest():
    if not LINUX:
        return '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PriorBuildFixture", platforms: [.macOS(.v15)], targets: [
    .target(name: "SessionKit", swiftSettings: [.unsafeFlags(["-enable-testing"])]),
    .target(name: "SessionKitPersistence", dependencies: ["SessionKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "Generate", dependencies: ["SessionKit", "SessionKitPersistence"])
])
'''
    return '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PriorBuildFixture",
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
    targets: [
    .systemLibrary(name: "SQLite3"),
    .target(name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
    .target(name: "SessionKit", dependencies: ["CryptoKit"], swiftSettings: [.unsafeFlags(["-enable-testing"])]),
    .target(name: "SessionKitPersistence", dependencies: ["SessionKit", "SQLite3", "CryptoKit"]),
    .executableTarget(name: "Generate", dependencies: ["SessionKit", "SessionKitPersistence"])
])
'''


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
        if LINUX:
            linux_shims(package)
        (package / 'Sources/Generate').mkdir()
        shutil.copyfile(ROOT / 'scripts/fixtures' / GENERATORS.get(build, 'generate-prior-build.swift'), package / 'Sources/Generate/main.swift')
        (package / 'Package.swift').write_text(package_manifest())
        database = package / f'build{build}.sqlite'
        subprocess.run(['swift', 'run', '--package-path', str(package), 'Generate', str(database)], check=True)
        with sqlite3.connect(database) as connection:
            connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            connection.execute('PRAGMA journal_mode=DELETE')  # Portable, standalone fixture; no WAL sidecars.
            version = int(connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0])
        shutil.copyfile(database, OUTPUT / database.name)
        host = 'Linux, with the shims linux_shims() names' if LINUX else 'macOS'
        (OUTPUT / f'build{build}.json').write_text(json.dumps({
            'sourceRevision': revision, 'sourceTag': f'testflight/0.1-build-{build}',
            'database': database.name, 'schemaVersion': version,
            'sha256': hashlib.sha256(database.read_bytes()).hexdigest(),
            'origin': f'Synthetic library written by unmodified prior-release SessionKit and persistence sources on {host}; not device-captured data.',
            'generator': 'scripts/generate-prior-build-fixture.py'
        }, indent=2) + '\n')


if __name__ == '__main__':
    for build in [int(argument) for argument in sys.argv[1:]] or RELEASES:
        generate(build, RELEASES[build])
