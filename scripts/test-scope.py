#!/usr/bin/env python3
"""Map a diff to its minimum test tier (docs/workstreams/test-lane.md) and suggest what to run.

  scripts/test-scope.py                 changes since the merge base with origin/<trunk> (next), uncommitted included
  scripts/test-scope.py --base main     compare against another ref
  scripts/test-scope.py --files A B     classify these paths (no public-API check)
  scripts/test-scope.py --json          machine-readable output

The tier table is the policy; this script only applies it. If its answer and your judgment
disagree, take the higher tier and say why in the lane request.
"""
import argparse
import json
import os
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
# The developer tools built on SessionKit, in their own package (#1873). The app never links them.
SESSIONKIT_TOOLS = 'Packages/SessionKitTools/'

T0_PREFIXES = ('docs/', 'research/', 'Design/', 'references/', 'tmp/', 'Site/', '.claude/', '.github/',
               'Contracts/docs/')
T0_FILES = {'.gitignore', '.gitattributes', 'LICENSE', '.worktreeinclude'}
VALIDATED_PREFIXES = ('Contracts/', 'validation/', 'schemas/', 'traces/', 'fixtures/', 'TestPlans/')
# The research code that scripts/research_tests.py tests (and the share-link page test), so a diff there is
# T1, not docs (#1033). research_tests.py keeps its own copy; test_research_tests.py fails if they differ.
RESEARCH_TESTED_PREFIXES = ('research/B4/', 'research/B2/', 'research/D3/', 'research/C1/tools/')
BROWSER_PREFIXES = ('Tools/BrowserExtraction/',)
BROWSER_FILES = {'package.json', 'package-lock.json'}
BUILD_FILES = ('project.yml', 'SpokenMarginsNative.xcodeproj/', 'Config/')

# The lane's own machinery (owner rule 2026-10-01). A PR touching any of these merges only after a clean
# Codex or Claude audit of its head, like an audio, persistence or packet change (lane-runner.py, merge_blockers).
# scripts/lane-runner.py and .github/ go further: only the owner merges those (lane-runner.py, owner_tap_paths).
# The list: every workflow; the runner and its helpers (lane-runner.py, lane_sim.py, lane_slots.py,
# lane_guard.py, lane-sim-boot, xcodebuild-lane, host-test-lane, install-lane-guard.py); the policies the
# runner loads from next (this file, hot_file_ratchet.py, merge_audit.py); verify-tests.py, which runs the
# lane's host tests and T3 plans; and the two test plans a T3 runs. Tests of the lane (scripts/tests/)
# can't break it and stay off the list, as does scripted-journeys.json (the Test Desk's list).
# The Mac's Codex audit script keeps a copy of this list (its RISKY_PATTERNS "lane").
LANE_PREFIXES = ('.github/workflows/', 'scripts/lane')
LANE_FILES = {'scripts/xcodebuild-lane', 'scripts/host-test-lane', 'scripts/install-lane-guard.py',
              'scripts/test-scope.py', 'scripts/hot_file_ratchet.py', 'scripts/merge_audit.py',
              'scripts/verify-tests.py', 'scripts/trunk.py', 'TestPlans/AppBehavior.xctestplan', 'TestPlans/AudioAdapters.xctestplan'}
LANE_NOTE = ('Lane change: the runner merges it only after a Codex or Claude audit of the head that says "No blocking '
             'findings". The audit runs by itself once the automerge run passes. A change to scripts/lane-runner.py or '
             '.github/ also needs the owner\'s merge tap: the runner never merges it.')

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
    'research': 'research code with its own tests (Go server, Python, Caddy script)',
    'scripts': 'repo scripts (runner tests)',
    'guard': 'lane guard hook',
    'build-script': 'script run by the Xcode build',
    'validated': 'contracts, fixtures or test plans (validators)',
    'browser': 'browser extraction JavaScript',
    'sessionkit': 'SessionKit logic',
    'sessionkit-tests': 'SessionKit tests',
    'sessionkit-tools': 'SessionKit developer tools (coop-packet, phone-plan)',
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
    'audio': 'Audio: host and app tests fake the audio session. Audible behavior is the owner\'s T6 check. '
             'A state-machine change needs one test across a chunk boundary with lifecycle on '
             '(SupertonicClientHarness, #353).',
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
    if path.startswith(RESEARCH_TESTED_PREFIXES) and not path.endswith('.md'):
        return Finding(path, 1, 'research', commands=['.venv/bin/python scripts/research_tests.py'])
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
    if path.startswith(SESSIONKIT_TOOLS):
        return Finding(path, 1, 'sessionkit-tools', commands=['bash scripts/run-sessionkit-tests.sh --tools'])
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


