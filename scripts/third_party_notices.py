#!/usr/bin/env python3
"""THIRD_PARTY_NOTICES.md from docs/legal/third-party-components.json, and a check that nothing is missing (#1823).

The manifest names every third-party component the repository ships, downloads, builds with or carries as data.
This script fails when:
- a Swift package, an npm package, a Python dev requirement or a package compiled into the page-reading scripts
  has no entry (or an entry at another version);
- a model or font file, or a folder the app bundles (project.yml), sits under no entry's paths;
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
                   'The app fetches these on request. They are not in this repository or in the app. '
                   'Where the voice catalog (#1818) publishes the current address and licence text, it is the reference.'),
    'tool': ('Build, test and research tools',
             'Used to build, test or research. None of them ships in the app.'),
    'content': ('Third-party content in the repository',
                'Data and text captured from other people\'s work. This project does not license it; the rights stay with their owners.'),
}
MODEL_SUFFIXES = {'.ttf', '.otf', '.woff', '.woff2', '.onnx', '.mlmodel', '.gguf', '.safetensors', '.npz',
                  '.tflite', '.bin', '.f32', '.pt', '.pth'}
MANIFEST_NAMES = re.compile(r'^(package\.json|requirements[^/]*\.txt|go\.mod|Package\.swift|Package\.resolved|'
                            r'Podfile|Cartfile|Gemfile|pyproject\.toml|Cargo\.toml)$')
SKIPPED_DIRS = {'.git', 'node_modules', '.build', '.venv', 'artifacts', 'DerivedData', 'tmp'}


def load(root):
    return json.loads((root / MANIFEST).read_text())


def walk(root):
    """Every file under root as a posix path relative to it, leaving out build and tool folders."""
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


def swift_package_identities(root):
    """Identities of every `.package(url:)` in SessionKit's Package.swift, Linux block included."""
    text = (root / 'Packages/SessionKit/Package.swift').read_text()
    text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
    names = {url.rstrip('/').rsplit('/', 1)[-1].removesuffix('.git').lower()
             for url in re.findall(r'\.package\(\s*url:\s*"([^"]+)"', text)}
    pins = json.loads((root / 'Packages/SessionKit/Package.resolved').read_text())['pins']
    return names | {pin['identity'] for pin in pins}


def npm_dependencies(root):
    manifest = json.loads((root / 'package.json').read_text())
    return {**manifest.get('dependencies', {}), **manifest.get('devDependencies', {})}


def pip_requirements(root):
    names = set()
    for line in (root / 'requirements-dev.txt').read_text().splitlines():
        match = re.match(r'\s*([A-Za-z0-9_.-]+)', line)
        if match and not line.lstrip().startswith('#'):
            names.add(match.group(1).lower())
    return names


def bundled_js_packages(root):
    """{name: (version, license)} from the headings of BundledJavaScript-NOTICES.txt."""
    heading = re.compile(r'^={20,}\n(\S+) (\S+) \(([^)]+)\)\n={20,}$', re.M)
    return {name: (version, licence) for name, version, licence in heading.findall((root / BUNDLED_JS_NOTICES).read_text())}


def resource_folders(root):
    """Paths project.yml bundles as resources or plain folders."""
    lines = (root / 'project.yml').read_text().splitlines()
    found = set()
    for index, line in enumerate(lines):
        match = re.match(r'\s*- path: (\S+)', line)
        if match and re.search(r'buildPhase: resources|type: folder\b', ' '.join(lines[index + 1:index + 4])):
            found.add(match.group(1))
    return found


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

    packages = tracked('swiftPackage')
    for identity in sorted(swift_package_identities(root) - set(packages)):
        found.append(f'Swift package {identity} (Package.swift or Package.resolved) has no entry in {MANIFEST}')
    npm = tracked('npm')
    for name in sorted(set(npm_dependencies(root)) - set(npm)):
        found.append(f'npm package {name} (package.json) has no entry in {MANIFEST}')
    pip = tracked('pip')
    for name in sorted(pip_requirements(root) - set(pip)):
        found.append(f'Python requirement {name} (requirements-dev.txt) has no entry in {MANIFEST}')
    bundled = tracked('bundledJs')
    for name, (version, licence) in sorted(bundled_js_packages(root).items()):
        entry = bundled.get(name.lower())
        if entry is None:
            found.append(f'{name} {version} is compiled into the page-reading scripts and has no entry in {MANIFEST}')
        elif entry.get('version') != version or not entry['license'].startswith(licence):
            found.append(f'{name}: {BUNDLED_JS_NOTICES} says {version} ({licence}); the entry says '
                         f'{entry.get("version")} ({entry["license"]})')

    prefixes = [path for component in components for path in component.get('paths', [])]
    own = data.get('projectAuthored', [])
    for path in sorted(resource_folders(root)):
        if not covers([*prefixes, *own], path) and not any(covers([path], listed) for listed in [*prefixes, *own]):
            found.append(f'project.yml bundles {path}, which no entry lists in "paths" and "projectAuthored" does not claim')
    claimed_manifests = {path for component in components for path in component.get('tracks', {}).get('manifests', [])}
    individually_checked = {'package.json', 'requirements-dev.txt', 'Packages/SessionKit/Package.swift',
                            'Packages/SessionKit/Package.resolved',
                            'SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'}
    for path in walk(root):
        name = path.rsplit('/', 1)[-1]
        if Path(path).suffix.lower() in MODEL_SUFFIXES and not covers(prefixes, path):
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
