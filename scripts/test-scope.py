#!/usr/bin/env python3
"""Map a diff to its minimum test tier (docs/workstreams/test-lane.md) and suggest what to run.

  scripts/test-scope.py                 changes since the merge base with origin/next, uncommitted included
  scripts/test-scope.py --base main     compare against another ref
  scripts/test-scope.py --files A B     classify these paths (no public-API check)
  scripts/test-scope.py --json          machine-readable output

The tier table is the policy; this script only applies it. If its answer and your judgment
disagree, take the higher tier and say why in the lane request.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

APP_SOURCES = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/'
APP_TESTS = 'App/SpokenMarginsAppTests/'
UI_TESTS = 'App/SpokenMarginsAppUITests/'
SESSIONKIT = 'Packages/SessionKit/'
SESSIONKIT_TESTS = SESSIONKIT + 'Tests/'

T0_PREFIXES = ('docs/', 'research/', 'Design/', 'references/', 'tmp/', 'Site/', '.claude/', '.github/',
               'Contracts/docs/')
T0_FILES = {'.gitignore', '.gitattributes', 'LICENSE', '.worktreeinclude'}
VALIDATED_PREFIXES = ('Contracts/', 'validation/', 'schemas/', 'traces/', 'fixtures/', 'TestPlans/')
BROWSER_PREFIXES = ('Tools/BrowserExtraction/',)
BROWSER_FILES = {'package.json', 'package-lock.json'}
BUILD_FILES = ('project.yml', 'SpokenMarginsNative.xcodeproj/', 'Config/')

# The lane's own machinery (owner rule 2026-10-01). A PR touching any of these merges only after a clean
# Codex audit of its head, like an audio, persistence or packet change (lane-runner.py, merge_blockers).
# The list: every workflow; the runner and its helpers (lane-runner.py, lane_sim.py, lane_slots.py,
# lane_guard.py, lane-sim-boot, xcodebuild-lane, host-test-lane, install-lane-guard.py); the policies the
# runner loads from next (this file, hot_file_ratchet.py, merge_audit.py); verify-tests.py, which runs the
# lane's host tests and T3 plans; and the two test plans a T3 runs. Tests of the lane (scripts/tests/)
# can't break it and stay off the list, as does scripted-journeys.json (the Test Desk's list).
# The Mac's Codex audit script keeps a copy of this list (its RISKY_PATTERNS "lane").
LANE_PREFIXES = ('.github/workflows/', 'scripts/lane')
LANE_FILES = {'scripts/xcodebuild-lane', 'scripts/host-test-lane', 'scripts/install-lane-guard.py',
              'scripts/test-scope.py', 'scripts/hot_file_ratchet.py', 'scripts/merge_audit.py',
              'scripts/verify-tests.py', 'TestPlans/AppBehavior.xctestplan', 'TestPlans/AudioAdapters.xctestplan'}
LANE_NOTE = ('Lane change: the runner merges it only after a Codex audit of the head that says "No blocking '
             'findings". The audit runs by itself once the automerge run passes.')

SESSIONKIT_RISK = {'SessionKitAudio': 'audio', 'SessionKitPersistence': 'persistence', 'SessionKitSharing': 'packet'}
SESSIONKIT_PACKET_FILES = {'SharingModels.swift', 'ShareableLinkPolicy.swift'}
PACKET_SCHEMAS = {'spoken-margins-package.schema.json', 'shared-commentary-layer.schema.json',
                  'interjection-share-revision.schema.json', 'portable-listening-map-proposal.schema.json'}
PACKET_FIXTURES = ('Contracts/fixtures/interjection-packages/', 'Contracts/fixtures/sharing/')
PERSISTENCE_FIXTURES = ('Contracts/fixtures/persistence/',)

APP_AUDIO = re.compile(r'Audio|Playback|Speech|Supertonic|RemoteControl|Media')
APP_PACKET = re.compile(r'Shar|ImportedMargin|PackageHandoff|Packet')
APP_PERSISTENCE = re.compile(r'Store\.swift$|Ledger')
APP_ORCHESTRATION = re.compile(r'Gate1AppModel\.swift$|Coordinator|Controller|Conductor|Router|Model\.swift$')
PUBLIC_API = re.compile(r'^[+-](?![+-]{2})\s*(?!//)(?:@\w+(?:\([^)]*\))?\s+)*(?:\w+\s+)*?(?:public|open)(?:\(set\))?\s+'
                        r'(?:\w+\s+)*?(?:func|var|let|class|struct|enum|protocol|init|typealias|actor|subscript|'
                        r'extension|case|associatedtype)\b')
TEST_CLASS = re.compile(r'^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase', re.M)

SWIFT_TEST_LIMIT = 8

REASONS = {
    'docs': 'docs, research or tooling notes',
    'scripts': 'repo scripts (runner tests)',
    'guard': 'lane guard hook',
    'build-script': 'script run by the Xcode build',
    'validated': 'contracts, fixtures or test plans (validators)',
    'browser': 'browser extraction JavaScript',
    'sessionkit': 'SessionKit logic',
    'sessionkit-tests': 'SessionKit tests',
    'public-api': 'SessionKit public API',
    'package-manifest': 'SessionKit package manifest',
    'audio': 'audio session, players or playback state (escalated one tier)',
    'persistence': 'persistence or migrations (escalated one tier)',
    'packet': 'packet import/export (escalated one tier)',
    'build': 'Xcode project or build settings',
    'app-ui': 'app UI',
    'app-orchestration': 'app orchestration',
    'app-tests': 'app-hosted tests',
    'ui-tests': 'UI test scripts (compile only)',
    'app-other': 'app target files',
    'ops': 'VPS and Mac ops tools, with their own Python tests',
    'unknown': 'unclassified path, defaulting to a compile',
}

NOTES = {
    'packet': 'Packets (I10): a packet from this build must import into Build 29, whose reader rejects '
              'unknown keys. Keep a test that feeds the new packet to the last shipped reader; a manifest '
              'change needs the owner\'s OK.',
    'persistence': 'Persistence: the previous build must still open the database (PriorBuildPersistenceTests); '
                   'prefer new record kinds over new fields.',
    'audio': 'Audio: host and app tests fake the audio session. Audible behavior is the owner\'s T6 check.',
    'app-ui': 'If a listener would notice this change, the milestone needs a T4 journey.',
    'guard': 'After changing the guard, run scripts/install-lane-guard.py so new sessions use it.',
    'ui-tests': 'Scripted journeys run only in the integration run on next\'s tip, never per PR. Name the '
                'journey the script covers in the PR, and add a new script to TestPlans/scripted-journeys.json '
                'under probation (docs/journeys.md, Scripted journeys).',
}

T2_COMMANDS = [
    "scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp "
    "-destination 'generic/platform=iOS Simulator' build-for-testing",
    "scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp "
    "-destination 'generic/platform=iOS' build",
]


class Finding:
    def __init__(self, path, tier, category, swift_filters=(), app_tests=(), commands=()):
        self.path, self.tier, self.category = path, tier, category
        self.swift_filters, self.app_tests, self.commands = list(swift_filters), list(app_tests), list(commands)

    def as_dict(self):
        return {'path': self.path, 'tier': f'T{self.tier}', 'category': self.category,
                'reason': REASONS[self.category]}


def test_classes(files):
    names = []
    for path in files:
        try:
            names.extend(TEST_CLASS.findall(path.read_text(errors='replace')))
        except OSError:
            continue
    return sorted(set(names))


def sessionkit_filters(root, path):
    """Test classes for a SessionKit source file: FooTests for Foo.swift, else tests importing its target."""
    tests = sorted((root / SESSIONKIT_TESTS).glob('*/*.swift'))
    stem = Path(path).stem
    named = [t for t in tests if t.stem.startswith(stem) and t.stem.endswith('Tests')]
    if named:
        return test_classes(named)
    parts = Path(path).parts
    target = parts[parts.index('Sources') + 1] if 'Sources' in parts else None
    if not target:
        return []
    importing = re.compile(rf'^\s*(?:@testable\s+)?import\s+{re.escape(target)}\s*$', re.M)
    return test_classes([t for t in tests if importing.search(t.read_text(errors='replace'))])


def app_test_classes(root, path):
    stem = Path(path).stem
    return test_classes(t for t in sorted((root / APP_TESTS).glob('*.swift'))
                        if t.stem.startswith(stem) and t.stem.endswith('Tests'))


def build_scripts(root):
    try:
        text = (root / 'project.yml').read_text()
    except OSError:
        return set()
    return set(re.findall(r'scripts/[\w.-]+', text))


def is_lane_path(path):
    """Whether a changed path is part of the lane itself (LANE_PREFIXES, LANE_FILES)."""
    return path.startswith(LANE_PREFIXES) or path in LANE_FILES


def classify_path(root, path, diff_text='', build_script_paths=frozenset()):
    name = Path(path).name
    if path.endswith('.md') or path in T0_FILES or path.startswith(T0_PREFIXES):
        return Finding(path, 0, 'docs')
    if path.startswith('scripts/'):
        if path in build_script_paths:
            return Finding(path, 2, 'build-script', commands=T2_COMMANDS)
        runner = ['.venv/bin/python -m unittest discover -s scripts/tests']
        return Finding(path, 1, 'guard' if name == 'lane_guard.py' else 'scripts', commands=runner)
    if path.startswith('ops/'):
        # VPS and Mac ops tools (the Dial gate, the Codex audit): nothing reaches the app, and --plan fast
        # runs each ops folder's own tests (verify-tests.py, ops_steps).
        folder = '/'.join(Path(path).parts[:2]) if len(Path(path).parts) > 2 else 'ops'
        return Finding(path, 1, 'ops', commands=[f'.venv/bin/python -m unittest discover -s {folder}'])
    if path.startswith(BROWSER_PREFIXES) or path in BROWSER_FILES:
        return Finding(path, 1, 'browser', commands=['npm run test:browser-extraction'])
    if path.startswith(PERSISTENCE_FIXTURES):
        return Finding(path, 2, 'persistence', swift_filters=['PriorBuildPersistenceTests', 'Build29UpgradeProgressTests'],
                       commands=['.venv/bin/python scripts/validate-contracts.py'] + T2_COMMANDS)
    if path.startswith(PACKET_FIXTURES) or (path.startswith('Contracts/schemas/') and name in PACKET_SCHEMAS):
        return Finding(path, 2, 'packet', swift_filters=['SharingTests'],
                       commands=['.venv/bin/python scripts/validate-contracts.py'] + T2_COMMANDS)
    if path.startswith(VALIDATED_PREFIXES):
        return Finding(path, 1, 'validated', commands=[
            '.venv/bin/python scripts/validate-contracts.py',
            '.venv/bin/python scripts/validate-surface-contracts.py',
            '.venv/bin/python scripts/test_inventory.py'])
    if path.startswith(SESSIONKIT):
        if path.startswith(SESSIONKIT_TESTS):
            return Finding(path, 1, 'sessionkit-tests', swift_filters=test_classes([root / path]))
        if name in ('Package.swift', 'Package.resolved'):
            return Finding(path, 2, 'package-manifest', commands=T2_COMMANDS)
        parts = Path(path).parts
        target = parts[parts.index('Sources') + 1] if 'Sources' in parts else ''
        filters = sessionkit_filters(root, path)
        risk = SESSIONKIT_RISK.get(target) or ('packet' if name in SESSIONKIT_PACKET_FILES else None)
        if risk:
            return Finding(path, 2, risk, swift_filters=filters, commands=T2_COMMANDS)
        if any(PUBLIC_API.match(line) for line in diff_text.splitlines()):
            return Finding(path, 2, 'public-api', swift_filters=filters, commands=T2_COMMANDS)
        return Finding(path, 1, 'sessionkit', swift_filters=filters)
    if path.startswith(BUILD_FILES):
        return Finding(path, 2, 'build', commands=T2_COMMANDS)
    if path.startswith(UI_TESTS):
        # Scripted journeys compile in the PR's build and run only in the integration run (#445), so a UI test
        # file never escalates to T3, whatever its name, and adds no classes to a T3 request.
        return Finding(path, 2, 'ui-tests', commands=T2_COMMANDS)
    if path.startswith(APP_TESTS):
        return Finding(path, 3, 'app-tests', app_tests=test_classes([root / path]), commands=T2_COMMANDS)
    if path.startswith('App/'):
        if path.startswith('App/SpokenMarginsShareExtension/') or (
                path.endswith('.swift') and APP_PACKET.search(name)):
            category = 'packet'
        elif not path.endswith('.swift'):
            category = 'app-other'
        elif APP_AUDIO.search(name):
            category = 'audio'
        elif APP_PERSISTENCE.search(name):
            category = 'persistence'
        elif APP_ORCHESTRATION.search(name):
            category = 'app-orchestration'
        else:
            category = 'app-ui'
        commands = list(T2_COMMANDS)
        if path.endswith(('.js', '.mjs')):
            commands.insert(0, 'npm run test:browser-extraction')
        tier = 2 if category in ('app-ui', 'app-other') else 3
        tests = app_test_classes(root, path) if path.endswith('.swift') else []
        return Finding(path, tier, category, app_tests=tests, commands=commands)
    return Finding(path, 2, 'unknown', commands=T2_COMMANDS)


def classify(paths, diffs=None, root=ROOT):
    diffs = diffs or {}
    scripts = build_scripts(root)
    findings = [classify_path(root, p, diffs.get(p, ''), scripts) for p in sorted(set(paths))]
    tier = max((f.tier for f in findings), default=0)
    commands, filters, app_tests, notes = [], [], [], []
    for finding in findings:
        for command in finding.commands:
            if command not in commands:
                commands.append(command)
        filters.extend(f for f in finding.swift_filters if f not in filters)
        app_tests.extend(t for t in finding.app_tests if t not in app_tests)
        note = NOTES.get(finding.category)
        if note and note not in notes:
            notes.append(note)
    if filters:
        swift = ('bash scripts/run-sessionkit-tests.sh' if len(filters) > SWIFT_TEST_LIMIT else
                 f"swift test --package-path Packages/SessionKit --filter '{'|'.join(filters)}'")
        commands.insert(0, swift)
    lane = None
    if tier >= 3:
        tests = ', '.join(f'SpokenMarginsAppTests/{t}' for t in app_tests) or '<the app test classes that cover it>'
        lane = f'/lane T3\ntests: {tests}'
    lane_paths = [f.path for f in findings if is_lane_path(f.path)]
    if lane_paths:
        notes.append(LANE_NOTE)
    top = [f for f in findings if f.tier == tier]
    # app_tests: the classes the lane runner adds to every T3 request for this diff (#351).
    # lane_paths: the changed paths that are part of the lane; the runner merges those only after an audit.
    return {'tier': f'T{tier}', 'why': sorted({REASONS[f.category] for f in top}),
            'files': [f.as_dict() for f in findings], 'run': commands, 'lane_request': lane, 'notes': notes,
            'app_tests': app_tests, 'lane_paths': lane_paths}


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True)


def changed_paths(base):
    merge_base = git('merge-base', 'HEAD', base).strip()
    paths = set(git('diff', '--name-only', merge_base).split())
    paths |= set(git('ls-files', '--others', '--exclude-standard').split())
    diffs = {}
    current = None
    for line in git('diff', '-U0', merge_base, '--', SESSIONKIT + 'Sources').splitlines():
        if line.startswith('diff --git '):
            current = line.split(' b/', 1)[1]
            diffs[current] = ''
        elif current:
            diffs[current] += line + '\n'
    for path in paths - set(diffs):
        if path.startswith(SESSIONKIT + 'Sources') and (ROOT / path).is_file():
            diffs[path] = ''.join('+' + line + '\n' for line in (ROOT / path).read_text(errors='replace').splitlines())
    return sorted(paths), diffs


def render(result):
    lines = [f"Minimum tier: {result['tier']} ({'; '.join(result['why']) or 'no changes'})", '']
    for f in result['files']:
        lines.append(f"  {f['tier']}  {f['path']}  ({f['reason']})")
    if result['run']:
        lines += ['', 'Run yourself:'] + [f'  {c}' for c in result['run']]
    if result['lane_request']:
        lines += ['', 'Ask the lane (see the lane-request skill):'] + [f'  {c}' for c in result['lane_request'].splitlines()]
    if result['notes']:
        lines += ['', 'Notes:'] + [f'  - {n}' for n in result['notes']]
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--base', default='origin/next')
    parser.add_argument('--files', nargs='+')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    paths, diffs = (args.files, {}) if args.files else changed_paths(args.base)
    result = classify(paths, diffs)
    print(json.dumps(result, indent=2) if args.json else render(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
