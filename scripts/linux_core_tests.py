#!/usr/bin/env python3
"""SessionKitCoreTests on Linux for the hosted portable job (#3529), and the Linux and Mac test lists side by side.

`run` runs them in the swift image the job builds with. A red test fails the portable check, so stop-macs-on-red frees
the PR's hosted-Mac slot before the Mac's own run of the same tests. The rerun rule (owner, 2026-10-24): a test that
fails and passes on its rerun counts as a pass, and the run names it. The whole run goes again, as the Mac's serial
fallback does; a build failure does not, because a rerun would only fail the same way.

`compare` reads a Linux log and the Mac's result file and writes a report: what each ran, and every test that runs on
only one. Removing the Mac's run takes that list and a record of both agreeing; lost tests go to the owner.

    .venv/bin/python scripts/linux_core_tests.py run
    python3 scripts/linux_core_tests.py compare --linux linux-core.log --mac package-core.xunit.xml --out report.txt
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'swift:6.2.4'  # hosted-sessionkit-linux.yml's container and the job's cache key; a test keeps them equal
SCRATCH = '.build-linux'
LOG = Path('artifacts/test-runs/linux-core/linux-core.log')
RESOLVED = Path('Packages/SessionKit/Package.resolved')
SWIFT = ('apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && '
         f'swift test --scratch-path /w/{SCRATCH}')
RESULT = re.compile(r"Test Case '(\w+)\.(\w+)' (passed|failed|skipped)")
WORST = ('failed', 'skipped', 'passed')


def docker_command(root: Path = ROOT) -> list[str]:
    return ['docker', 'run', '--rm', '-v', f'{root}:/w', '-w', '/w/Packages/SessionKit', IMAGE, 'bash', '-c', SWIFT]


def linux_results(text: str) -> dict[str, str]:
    """{Class/method: passed|failed|skipped} from `swift test` output on Linux. A repeated test keeps its worst result."""
    results: dict[str, str] = {}
    for suite, test, status in RESULT.findall(text):
        key = f'{suite}/{test}'
        results[key] = next(s for s in WORST if s in (status, results.get(key, status)))
    return results


def attempt(command: list[str], log: Path) -> tuple[int, str]:
    """Run <command>, its output going both to this job's log and to <log>. (exit code, output)."""
    log.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace') as run, \
            log.open('w') as saved:
        for line in run.stdout:
            sys.stdout.write(line)
            saved.write(line)
            lines.append(line)
    sys.stdout.flush()
    return run.returncode, ''.join(lines)


def say_failed(results: dict[str, str]) -> list[str]:
    failed = sorted(test for test, status in results.items() if status == 'failed')
    for test in failed:
        print(f'Failed: SessionKitCoreTests/{test}', flush=True)
    return failed


