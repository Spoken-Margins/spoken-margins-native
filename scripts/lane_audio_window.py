"""Audio windows in app test runs (#1790): start ops/audio-loopback/window.py beside a run that includes an
AudioLoopback test by name, hand the test its folder, and turn its verdicts into lines for the lane report.

The run's tests see the folder as SM_AUDIO_WINDOW: xcodebuild passes TEST_RUNNER_<NAME> variables to the test
runner without the prefix. Runs that don't name an AudioLoopback test start nothing, so the Mac's audio is
touched only when a request names one. In a whole-plan run (Release, a full AudioAdapters) the test finds no
window and skips, and `unasked` lets that skip pass: nobody asked that run to listen.
"""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / 'ops/audio-loopback/window.py'
ENV = 'TEST_RUNNER_SM_AUDIO_WINDOW'
MARKER = 'AudioLoopback'
READY_WAIT = 20
STOP_WAIT = 30  # a stop in mid-window lets route put the default output back first


def wants_audio(tests):
    return any(MARKER in test for test in tests or ())


def unasked(expected, selectors):
    """The AudioLoopback tests that may skip: all of them unless the run's selectors name one, since then the
    skip means the lane couldn't listen and the run must not pass."""
    return set() if wants_audio(selectors) else {test for test in expected or () if MARKER in test}


@contextlib.contextmanager
def serve(output, tests, out=sys.stdout, server=SERVER, python=sys.executable):
    """Yields the window folder while the server runs, or None when `tests` (the run's -only-testing selectors)
    name no AudioLoopback test."""
    if not wants_audio(tests) or not Path(server).exists():
        yield None
        return
    folder = Path(output) / 'audio-window'
    folder.mkdir(parents=True, exist_ok=True)
    log = (folder / 'server.log').open('w')
    process = subprocess.Popen([python, str(server), 'serve', '--dir', str(folder), '--parent-pid', str(os.getpid())],
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + READY_WAIT
    while not (folder / 'ready.json').exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.1)
    if not (folder / 'ready.json').exists():
        print(f'warning: the audio window server did not start; see {folder}/server.log', file=out, flush=True)
    previous = os.environ.get(ENV)
    os.environ[ENV] = str(folder)
    try:
        yield folder
    finally:
        if previous is None:
            os.environ.pop(ENV, None)
        else:
            os.environ[ENV] = previous
        stop(process)
        log.close()


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=STOP_WAIT)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def attachments(folder):
    """One attachments entry per answered window, in the shape lane_xcresult_attachments.report_lines reads."""
    if not folder:
        return []
    entries = []
    for path in sorted(Path(folder).glob('*.result.json'), key=lambda p: p.stat().st_mtime):
        try:
            result = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            entries.append({'test': path.name, 'files': [str(path)], 'error': f'unreadable verdict: {error}',
                            'export_log': str(Path(folder) / 'server.log')})
            continue
        files = [str(path)] + [result[key] for key in ('wav',) if result.get(key)]
        entries.append({'test': result.get('test') or path.name, 'files': files,
                        'audio': {'verdict': result.get('verdict'), 'summary': result.get('summary', '')}})
    return entries
