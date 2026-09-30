"""Shared, fail-closed test selection and contract inventory for local verification."""
import importlib.util
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def swift_tests(directory):
    tests = set()
    for path in sorted(directory.rglob('*.swift')):
        # These suites use XCTestCase directly. Unknown test syntax is caught by
        # execution-vs-selection reconciliation, not silently counted as passing.
        source = path.read_text()
        classes = list(re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b', source))
        for index, match in enumerate(classes):
            end = classes[index + 1].start() if index + 1 < len(classes) else len(source)
            for method in re.findall(r'\bfunc\s+(test\w+)\s*\(', source[match.end():end]):
                tests.add(f'{match[1]}/{method}')
    return tests


def target_tests(root, name):
    if name == 'SpokenMarginsAppTests':
        return swift_tests(root / 'App/SpokenMarginsAppTests') - swift_tests_in_file(
            root / 'App/SpokenMarginsAppTests/Gate4WatchPackageRenderTests.swift')
    if name == 'SpokenMarginsAppUITests':
        return swift_tests(root / 'App/SpokenMarginsAppUITests')
    raise ValueError(f'Unclassified test target: {name}')


def swift_tests_in_file(path):
    source = path.read_text()
    name = re.search(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b', source).group(1)
    return {f'{name}/{m}' for m in re.findall(r'\bfunc\s+(test\w+)\s*\(', source)}


def matches(test, selector):
    selector = selector.removesuffix('()')
    return test == selector or test.startswith(selector + '/')


def plan_tests(root, name):
    plan = json.loads((root / f'TestPlans/{name}.xctestplan').read_text())
    selected = set()
    for target in plan['testTargets']:
        if target.get('skipped', False):
            raise ValueError(f'{name}: skipping an entire target needs explicit disposition')
        target_name = target['target']['name']
        available = target_tests(root, target_name)
        for field in ('selectedTests', 'skippedTests'):
            for selector in target.get(field, []):
                if not any(matches(test, selector) for test in available):
                    raise ValueError(f'{name}: stale {field} selector {selector}')
        included = target.get('selectedTests')
        skipped = target.get('skippedTests', [])
        selected.update(f'{target_name}/{test}' for test in available
                        if (included is None or any(matches(test, s) for s in included))
                        and not any(matches(test, s) for s in skipped))
    if not selected:
        raise ValueError(f'{name}: selects no tests')
    return selected


def scripted_journey_errors(root):
    """TestPlans/scripted-journeys.json: which UI test scripts the integration run runs (#445).

    Only `gating` scripts can turn the integration run red; `probation` scripts run and are reported.
    Each entry names an existing SpokenMarginsAppUITests class or method and the journey it covers.
    """
    try:
        listing = json.loads((root / 'TestPlans/scripted-journeys.json').read_text())
    except (OSError, ValueError) as error:
        return [f'scripted-journeys.json: {error}']
    if not (isinstance(listing, dict) and listing.get('version') == 1
            and set(listing) == {'version', 'gating', 'probation'}
            and all(isinstance(listing[status], list) for status in ('gating', 'probation'))):
        return ['scripted-journeys.json: expected version 1 with exactly "gating" and "probation" lists']
    available = target_tests(root, 'SpokenMarginsAppUITests')
    errors, seen = [], []
    for status in ('gating', 'probation'):
        for entry in listing[status]:
            test = entry.get('test') if isinstance(entry, dict) else None
            name = test.removeprefix('SpokenMarginsAppUITests/').removesuffix('()') if isinstance(test, str) else ''
            if not isinstance(test, str) or name == test or not any(matches(t, name) for t in available):
                errors.append(f'scripted-journeys.json: {status} names no SpokenMarginsAppUITests test: {test!r}')
                continue
            if not str(entry.get('journey', '')).strip():
                errors.append(f'scripted-journeys.json: {status} entry {test!r} names no journey')
            # A class in one list and one of its methods in another would leave its status ambiguous.
            for other, other_status in seen:
                if matches(name, other) or matches(other, name):
                    errors.append(f'scripted-journeys.json: {test!r} ({status}) is also listed as {other!r} '
                                  f'({other_status})')
            seen.append((name, status))
    return errors


def scripted_journeys(root=ROOT):
    """The scripted journeys the integration run runs, as {'gating': [...], 'probation': [...]} test IDs."""
    if errors := scripted_journey_errors(root):
        raise ValueError('; '.join(errors))
    listing = json.loads((root / 'TestPlans/scripted-journeys.json').read_text())
    return {status: [entry['test'].removesuffix('()') for entry in listing[status]]
            for status in ('gating', 'probation')}


def validate(root=ROOT):
    errors = []
    inventory = json.loads((root / 'validation/test-inventory.json').read_text())
    traces = {p.stem for p in (root / 'Contracts/traces').glob('*.json')}
    dispositions = inventory['traces']
    if traces != set(dispositions):
        errors.append(f'Trace disposition mismatch: {sorted(traces ^ set(dispositions))}')
    harness = (root / 'Packages/SessionKit/Tests/SessionKitTraceTests/TraceReplayTests.swift').read_text()
    mappings = dict(re.findall(r'func (test\w+)\(\) throws \{ try TraceHarness\(traceName: "([^"]+)"\)', harness))
    active = {name: spec['test'].split('/')[-1] for name, spec in dispositions.items() if spec['status'] == 'active'}
    if {name: method for method, name in mappings.items()} != active:
        errors.append('Executable trace methods differ from active trace inventory')
    for name, spec in dispositions.items():
        if spec['status'] not in ('active', 'deferred', 'archived'):
            errors.append(f'{name}: unknown disposition')
        if spec['status'] != 'active' and not spec.get('reason', '').strip():
            errors.append(f'{name}: missing omission reason')
    spec = importlib.util.spec_from_file_location('contract_validator', root / 'scripts/validate-contracts.py')
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    contracts = root / 'Contracts'
    covered = {p for rule in validator.PATH_SCHEMA_RULES + validator.NEGATIVE_PATH_SCHEMA_RULES
               for p in contracts.glob(rule[0])}
    unclassified = set(contracts.glob('fixtures/**/*.json')) - covered
    if unclassified:
        errors.append('Fixtures without schema coverage: ' + ', '.join(str(p) for p in sorted(unclassified)))
    persistence = contracts / 'fixtures/persistence'
    described = {persistence / json.loads(p.read_text())['database'] for p in persistence.glob('*.json')}
    if set(persistence.glob('*.sqlite')) != described:
        errors.append('Prior-build database fixture/provenance mismatch')
    for pattern, *_ in validator.PATH_SCHEMA_RULES:
        if not list(contracts.glob(pattern)) and not inventory.get('emptySchemaSelections', {}).get(pattern):
            errors.append(f'Empty fixture/schema selection: {pattern}')
    try:
        behavior, adapters = (plan_tests(root, p) for p in ('AppBehavior', 'AudioAdapters'))
        all_app = {f'SpokenMarginsAppTests/{t}' for t in target_tests(root, 'SpokenMarginsAppTests')}
        if behavior & adapters or behavior | adapters != all_app:
            errors.append('AppBehavior and AudioAdapters must partition all active app tests')
        release = plan_tests(root, 'Release')
        all_ui = {f'SpokenMarginsAppUITests/{t}' for t in target_tests(root, 'SpokenMarginsAppUITests')}
        if release != all_app | all_ui:
            errors.append('Release must include all active app and UI tests')
        for plan in ('UISeams', 'SpeechCanary', 'Smoke', 'ScreenTour'):
            if not plan_tests(root, plan) <= all_ui:
                errors.append(f'{plan}: non-UI test selected')
    except (ValueError, KeyError) as error:
        errors.append(str(error))
    errors += scripted_journey_errors(root)
    return errors


if __name__ == '__main__':
    failures = validate()
    for failure in failures:
        print(failure)
    print('Test inventory: ' + ('FAILED' if failures else 'passed'))
    raise SystemExit(bool(failures))
