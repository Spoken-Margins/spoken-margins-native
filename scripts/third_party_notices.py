#!/usr/bin/env python3
"""THIRD_PARTY_NOTICES.md from docs/legal/third-party-components.json, and a check that nothing is missing (#1823).

The manifest names every third-party component the repository ships, downloads, builds with or carries as data.
This script fails when:
- a Swift package, an npm package, a Python dev requirement or a package compiled into the page-reading scripts
  has no entry (or an entry at another version);
- a model or font file, or a folder the app bundles (project.yml), sits under no entry's paths;
- an app target bundles a Contracts/fixtures or Contracts/traces path no app source reads from the bundle;
- a dependency manifest (package.json, requirements*.txt, Package.swift, go.mod) is claimed by no entry, or a
  Go module requires an outside module;
- a path or licence file an entry names does not exist;
- THIRD_PARTY_NOTICES.md is not what the manifest generates.

    python3 scripts/third_party_notices.py            # check
    python3 scripts/third_party_notices.py --write    # regenerate THIRD_PARTY_NOTICES.md
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path('docs/legal/third-party-components.json')
OUTPUT = Path('THIRD_PARTY_NOTICES.md')
BUNDLED_JS_NOTICES = Path('App/SharedResources/BundledJavaScript-NOTICES.txt')

DISTRIBUTIONS = ('bundled', 'downloaded', 'tool', 'content')
HEADINGS = {
    'bundled': ('Ships in the app',
                'These are compiled into or packaged with the app, and some are also stored in this repository.'),
    'downloaded': ('Downloaded, not distributed here',
                   'Fetched on request. They are not in this repository or in the app. '
                   'Where the voice catalog (#1818) publishes the current address and licence text, it is the reference.'),
    'tool': ('Build, test and research tools',
             'Used to build, test or research. None of them ships in the app.'),
    'content': ('Third-party content in the repository',
                'Data and text captured from other people\'s work. This project does not license it; the rights stay with their owners.'),
}
# Model and font files only. Artwork, audio and images are not checked: the manifest's "about" says so.
MODEL_SUFFIXES = {'.ttf', '.otf', '.ttc', '.woff', '.woff2', '.eot', '.onnx', '.ort', '.mlmodel', '.mlmodelc',
                  '.gguf', '.safetensors', '.npz', '.tflite', '.pb', '.h5', '.pkl', '.model', '.spm', '.data',
                  '.bin', '.f32', '.pt', '.pth'}
MANIFEST_NAMES = re.compile(r'^(package\.json|requirements[^/]*\.txt|go\.mod|Package\.swift|Package\.resolved|'
                            r'Podfile|Cartfile|Gemfile|pyproject\.toml|Cargo\.toml)$')
# Only used when git can't list the files. Worktrees (.claude/worktrees) and build leftovers are not the repository.
SKIPPED_DIRS = {'.git', '.claude', 'node_modules', '.build', '.swiftpm', '.venv', 'artifacts', 'DerivedData', 'dist', '.next'}
# These two files are kept as copies beside each extension's scripts and must stay identical.
COPIES = (('App/SharedResources/BundledJavaScript-NOTICES.txt',
           'App/SpokenMarginsShareExtension/Resources/BundledJavaScript-NOTICES.txt'),
          ('App/SharedResources/Defuddle-LICENSE.txt',
           'App/SpokenMarginsShareExtension/Resources/Defuddle-LICENSE.txt'))


def load(root):
    return json.loads((root / MANIFEST).read_text())


def walk(root):
    """Every file the repository tracks, as posix paths relative to root. Without git: every file but build and tool folders."""
    try:
        # Only when root is itself a checkout: a folder inside another repository (a test's temp copy under the
        # lane's workspace) would list that repository's tracked files, not its own.
        top = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'], capture_output=True, check=True)
        if Path(top.stdout.decode().strip()).resolve() != Path(root).resolve():
            raise OSError('not the top of a checkout')
        listed = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True, check=True).stdout
        for name in listed.decode().split('\0'):
            if name and (root / name).is_file():
                yield name
        return
    except (OSError, subprocess.CalledProcessError):
        pass
    stack = [root]
    while stack:
        folder = stack.pop()
        for entry in sorted(folder.iterdir()):
            if entry.is_dir():
                if entry.name not in SKIPPED_DIRS and not entry.name.endswith('.xcodeproj'):
                    stack.append(entry)
            else:
                yield entry.relative_to(root).as_posix()


def covers(prefixes, path):
    return any(path == prefix or path.startswith(prefix.rstrip('/') + '/') for prefix in prefixes)


def identity(url):
    return url.rstrip('/').rsplit('/', 1)[-1].removesuffix('.git').lower()


# The Swift manifests swift_packages reads, so every remote package in them must have its own entry. The tools
# package (#1873) builds on SessionKit by path and names no outside package today.
SWIFT_MANIFESTS = ('Packages/SessionKit/Package.swift', 'Packages/SessionKitTools/Package.swift')
SWIFT_RESOLVED = ('Packages/SessionKit/Package.resolved', 'Packages/SessionKitTools/Package.resolved',
                  'SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')


def swift_packages(root):
    """{identity: version or None} for every remote Swift package: `.package(url:)` in SessionKit's and its tools'
    Package.swift (Linux blocks included), `url:` in project.yml's packages, and the pins of every Package.resolved."""
    text = '\n'.join((root / manifest).read_text() for manifest in SWIFT_MANIFESTS if (root / manifest).exists())
    text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
    found = {identity(url): version for url, version in
             re.findall(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?url:\s*"([^"]+)"(?:\s*,\s*exact:\s*"([^"]+)")?', text)}
    for url in re.findall(r'^\s+url:\s*(\S+)', (root / 'project.yml').read_text(), re.M):
        found.setdefault(identity(url), None)
    for resolved in SWIFT_RESOLVED:
        if (root / resolved).exists():
            for pin in json.loads((root / resolved).read_text())['pins']:
                found.setdefault(pin['identity'], None)
    return found


def npm_dependencies(root):
    """{name: version or None}; a range such as ^1.0 gives None."""
    manifest = json.loads((root / 'package.json').read_text())
    declared = {**manifest.get('dependencies', {}), **manifest.get('devDependencies', {})}
    return {name: (version if re.fullmatch(r'\d[\w.+-]*', version) else None) for name, version in declared.items()}


def pip_requirements(root):
    """{normalised name: pinned version or None} from requirements-dev.txt; option lines like -r are skipped."""
    found = {}
    for line in (root / 'requirements-dev.txt').read_text().splitlines():
        match = re.match(r'\s*([A-Za-z0-9][A-Za-z0-9_.-]*)(?:\[[^\]]*\])?\s*(?:==\s*([\w.+-]+))?', line)
        if match and not line.lstrip().startswith(('#', '-')):
            found[re.sub(r'[-_.]+', '-', match.group(1)).lower()] = match.group(2)
    return found


def bundled_js_packages(root):
    """{name: (version, license)} from the headings of BundledJavaScript-NOTICES.txt."""
    heading = re.compile(r'^={20,}\n(\S+) (\S+) \(([^)]+)\)\n={20,}$', re.M)
    return {name: (version, licence) for name, version, licence in heading.findall((root / BUNDLED_JS_NOTICES).read_text())}


def resource_folders(root):
    """Paths project.yml bundles as resources or plain folders."""
    lines = (root / 'project.yml').read_text().splitlines()
    found = set()
    for index, line in enumerate(lines):
        match = re.match(r'(\s*)- path: (\S+)', line)
        if not match:
            continue
        body = []
        for follower in lines[index + 1:]:
            if re.match(r'\s*- ', follower) or not follower.startswith(match.group(1) + '  '):
                break  # the next list item, or the end of this one
            body.append(follower)
        if re.search(r'buildPhase: resources|type: folder\b', ' '.join(body)):
            found.add(match.group(2))
    return found


# Test bundles may carry any fixture; a target of another type ships to listeners.
TEST_TARGET_TYPES = ('bundle.unit-test', 'bundle.ui-testing')
APP_TEST_SOURCES = ('App/SpokenMarginsAppTests/', 'App/SpokenMarginsAppUITests/')


def shipped_contract_resources(root):
    """(target, path, is folder) for each Contracts/fixtures or Contracts/traces path a shipped target bundles."""
    found = []
    target = kind = None
    in_targets = False
    lines = (root / 'project.yml').read_text().splitlines()
    for index, line in enumerate(lines):
        if re.match(r'\S', line):
            in_targets = line.startswith('targets:')
            continue
        if not in_targets:
            continue
        if match := re.match(r'  (\S[^:]*):\s*$', line):
            target, kind = match.group(1), None
        elif match := re.match(r'    type: (\S+)', line):
            kind = match.group(1)
        elif match := re.match(r'(\s*)- path: (Contracts/(?:fixtures|traces)(?:/\S*)?)\s*$', line):
            if kind in TEST_TARGET_TYPES:
                continue
            body = []
            for follower in lines[index + 1:]:
                if re.match(r'\s*- ', follower) or not follower.startswith(match.group(1) + '  '):
                    break
                body.append(follower)
            found.append((target, match.group(2), bool(re.search(r'type: folder\b', ' '.join(body)))))
    return found


def bundle_reads(root, files):
    """The `subdirectory:` and `forResource:` names app and SessionKit sources (not their tests) pass to Bundle."""
    subdirectories, resources = set(), set()
    for path in files:
        if not path.endswith('.swift') or path.startswith(APP_TEST_SOURCES):
            continue
        if not (path.startswith('App/') or re.match(r'Packages/[^/]+/Sources/', path)):
            continue
        text = (root / path).read_text(errors='replace')
        subdirectories.update(re.findall(r'subdirectory:\s*"([^"]+)"', text))
        resources.update(re.findall(r'forResource:\s*"([^"]+)"', text))
    return subdirectories, resources


def problems(root):
    data = load(root)
    components = data['components']
    found = []

    def tracked(kind):
        return {component['tracks'][kind].lower(): component for component in components if kind in component.get('tracks', {})}

    for component in components:
        label = component['id']
        if component.get('distribution') not in DISTRIBUTIONS:
            found.append(f'{label}: distribution must be one of {", ".join(DISTRIBUTIONS)}')
        for key in ('name', 'license', 'note'):
            if not component.get(key):
                found.append(f'{label}: "{key}" is empty')
        needs_text = component.get('distribution') in ('bundled', 'downloaded') or \
            set(component.get('tracks', {})) - {'manifests'}
        if needs_text and not (component.get('licenseFiles') or component.get('licenseUrl')):
            found.append(f'{label}: needs licenseFiles or licenseUrl')
        for path in [*component.get('paths', []), *component.get('licenseFiles', []),
                     *component.get('tracks', {}).get('manifests', [])]:
            if not (root / path).exists():
                found.append(f'{label}: {path} does not exist')

    def compare(kind, declared, where, label):
        entries = tracked(kind)
        for name, version in sorted(declared.items()):
            entry = entries.get(name.lower())
            if entry is None:
                found.append(f'{label} {name} ({where}) has no entry in {MANIFEST}')
            elif version and entry.get('version') != version:
                found.append(f'{label} {name}: {where} says {version}; the entry says {entry.get("version")}')

    compare('swiftPackage', swift_packages(root), 'Package.swift, project.yml or Package.resolved', 'Swift package')
    compare('npm', npm_dependencies(root), 'package.json', 'npm package')
    compare('pip', pip_requirements(root), 'requirements-dev.txt', 'Python requirement')
    for original, copy in COPIES:
        if (root / original).read_bytes() != (root / copy).read_bytes():
            found.append(f'{copy} differs from {original}; the extension must ship the same notice')
    bundled = tracked('bundledJs')
    for name, (version, licence) in sorted(bundled_js_packages(root).items()):
        entry = bundled.get(name.lower())
        if entry is None:
            found.append(f'{name} {version} is compiled into the page-reading scripts and has no entry in {MANIFEST}')
        elif entry.get('version') != version or not entry['license'].startswith(licence):
            found.append(f'{name}: {BUNDLED_JS_NOTICES} says {version} ({licence}); the entry says '
                         f'{entry.get("version")} ({entry["license"]})')

    # Tool entries list where a tool lives, not what it owns: a model under scripts/ is not a jsonschema file.
    prefixes = [path for component in components if component['distribution'] != 'tool'
                for path in component.get('paths', [])]
    own = data.get('projectAuthored', [])
    # Captured content is covered as data, but a model or font file dropped there still needs its own entry.
    model_prefixes = [path for component in components if component['distribution'] not in ('tool', 'content')
                      for path in component.get('paths', [])]
    for path in sorted(resource_folders(root)):
        if not covers([*prefixes, *own], path) and not any(covers([path], listed) for listed in [*prefixes, *own]):
            found.append(f'project.yml bundles {path}, which no entry lists in "paths" and "projectAuthored" does not claim')
    files = list(walk(root))
    # Captured feeds, search responses and traces are kept for tests; a folder ships only when the app reads it (#3075).
    subdirectories, resources = bundle_reads(root, files)
    for target, path, is_folder in shipped_contract_resources(root):
        name = Path(path).name
        if (name not in subdirectories) if is_folder else (Path(path).stem not in resources):
            found.append(f'project.yml bundles {path} in {target}, but no app source reads "{name}" from the bundle; '
                         'bundle only the folders the app reads and keep test fixtures in the test bundle')
    claimed_manifests = {path for component in components for path in component.get('tracks', {}).get('manifests', [])}
    individually_checked = {'package.json', 'requirements-dev.txt', *SWIFT_MANIFESTS, *SWIFT_RESOLVED}
    for path in files:
        name = path.rsplit('/', 1)[-1]
        if Path(path).suffix.lower() in MODEL_SUFFIXES and not covers(model_prefixes, path):
            found.append(f'{path}: a model or font file under no entry\'s paths')
        if MANIFEST_NAMES.match(name) and path not in individually_checked and path not in claimed_manifests:
            found.append(f'{path}: a dependency manifest no entry claims under tracks.manifests')
    gomod = root / 'research/B4/server/go.mod'
    if gomod.exists() and re.search(r'^\s*require\b|^\s+\S+\s+v\d', gomod.read_text(), re.M):
        found.append('research/B4/server/go.mod requires an outside module; give it its own entry')

    if (root / OUTPUT).read_text() != render(data):
        found.append(f'{OUTPUT} is out of date; run `python3 scripts/third_party_notices.py --write`')
    return found


def render(data):
    out = ['# Third-party notices', '',
           'Spoken Margins itself is licensed under the GNU Affero General Public License, version 3 only, '
           'with an App Store permission ([NOTICE](NOTICE)). The components below keep their own licences.', '',
           f'This file is generated from [{MANIFEST}]({MANIFEST}) by `scripts/third_party_notices.py`, '
           'which fails when a dependency, bundled model or bundled folder has no entry. Do not edit it by hand.', '']
    for kind in DISTRIBUTIONS:
        members = [component for component in data['components'] if component['distribution'] == kind]
        if not members:
            continue
        title, intro = HEADINGS[kind]
        out += [f'## {title}', '', intro, '']
        for component in members:
            version = f' {component["version"]}' if component.get('version') else ''
            out += [f'### {component["name"]}{version}', '', f'- Licence: {component["license"]}']
            if component.get('by'):
                out.append(f'- From: {component["by"]}')
            if component.get('source'):
                out.append(f'- Source: <{component["source"]}>')
            if component.get('paths'):
                out.append('- Where: ' + ', '.join(f'`{path}`' for path in component['paths']))
            texts = [f'[{Path(path).name}]({path})' for path in component.get('licenseFiles', [])]
            if component.get('licenseUrl'):
                texts.append(f'<{component["licenseUrl"]}>')
            if texts:
                out.append('- Licence text: ' + ', '.join(texts))
            out += ['', component['note'], '']
    return '\n'.join(out).rstrip('\n') + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--write', action='store_true', help='regenerate THIRD_PARTY_NOTICES.md first')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.write:
        (args.root / OUTPUT).write_text(render(load(args.root)))
    found = problems(args.root)
    for line in found:
        print(f'third-party notices: {line}', file=sys.stderr)
    if not found:
        print(f'third-party notices: {len(load(args.root)["components"])} components, all covered')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main())
