#!/usr/bin/env python3
"""Run scripts/tests one module per process, a few processes at a time (2026-11-20, #4769).

verify-tests.py's runner-tests step ran its 3,855 tests in one process: 963 s on the owner's Mac and 996 s at p50 on
the hosted portable job, the longest step of the merge queue's Linux check. The tests are independent and mostly wait
on subprocesses, so this runs each test module in its own `python` process, JOBS at a time, the slowest modules first
(by scripts/runner_test_seconds.json; a module not in it counts as the slowest, so a new one is never left for last).
A worker takes the next module when it finishes one, so a stale table costs balance, never coverage.

It prints one line per module as it finishes, the whole output of any module that failed, and at the end the same
"Ran N tests in Xs" and "OK" / "FAILED (...)" lines unittest prints, so verify-tests.py's zero-tests check reads it as
before. Exit status 0 only when every module ran and passed.

    python3 scripts/parallel_unittest.py [--jobs N] [--times-out FILE] [--leave-out PREFIX ...]

--leave-out drops tests whose id starts with PREFIX (verify-tests.py's PORTABLE_RUNNER_TESTS_LEFT_OUT); a module whose
every test is left out is not started. --times-out writes each module's seconds, to refresh the table.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# The tests are found from the working directory, as `unittest discover -s scripts/tests` finds them
# (verify-tests.py runs the step from the checkout's root); the weights live beside this script.
WEIGHTS = Path(__file__).resolve().parent / 'runner_test_seconds.json'
DEFAULT_JOBS = 4
# A module still running after this long is killed and fails the step by name. The slowest took 107 s alone
# (runner_test_seconds.json) and up to 189 s with four running on the owner's Mac (test_sm_status). The "still
# running" lines keep verify-tests.py's 240 s stall rule from firing, so this is the hang bound now.
def module_timeout(value):
    try:
        return float(value) if float(value) > 0 else 480.0
    except (TypeError, ValueError):
        return 480.0


MODULE_TIMEOUT = module_timeout(os.environ.get('SM_RUNNER_TEST_MODULE_TIMEOUT'))
HEARTBEAT_SECONDS = 60
# Each module runs in its own process group so a timeout kills its whole tree (a swiftc it started, say). That puts
# it outside the step's group, which verify-tests.py signals on a step timeout or stall, so SIGTERM here kills every
# live module group before this process exits.
CHILDREN = {}
CHILDREN_LOCK = threading.Lock()


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def stop_children(number, frame):
    with CHILDREN_LOCK:
        for pid in list(CHILDREN):
            kill_group(pid)
    os.write(1, f'parallel_unittest.py: stopped by signal {number}; killed every running module\n'.encode())
    os._exit(128 + number)

# One module, with the left-out ids dropped (a test id starting with any PREFIX is not run).
MODULE_LOADER = '''
import sys, unittest
sys.path.insert(0, "scripts/tests")
module, left_out = sys.argv[1], tuple(sys.argv[2:])
def tests(suite):
    for item in suite:
        yield from tests(item) if isinstance(item, unittest.TestSuite) else [item]
kept = unittest.TestSuite(t for t in tests(unittest.defaultTestLoader.loadTestsFromName(module))
                          if not t.id().startswith(left_out))
sys.exit(not unittest.TextTestRunner().run(kept).wasSuccessful())
'''

RAN = re.compile(r'^Ran (\d+) tests? in ', re.M)
COUNTS = re.compile(r'(failures|errors|skipped|expected failures|unexpected successes)=(\d+)')


def modules(tests_dir):
    """The modules `unittest discover -s scripts/tests` loads: test*.py at the top level. A test package below it
    would be loaded by discover and not here, so it stops the run rather than drop its tests unseen."""
    nested = sorted(str(path) for path in tests_dir.glob('*/**/test*.py'))
    if nested:
        raise SystemExit(f'parallel_unittest.py runs top-level test modules only; move or list these: {nested}')
    return sorted(path.stem for path in tests_dir.glob('test*.py'))


def wholly_left_out(module, left_out):
    return any(prefix in (module, module + '.') for prefix in left_out)


def order(names, weights):
    """Slowest first; a module with no recorded time first of all (it may be the slowest)."""
    return sorted(names, key=lambda name: (name in weights, -weights.get(name, 0.0), name))


def summary(output):
    """(tests run, {failures, errors, skipped...}) from a unittest run's output; run is None when it never finished."""
    found = RAN.findall(output)
    tail = output[output.rfind('\nRan '):] if found else ''
    return (int(found[-1]) if found else None), {key: int(value) for key, value in COUNTS.findall(tail)}


