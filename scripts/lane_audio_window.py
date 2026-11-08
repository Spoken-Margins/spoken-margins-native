"""Audio windows in app test runs (#1790): start ops/audio-loopback/window.py beside a run that includes an
AudioLoopback test by name, hand the test its folder, and turn its verdicts into lines for the lane report.

The run's tests see the folder as SM_AUDIO_WINDOW: xcodebuild passes TEST_RUNNER_<NAME> variables to the test
runner without the prefix. Runs that don't name an AudioLoopback test start nothing, so the Mac's audio is
touched only when a request names one. In a whole-plan run (Release, a full AudioAdapters) the test finds no
window and skips, and `unasked` lets that skip pass: nobody asked that run to listen.

A GitHub-hosted Mac (LANE_HOSTED_APP, every /lane request while it is `on`) has no BlackHole and no recorder app, so
it can never listen (#3604). There the window is not started, an AudioLoopback test's skip passes even when a request
names it, and the report says "not run: ... the audio check is still owed" instead of coming back INCONCLUSIVE. The
self-hosted Mac keeps the strict rule: a named test that could not listen fails the run.
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


NOT_RUN = ('not run: the hosted Mac has no audio loopback (no BlackHole, no recorder app). The audio check is '
           'still owed: the owner\'s pass, or a run on the Mac with BlackHole (ops/audio-loopback/README.md)')


def hosted(environ=None):
    """True on a GitHub-hosted runner (GitHub sets RUNNER_ENVIRONMENT=github-hosted there, and `self-hosted` on ours,
    which also sets GITHUB_ACTIONS=true, so that variable alone says nothing; see verify-tests.py on_hosted_runner)."""
    return (os.environ if environ is None else environ).get('RUNNER_ENVIRONMENT') == 'github-hosted'


def wants_audio(tests):
    return any(MARKER in test for test in tests or ())


def unasked(expected, selectors, hosted_runner=None):
    """The AudioLoopback tests that may skip. On the self-hosted Mac: all of them unless the run's selectors name
    one, since then the skip means the lane couldn't listen and the run must not pass. On a hosted Mac: all of them,
    named or not, because it can never listen (#3604); `not_run` records them so the report says so."""
    if hosted() if hosted_runner is None else hosted_runner:
        return {test for test in expected or () if MARKER in test}
    return set() if wants_audio(selectors) else {test for test in expected or () if MARKER in test}


def not_run(records, hosted_runner=None):
    """(the AudioLoopback tests in a step's test records that skipped on a hosted Mac, the report entries for them).
    Both are empty anywhere else: a skip there is either not asked for or a run that could not listen."""
    if not (hosted() if hosted_runner is None else hosted_runner):
        return [], []
    names = sorted(test for test, record in (records or {}).items()
                   if MARKER in test and record.get('status') == 'skipped')
    return names, [{'test': test, 'files': [], 'audio': {'verdict': 'NOT RUN', 'summary': NOT_RUN}} for test in names]


@contextlib.contextmanager
def serve(output, tests, out=sys.stdout, server=SERVER, python=sys.executable, hosted_runner=None):
    """Yields the window folder while the server runs, or None when `tests` (the run's -only-testing selectors)
    name no AudioLoopback test, or on a hosted Mac, which has nothing to record with (#3604)."""
    if (hosted() if hosted_runner is None else hosted_runner) or not wants_audio(tests) or not Path(server).exists():
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