HOSTED_RUNNER = ['ubuntu-latest']  # runs-on for the off-Mac automerge job; lane.yml keys on it (#2442)

# #1389 phase 2: once the repo is public, /lane T2 and T3 requests run on a GitHub-hosted Mac, the image and Xcode the
# hosted fast checks use (hosted-portable.yml). Rollout guard, not a feature switch: lane.yml's route job hands this
# repository variable over, and unset (a private repo, whose hosted minutes cost money) the lane job stays on the Mac.
HOSTED_APP_SWITCH = 'LANE_HOSTED_APP'
HOSTED_APP_RUNNER = ['xcode-27']


def hosted_app_routing(result, env=None):
    """The lane job (T2/T3 requests) on a GitHub-hosted Mac when LANE_HOSTED_APP is `on`; the automerge job keeps
    its route. Anything else leaves <result> as it is."""
    if (os.environ if env is None else env).get(HOSTED_APP_SWITCH, '').strip().lower() != 'on':
        return result
    return dict(result, lane=list(HOSTED_APP_RUNNER))


def hosted_merge_routing(result, env=None):
    """#2459: every automerge job starts on a GitHub-hosted Linux runner once the hosted fast pair runs
    (LANE_HOSTED_FAST `on`, the rule lane-runner.py's hosted_fast_on reads). There a PR held for T3 is reported held
    without a Mac, and the job waits for the hosted checks: with LANE_HOSTED_MAC_REST `on` too it merges on all
    three and runs no test; without it, it hands the run to the build Mac (lane.yml's automerge-mac) only once the
    pair has finished. T0 and ops diffs test themselves, as before. The lane job keeps its route. Anything else
    leaves <result> as it is."""
    env = os.environ if env is None else env
    if env.get('LANE_HOSTED_FAST', '').strip().lower() != 'on':
        return result
    return dict(result, automerge=list(HOSTED_RUNNER))


# Ops folders whose tests skip themselves on Linux (ops/power's amph is AppleScript): a pass there proves nothing.
MAC_ONLY_OPS = ('ops/power/',)


def hosted_automerge(scope):
    """Only T0 and ops plus docs can run without the Mac. Lane/app inputs always stay there."""
    files = scope['files']
    paths = [f['path'] for f in files]
    if not paths or any(is_lane_path(p) or p.startswith(('App/', 'Packages/', 'Contracts/') + MAC_ONLY_OPS)
                        for p in paths):
        return False
    if scope['tier'] == 'T0':
        return True
    return (scope['tier'] == 'T1' and all(f['category'] in ('ops', 'docs') for f in files)
            and all(p.startswith(('ops/', 'docs/')) or p.endswith('.md') for p in paths))