def run_all(names, jobs, left_out=(), cwd='.', out=sys.stdout, python=sys.executable,
            module_timeout=MODULE_TIMEOUT, heartbeat=HEARTBEAT_SECONDS):
    queue = list(names)
    lock = threading.Lock()
    results = {}
    running = {}

    def report(name, line, output=None):
        with lock:
            print(line, file=out, flush=True)
            if output is not None:
                print(f'----- {name} output -----\n{output.rstrip()}\n----- end of {name} -----', file=out, flush=True)

    def run_one(name):
        start = time.monotonic()
        with lock:
            running[name] = start
        with tempfile.TemporaryFile() as log:
            with CHILDREN_LOCK:
                child = subprocess.Popen([python, '-c', MODULE_LOADER, name, *left_out], cwd=cwd, stdout=log,
                                         stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
                CHILDREN[child.pid] = name
            try:
                code, timed_out = child.wait(timeout=module_timeout), False
            except subprocess.TimeoutExpired:
                kill_group(child.pid)
                code, timed_out = child.wait(), True
            finally:
                kill_group(child.pid)  # anything the module left behind in its group
                with CHILDREN_LOCK:
                    CHILDREN.pop(child.pid, None)
            log.seek(0)
            output = log.read().decode('utf-8', errors='replace')  # a test may print any bytes
        seconds = time.monotonic() - start
        ran, counts = summary(output)
        ok = code == 0 and ran is not None and not timed_out
        verdict = ('ok' if ok else f'FAILED (killed after {module_timeout:.0f}s)' if timed_out
                   else f'FAILED (exit {code})')
        with lock:
            running.pop(name, None)
            results[name] = {'seconds': round(seconds, 1), 'ran': ran or 0, 'ok': ok, **counts}
        report(name, f'{name}: {ran if ran is not None else "no"} tests in {seconds:.1f}s - {verdict}',
               None if ok else output)

    def worker():
        while True:
            with lock:
                if not queue:
                    return
                name = queue.pop(0)
            try:
                run_one(name)
            except BaseException as error:  # never lose a module: an unexpected error is that module's failure
                with lock:
                    running.pop(name, None)
                    results[name] = {'seconds': 0.0, 'ran': 0, 'ok': False}
                report(name, f'{name}: FAILED (parallel_unittest.py error: {error!r})')

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(max(1, jobs))]
    for thread in threads:
        thread.start()
    # A line while slow modules run, so the step's stall watcher sees progress and a hang names its module.
    last = time.monotonic()
    while any(thread.is_alive() for thread in threads):
        for thread in threads:
            thread.join(timeout=heartbeat / max(1, len(threads)))
        if time.monotonic() - last < heartbeat:
            continue
        last = time.monotonic()
        with lock:
            now = time.monotonic()
            busy = ', '.join(f'{name} {now - start:.0f}s' for name, start in sorted(running.items())
                             if now - start >= heartbeat)
        if busy:
            report(None, f'still running: {busy}')
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--jobs', type=int, default=int(os.environ.get('SM_RUNNER_TEST_JOBS') or
                                                         min(DEFAULT_JOBS, os.cpu_count() or 1)))
    parser.add_argument('--times-out', type=Path)
    parser.add_argument('--leave-out', nargs='*', default=[])
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(errors='backslashreplace')
    for number in (signal.SIGTERM, signal.SIGINT):
        signal.signal(number, stop_children)  # a failing test's output reaches any log, even an ASCII one
    left_out = tuple(args.leave_out)
    weights = json.loads(WEIGHTS.read_text())['seconds'] if WEIGHTS.exists() else {}
    names = order([name for name in modules(Path('scripts/tests')) if not wholly_left_out(name, left_out)], weights)
    print(f'{len(names)} test modules in {args.jobs} processes, slowest first', flush=True)
    start = time.monotonic()
    results = run_all(names, args.jobs, left_out)
    wall = time.monotonic() - start
    missing = sorted(set(names) - set(results))
    if args.times_out:
        args.times_out.write_text(json.dumps({name: value['seconds'] for name, value in sorted(results.items())},
                                             indent=1) + '\n')
    total = sum(value['ran'] for value in results.values())
    failed = sorted(name for name, value in results.items() if not value['ok']) + missing
    failures = sum(value.get('failures', 0) for value in results.values())
    errors = sum(value.get('errors', 0) for value in results.values())
    skipped = sum(value.get('skipped', 0) for value in results.values())
    busy = sum(value['seconds'] for value in results.values())
    print(f'{len(results)} modules, {busy:.0f}s of module time in {wall:.0f}s', flush=True)
    print(f'Ran {total} test{"" if total == 1 else "s"} in {wall:.3f}s\n', flush=True)
    if failed:
        print(f'FAILED (failures={failures}, errors={errors}; modules: {", ".join(failed)})', flush=True)
        return 1
    print('OK' + (f' (skipped={skipped})' if skipped else ''), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
