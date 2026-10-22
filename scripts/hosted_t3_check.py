#!/usr/bin/env python3
"""Judge a hosted-Mac T3 (.github/workflows/hosted-app-macos.yml) by the lane's own rule (#2138).

`select` turns the workflow's `tests` input into -only-testing selectors and the tests they must run, using
verify-tests.py's t3_selection: a name that matches nothing in the plan fails here, before anything builds.
`reconcile` reads the run's log and result bundle as verify-tests.py does and fails on any requested test that
was missing, skipped or failed, or when no test completed. Before this the workflow failed only when zero tests
ran, so "1 passed, 1 skipped" passed.
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
_spec = importlib.util.spec_from_file_location('verify_tests_for_hosted_t3', SCRIPTS / 'verify-tests.py')
verify = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify)

# Only class and method names reach xcodebuild: each entry is Class or Class/method, optionally with ().
ENTRY = re.compile(r'[A-Za-z_]\w*(/[A-Za-z_]\w*(\(\))?)?')


def parse_tests(text):
    """The comma-separated `tests` input as entries; ValueError names the first entry that isn't one."""
    entries = []
    for raw in text.split(','):
        entry = raw.strip()
        if not entry:
            continue
        if not ENTRY.fullmatch(entry):
            raise ValueError(f"Not a test class or Class/method: '{entry}'")
        entries.append(entry.removesuffix('()'))
    return entries


def select(tests, plan, root=None):
    """(selectors, expected) for a request; both empty when nothing is requested (T2 only)."""
    entries = parse_tests(tests)
    if not entries:
        return [], set()
    selectors, _, expected = verify.t3_selection(entries, plan, root)
    return selectors, expected


def check(expected, records):
    """Errors that fail the run: verify-tests' reconcile, with no allowed skips and nothing on probation."""
    return verify.reconcile(set(expected), records)


def summary(records):
    counts = {status: sum(1 for r in records.values() if r['status'] == status)
              for status in ('passed', 'failed', 'skipped')}
    return (f"T3: {len(records)} tests completed: {counts['passed']} passed, {counts['failed']} failed, "
            f"{counts['skipped']} skipped.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    s = sub.add_parser('select')
    s.add_argument('--tests', default='')
    s.add_argument('--plan', default='AppBehavior')
    s.add_argument('--out', type=Path, required=True, help='folder for selectors.txt and expected.json')
    r = sub.add_parser('reconcile')
    r.add_argument('--expected', type=Path, required=True)
    r.add_argument('--log', type=Path, required=True)
    r.add_argument('--bundle', type=Path, required=True)
    args = parser.parse_args(argv)

    if args.command == 'select':
        try:
            selectors, expected = select(args.tests, args.plan)
        except (ValueError, RuntimeError) as error:
            print(f'::error::{error}')
            return 1
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / 'selectors.txt').write_text(''.join(f'-only-testing:{s}\n' for s in selectors))
        (args.out / 'expected.json').write_text(json.dumps(sorted(expected)) + '\n')
        print(f'{len(selectors)} selectors, {len(expected)} tests expected')
        return 0

    expected = json.loads(args.expected.read_text())
    log = args.log.read_text(errors='replace') if args.log.is_file() else ''
    try:
        records, _ = verify.completed_test_records(log, args.bundle)
    except Exception as error:  # an unreadable or empty bundle is a run that proved nothing
        records = verify.test_records(log)
        print(f'::warning::Result bundle unreadable ({error}); judging from the log alone.')
    print(summary(records))
    errors = check(expected, records)
    for error in errors:
        print(f'::error::{error}')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
