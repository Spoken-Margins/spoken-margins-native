#!/usr/bin/env python3
"""One bounded, owner-approved check of repaired PosterBoard state; never retries."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def new_crash(reports, baseline, device):
    for path in reports.glob('*.ips'):
        signature = (path.stat().st_mtime_ns, path.stat().st_size)
        if baseline.get(path) == signature:
            continue
        if f'com.apple.CoreSimulator.SimDevice.{device}' in path.read_text(errors='replace'):
            return path
    return None


def poster_state(store):
    configurations = list(store.glob('*/Extensions/*/configurations/*'))
    clocks = [p for p in configurations if p.parent.parent.name == 'com.apple.ClockPoster.ClockPosterExtension']
    missing = [str(p.relative_to(store)) for p in configurations
               if not (p / 'com.apple.posterkit.provider.descriptor.identifier').is_file()
               or not (p / 'com.apple.posterkit.provider.descriptor.identifier').read_text().strip()]
    return {'configurations': len(configurations), 'clock_configurations': len(clocks),
            'missing_identifiers': missing,
            'complete': len(clocks) == 5 and not missing}


def supervise(boot, shutdown, crash, state, *, clock=time.monotonic, sleep=time.sleep,
              timeout=180, stable_seconds=60):
    """Observe one boot; shut down on first report, deadline, interruption or success."""
    deadline = clock() + timeout
    healthy_since = None
    result = {'status': 'incomplete'}
    try:
        boot()
        while clock() < deadline:
            report = crash()
            if report:
                result.update(status='failed', crash_report=str(report))
                return result
            current = state()
            result['poster_state'] = current
            if current['complete']:
                if healthy_since is None:
                    healthy_since = clock()
                if clock() - healthy_since >= stable_seconds:
                    result.update(status='verified', stable_seconds=stable_seconds)
                    return result
            else:
                healthy_since = None
            sleep(0.1)
        result['reason'] = 'PosterBoard did not rebuild valid state within the bounded check.'
        return result
    finally:
        shutdown()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    # This is a recovery operation, not an alternative app-test runner. Agent
    # instructions require explicit approval after the September 16 stop.
    inventory = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))['devices']
    selected = [d for group in inventory.values() for d in group if d['udid'] == args.device]
    if len(selected) != 1 or selected[0]['state'] != 'Shutdown':
        parser.error('The selected simulator must exist and be shut down.')
    if any(d['state'] == 'Booted' for group in inventory.values() for d in group):
        parser.error('Another simulator is running; refusing to add resource load.')
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    if not reports.is_dir():
        parser.error('Crash-report directory is unavailable; refusing an unobserved boot.')
    baseline = {p: (p.stat().st_mtime_ns, p.stat().st_size) for p in reports.glob('*.ips')}
    store = Path(selected[0]['dataPath']) / 'Library/Application Support/PRBPosterExtensionDataStore'
    args.output.mkdir(parents=True, exist_ok=False)
    process = None
    result = {'status': 'incomplete', 'device': args.device}
    with (args.output / 'boot.log').open('w') as log:
        def boot():
            nonlocal process
            process = subprocess.Popen(['xcrun', 'simctl', 'boot', args.device],
                                       stdout=log, stderr=subprocess.STDOUT)

        def shutdown():
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)
            subprocess.run(['xcrun', 'simctl', 'shutdown', args.device],
                           check=True, timeout=15, stdout=log, stderr=subprocess.STDOUT)

        def state():
            if process is not None and process.poll() not in (None, 0):
                raise RuntimeError(f'Simulator boot failed with exit {process.returncode}')
            return poster_state(store)

        try:
            result.update(supervise(boot, shutdown,
                                    lambda: new_crash(reports, baseline, args.device),
                                    state))
        except BaseException as error:
            result.update(status='incomplete', error=str(error))
            raise
        finally:
            (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'verified' else 1


if __name__ == '__main__':
    raise SystemExit(main())
