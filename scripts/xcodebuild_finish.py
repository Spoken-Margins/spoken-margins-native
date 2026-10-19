"""Stop an `xcodebuild test` that has reported its tests and then gone quiet without exiting (#2053).

On 2026-10-18 the Test Desk ran one UI test through scripts/xcodebuild-lane twice. Each run printed its summary
("Executed 1 test, with 0 failures", 55 s) and then sat with no output until someone killed it, 4 minutes in the
afternoon run. The wrapper waits on xcodebuild's process, so it held a Mac-wide build slot all that time, and the
next build or `lane-sim-boot --pool` queued behind it with nothing to end the wait.

The rule: once the run's top-level summary has printed (the "Executed" line after "Test Suite 'All tests'" or
"'Selected tests'" finishes, or xcodebuild's own "** TEST … **" banner), a run that then prints nothing for
GRACE_SECONDS is finished. Its process group gets SIGINT first, which lets xcodebuild write the result bundle,
then SIGTERM and SIGKILL. The caller says that it was forced and reports the result the log already shows.
Any new output restarts the quiet period, and a suite that starts after a summary (a scheme's next test bundle) clears it
until that bundle reports in turn.

Each test bundle prints its own 'All tests' or 'Selected tests' summary, so the quiet spell can also be a scheme's next
bundle being installed and launched, which on this Mac can take minutes. A forced stop therefore reports a pass only
when the summary speaks for the whole run: xcodebuild's own banner printed, or the command selects tests in one bundle
and nothing (a test plan, an .xctestrun, iterations or retries) can run them again. Otherwise it reports 65.
"""
import contextlib
import os
import re
import signal
import time

GRACE_SECONDS = float(os.environ.get('SM_TEST_FINISH_GRACE_SECONDS', '120'))
TEST_FAILED_EXIT = 65  # what xcodebuild itself exits with when tests fail

TOP_SUITE_END = re.compile(r"^\s*Test Suite '(?:All tests|Selected tests)' (?:passed|failed) at ")
EXECUTED = re.compile(r'^\s*Executed (\d+) tests?, with (\d+) failures?')
SUITE_STARTED = re.compile(r"^\s*Test Suite '[^']+' started at ")
BANNER = re.compile(r'^\*\* TEST (?:EXECUTE )?(SUCCEEDED|FAILED) \*\*')


class FinishWatch:
    """Fed the run's output line by line; says when a run that has reported its tests has been quiet too long."""

    def __init__(self, grace=None, clock=time.monotonic):
        self.grace = GRACE_SECONDS if grace is None else grace
        self.clock = clock
        self.last_output = clock()
        self.summary_seen = False
        self.after_top_suite = False
        self.failed = False
        self.banner_seen = False
        self.executed = None  # tests in the last top-level summary

    def feed(self, line):
        self.last_output = self.clock()
        if SUITE_STARTED.match(line) and not self.banner_seen:
            self.summary_seen = False  # another bundle (or configuration) has begun; wait for its own summary
        elif TOP_SUITE_END.match(line):
            self.after_top_suite = True
            self.failed = self.failed or " failed at " in line
        elif self.after_top_suite and (match := EXECUTED.match(line)):
            self.after_top_suite = False
            self.summary_seen = True
            self.executed = int(match[1])
            self.failed = self.failed or int(match[2]) > 0
        elif match := BANNER.match(line):
            self.summary_seen = self.banner_seen = True
            self.failed = self.failed or match[1] == 'FAILED'
        elif (match := EXECUTED.match(line)) and int(match[2]) > 0:
            self.failed = True  # an inner suite's failures count even if the top-level line never comes

    def overdue(self):
        """Seconds the run has been quiet since its summary, once that passes the grace period; else None."""
        quiet = self.clock() - self.last_output
        return quiet if self.summary_seen and quiet >= self.grace else None

    def result(self):
        """The exit code the summary shows: 0 when every reported test passed, else xcodebuild's own 65."""
        return TEST_FAILED_EXIT if self.failed else 0

    def forced_result(self, args):
        """(exit code, why it isn't a pass) for a run stopped after its summary, given xcodebuild's arguments.
        A summary without failures is a pass only if it covers every test the command would run; else 65."""
        if self.failed:
            return TEST_FAILED_EXIT, None
        if self.banner_seen or one_bundle(args):
            return 0, None
        return TEST_FAILED_EXIT, ('reporting 65: the summary is one test bundle\'s, and it could not confirm every '
                                  'test bundle this command selects had run')

    def note(self, quiet):
        tests = '' if self.executed is None else f' ({self.executed} tests, {"failed" if self.failed else "passed"})'
        return (f'xcodebuild reported its tests{tests} but printed nothing for {quiet:.0f}s and had not exited; '
                f'stopped it (forced, #2053)')


REPEATS = {'-testPlan', '-xctestrun', '-test-iterations', '-retry-tests-on-failure', '-run-tests-until-failure'}


def one_bundle(args):
    """Whether xcodebuild's arguments select tests in a single test bundle that run once, so one bundle's summary
    is the whole run's. No -only-testing means every bundle in the scheme; a test plan, an .xctestrun, iterations or
    retries can run a bundle again and print another summary."""
    if REPEATS.intersection(args):
        return False
    selectors = [arg.split(':', 1)[1] for arg in args if arg.startswith('-only-testing:')]
    selectors += [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == '-only-testing']
    targets = {selector.split('/', 1)[0] for selector in selectors}
    return len(targets) == 1 and '' not in targets


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:  # on macOS a group of zombies gives EPERM
        return False
    return True


def stop_group(process, interrupt_wait=30, term_wait=10):
    """SIGINT, then SIGTERM, then SIGKILL to the process group led by `process` (started with start_new_session).
    Waits for the whole group, not just the leader, at each stage. Returns the signal that ended it."""
    for signum, wait in ((signal.SIGINT, interrupt_wait), (signal.SIGTERM, term_wait), (signal.SIGKILL, 5)):
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, signum)
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            process.poll()  # reap the leader, so a zombie leader doesn't count as alive
            if not group_alive(process.pid):
                process.wait()
                return signum
            time.sleep(0.1)
    process.wait()
    return signal.SIGKILL