def runner_routing(pr, file_pages, runner_pages, root=ROOT, offmac=True):
    """Choose queue labels, never capacity. API errors/incomplete diffs keep today's queues.

    Inputs are the event's PR and gh api --paginate --slurp responses. Busy online runners
    count: priority work queues there, but an absent/offline runner must not strand a job.
    Overflow (#1327): an automerge job that isn't priority work goes to the priority runner when it
    is idle and no build runner is, instead of queueing behind them while the Mac has a runner free.
    Never slower (#2147), a guard: if every online priority runner also takes build jobs, a priority automerge job uses the
    build queue, because GitHub gives waiting self-hosted jobs no order and the narrower label only means fewer
    runners. Priority does not jump the queue; real ordering is #1057.
    """
    normal = {'lane': ['self-hosted', 'macOS', 'sm-lane'],
              'automerge': ['self-hosted', 'macOS', 'sm-lane-build']}
    priority = ['self-hosted', 'sm-lane-priority']
    try:
        # An API error, malformed page, duplicate or truncated listing cannot prove a hosted diff.
        if not isinstance(file_pages, list) or not all(isinstance(p, list) for p in file_pages):
            return normal
        if not isinstance(runner_pages, list) or not runner_pages:
            return normal
        if not all(isinstance(page['runners'], list) for page in runner_pages):
            return normal
        runners = [r for page in runner_pages for r in page['runners']]
        if not all(r['status'] in ('online', 'offline') and isinstance(r['labels'], list)
                   and all(isinstance(label['name'], str) for label in r['labels']) for r in runners):
            return normal
        files = [file for page in file_pages for file in page]
        if not all(isinstance(file, dict) for file in files):
            return normal
        if any(file.get('status') == 'renamed' and 'previous_filename' not in file for file in files):
            return normal
        paths = {file['filename'] for file in files}
        complete = (bool(files) and len(files) == pr['changed_files'] and len(paths) == len(files)
                    and all(isinstance(p, str) and p for p in paths))
        paths.update(file['previous_filename'] for file in files if 'previous_filename' in file)
        if not all(isinstance(p, str) and p for p in paths):
            return normal
        labelled = any(label['name'] == 'priority' for label in pr['labels'])

        def names(runner):
            return {label['name'] for label in runner['labels']}

        # A GitHub-hosted Linux runner, free for the public repo (#2442; the VPS runner sm-vps-t1 until then, which
        # had to be online). GitHub always has one, so there is no runner to look for.
        if offmac and complete and hosted_automerge(classify(paths, root=root)):
            # Only the automerge job leaves the Mac: explicit /lane requests keep the Mac routing they had.
            return dict(runner_routing(pr, file_pages, runner_pages, root, offmac=False),
                        automerge=list(HOSTED_RUNNER))

        # Only an explicit busy=false is idle: a runner whose state is missing or unreadable is not.
        def idle(runner, wanted):
            return runner['status'] == 'online' and runner.get('busy') is False and wanted <= names(runner)

        if not any(r['status'] == 'online' and set(priority) <= names(r) for r in runners):
            return normal
        overflow = dict(normal)
        if any(idle(r, set(priority)) for r in runners) and not any(idle(r, {'sm-lane-build'}) for r in runners):
            overflow['automerge'] = priority
        if not labelled:
            if not complete:
                return overflow
            # Both sides of a rename belong to the diff: moving app code into ops isn't ops-only.
            if not all(path.startswith(('ops/', 'docs/')) or is_lane_path(path) for path in paths):
                return overflow
            if classify(paths, root=root)['tier'] != 'T1':
                return overflow
        # The lane job keeps the priority runner: the build queue would only add the host-test backlog to it.
        shared = all('sm-lane-build' in names(r) for r in runners
                     if r['status'] == 'online' and set(priority) <= names(r))
        return {'lane': priority, 'automerge': normal['automerge'] if shared else priority}
    except (KeyError, TypeError, ValueError):
        return normal


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
    parser.add_argument('--base', help='the base ref (default: origin/<trunk>)')
    parser.add_argument('--files', nargs='+')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--runner-routing', nargs=3, metavar=('EVENT', 'FILES', 'RUNNERS'),
                        help='route lane jobs from event JSON and paginated gh API JSON files')
    args = parser.parse_args(argv)
    if args.runner_routing:
        try:
            event, files, runners = [json.loads(Path(path).read_text()) for path in args.runner_routing]
            result = runner_routing(event['pull_request'], files, runners)
        except (OSError, ValueError, KeyError, TypeError):
            result = runner_routing({}, [], [])
        print(json.dumps(hosted_merge_routing(hosted_app_routing(result))))
        return 0
    if not args.files and args.base is None:  # #1492: the trunk (scripts/trunk.py)
        from trunk import trunk_ref
        args.base = trunk_ref()
    paths, diffs = (args.files, {}) if args.files else changed_paths(args.base)
    result = classify(paths, diffs)
    print(json.dumps(result, indent=2) if args.json else render(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