def note_retry(names: list[str], first_code: int, ran: int, environ=None) -> None:
    environ = os.environ if environ is None else environ
    line = (f'passed on retry: {", ".join(f"SessionKitCoreTests/{name}" for name in names)}' if names else
            f'passed on retry: the first run stopped with exit {first_code} after {ran} tests and named no failure')
    print(f'::warning title=linux-core-retry::{line}\n{line}', flush=True)
    if environ.get('GITHUB_STEP_SUMMARY'):
        with open(environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(line + '\n')


def run_tests(command: list[str], log: Path, resolved: Path | None = None, environ=None) -> int:
    """0 when SessionKitCoreTests passed, on the first run or its one rerun. On Linux SwiftPM rewrites Package.resolved
    (swift-crypto in, onnxruntime out; run-sessionkit-linux-tests.sh says so), so the Mac's copy goes back afterwards."""
    backup = None
    if resolved:
        backup = Path(tempfile.mkdtemp()) / resolved.name
        shutil.copyfile(resolved, backup)
    try:
        code, text = attempt(command, log)
        first = linux_results(text)
        if not first:
            print(f'SessionKitCoreTests ran no tests on Linux (exit {code}): a build failure or a broken step.', flush=True)
            return code or 1
        if not code:
            return 0
        failed = say_failed(first)
        print('SessionKitCoreTests: the Linux run failed, so it runs once more (owner, 2026-10-24).', flush=True)
        log.replace(log.with_name('first-' + log.name))  # both runs' logs stay for the upload; the last is what stands
        retry_code, retry_text = attempt(command, log)
        second = linux_results(retry_text)
        if retry_code or not second:
            say_failed(second)
            return retry_code or 1
        note_retry(failed, code, len(first), environ)
        return 0
    finally:
        if backup:
            shutil.copyfile(backup, resolved)
            shutil.rmtree(backup.parent, ignore_errors=True)


def mac_results(path: Path) -> dict[str, str]:
    """{Class/method: passed|failed|skipped} from the Mac's `swift test --xunit-output` file."""
    results: dict[str, str] = {}
    for case in ElementTree.parse(path).getroot().iter('testcase'):
        suite = case.get('classname', '').rpartition('.')[2]
        test = case.get('name', '').removesuffix('()')
        if not (re.fullmatch(r'\w+', suite) and re.fullmatch(r'test\w+', test)):
            continue
        status = ('failed' if case.find('failure') is not None or case.find('error') is not None
                  else 'skipped' if case.find('skipped') is not None else 'passed')
        key = f'{suite}/{test}'
        results[key] = next(s for s in WORST if s in (status, results.get(key, status)))
    return results


def report(linux: dict[str, str], mac: dict[str, str]) -> str:
    """The summary, every test on only one side, and then both lists side by side."""
    def counts(results):
        return ', '.join(f'{sum(v == status for v in results.values())} {status}' for status in reversed(WORST))

    only_linux, only_mac = sorted(set(linux) - set(mac)), sorted(set(mac) - set(linux))
    skipped_here = sorted(t for t, status in linux.items() if status == 'skipped' and t in mac)
    disagree = sorted(t for t in set(linux) & set(mac)
                      if 'failed' in (linux[t], mac[t]) and linux[t] != mac[t])
    lines = [f'Linux: {len(linux)} tests ({counts(linux)})', f'Mac:   {len(mac)} tests ({counts(mac)})',
             "The Mac's parallel result file reports a test that skips itself as passed, so its skipped count reads low.",
             '', f'Only on Linux ({len(only_linux)}):', *only_linux,
             '', f'Only on the Mac ({len(only_mac)}):', *only_mac,
             '', f'Skipped on Linux, listed on the Mac ({len(skipped_here)}):', *skipped_here,
             '', f'Failed on one side only ({len(disagree)}):', *disagree,
             '', 'test\tlinux\tmac']
    lines += [f'{test}\t{linux.get(test, "-")}\t{mac.get(test, "-")}' for test in sorted(set(linux) | set(mac))]
    return '\n'.join(lines) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('run', help="run the tests in the job's swift image")
    compare = commands.add_parser('compare', help='write the Linux and Mac test lists side by side')
    compare.add_argument('--linux', type=Path, required=True, help='a Linux log, or a job log from gh run view --log')
    compare.add_argument('--mac', type=Path, required=True, help="the Mac's package-core.xunit.xml")
    compare.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == 'run':
        return run_tests(docker_command(), ROOT / LOG, ROOT / RESOLVED)
    linux, mac = linux_results(args.linux.read_text(errors='replace')), mac_results(args.mac)
    if not linux or not mac:
        print(f'no tests read: {len(linux)} from {args.linux}, {len(mac)} from {args.mac}', file=sys.stderr)
        return 1
    args.out.write_text(report(linux, mac))
    print(f'{len(linux)} on Linux, {len(mac)} on the Mac, {len(set(linux) - set(mac))} only on Linux, '
          f'{len(set(mac) - set(linux))} only on the Mac: {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
