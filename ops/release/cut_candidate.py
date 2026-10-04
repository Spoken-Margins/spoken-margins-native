#!/usr/bin/env python3
"""Cut a Build N release candidate from next, unattended (#687).

The Build 30 cut was a one-time Claude scheduled task. It stalled at 21:00 on 2026-10-01 on its
first command, waiting for a permission prompt nobody was there to answer, and Build 30 missed the
owner's Friday window. Every step was mechanical, so this script does them, run once by the owner
(`--at <time>`, or the launchd template beside it) or on demand.

Steps, stopping at the first failure:
1. Fetch. With `--wait-for`, wait until those PRs merge or `--deadline` passes, then record whether
   each one is in the candidate commit (a PR that isn't in doesn't stop the cut).
2. Push `release/build-<N>` at origin/next's tip, or at `--commit`. Refuse if the branch already
   exists at another commit.
3. Hold the rolling phone-build job (`launchctl bootout` and `disable`, so a restart doesn't load it
   again and move ~/SpokenMargins-phone/latest off the candidate), then run `scripts/phone-build --commit <sha>` and check latest/build.json names it.
4. Append a "Build N candidate" section (the waited-for PRs and the `--known-issues` file) to that
   build's test-plan.md, and copy it to iCloud Drive "Spoken Margins test plans".
5. Ask the Test Desk for T5 on #184, post the candidate note on #337 (with the command that turns the
   phone-build job back on), and send a Mac notification.

On a failure it posts what stopped on #337 and notifies. A held phone-build job is turned back on only
if the build hadn't finished; after a good build it stays held, so `latest` keeps the candidate. It never retries, and it never bumps the version, archives, uploads, tags or touches `main`.
A finished or stopped cut leaves ~/SpokenMarginsOps/release/build-<N>.json; a second run for the same
build does nothing unless given `--again`. `--dry-run` prints the plan and changes nothing.

Environment (tests): SM_CUT_REPO (the checkout; default this one), SM_CUT_GH (the gh command),
SM_CUT_PHONE_BUILD (default <repo>/scripts/phone-build), SM_CUT_LAUNCHCTL (launchctl),
SM_CUT_NOTIFY (the notification command, default osascript; `off` skips it), SM_CUT_STATE_DIR,
SM_PHONE_DIR and SM_PHONE_ICLOUD (shared with scripts/phone-build and the installer).
Stdlib only, Python 3.9-compatible: launchd runs it under /usr/bin/python3.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Optional

HERE = Path(__file__).resolve().parent
REPO = 'uncomposed/spoken-margins-native'
BRANCH = 'next'
STATUS_ISSUE = 337       # where the Mac tick and candidate notes go
REPORTS_ISSUE = 184      # where the Test Desk takes T5 requests and posts reports
PHONE_JOB = 'com.spokenmargins.phone-build'
PR_POLL_SECONDS = 120
PHONE_LOCK_WAIT_SECONDS = 90 * 60
PHONE_BUILD_TIMEOUT_SECONDS = 4 * 3600
RELEASE_REF = re.compile(r'^refs/heads/release/build-\d+$')


class CutFailed(Exception):
    pass


@dataclass
class Settings:
    repo: Path
    gh: List[str]
    phone_build: List[str]
    launchctl: List[str]
    notify: str
    state_dir: Path
    phone_dir: Path
    icloud: Path
    pr_poll_seconds: float = PR_POLL_SECONDS
    phone_lock_wait_seconds: float = PHONE_LOCK_WAIT_SECONDS

    @classmethod
    def from_env(cls, env=None) -> 'Settings':
        env = os.environ if env is None else env
        home = Path.home()
        repo = Path(env.get('SM_CUT_REPO') or HERE.parents[1])
        return cls(
            repo=repo,
            gh=env.get('SM_CUT_GH', 'gh').split(),
            phone_build=(env['SM_CUT_PHONE_BUILD'].split() if env.get('SM_CUT_PHONE_BUILD')
                         else [sys.executable, str(repo / 'scripts/phone-build')]),
            launchctl=env.get('SM_CUT_LAUNCHCTL', 'launchctl').split(),
            notify=env.get('SM_CUT_NOTIFY', 'osascript'),
            state_dir=Path(env.get('SM_CUT_STATE_DIR') or home / 'SpokenMarginsOps/release'),
            phone_dir=Path(env.get('SM_PHONE_DIR') or home / 'SpokenMargins-phone'),
            icloud=Path(env.get('SM_PHONE_ICLOUD') or
                        home / 'Library/Mobile Documents/com~apple~CloudDocs/Spoken Margins test plans'),
        )


def parse_when(text: str, now: dt.datetime) -> dt.datetime:
    """`HH:MM` is its next occurrence after `now` (today, or tomorrow once it has passed);
    `YYYY-MM-DDTHH:MM` is that moment. Local time, no time zone."""
    text = text.strip()
    match = re.fullmatch(r'(\d{1,2}):(\d{2})', text)
    if match:
        hour, minute = int(match.group(1)), int(match.group(2))
        if hour > 23 or minute > 59:
            raise ValueError(f'not a time of day: {text}')
        when = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        return when if when > now else when + dt.timedelta(days=1)
    try:
        when = dt.datetime.fromisoformat(text)
    except ValueError:
        raise ValueError(f'expected HH:MM or YYYY-MM-DDTHH:MM, got {text!r}') from None
    return when.replace(tzinfo=None)


def pr_numbers(values: List[str]) -> List[int]:
    numbers = []
    for value in values:
        for part in re.split(r'[,\s]+', value.strip()):
            if part:
                numbers.append(int(part.lstrip('#')))
    return list(dict.fromkeys(numbers))


def release_ref(build: int) -> str:
    return f'refs/heads/release/build-{build}'


@dataclass
class PullState:
    number: int
    merged: bool = False
    merge_sha: str = ''
    merged_at: str = ''
    included: bool = False

    def describe(self, deadline_text: str) -> str:
        if self.included:
            return f'#{self.number} in'
        if self.merged:
            return f'#{self.number} merged after this commit, so not in'
        return f'#{self.number} not merged by {deadline_text}, so not in'


@dataclass
class Cut:
    args: argparse.Namespace
    settings: Settings
    clock: Callable[[], dt.datetime] = dt.datetime.now
    sleep: Callable[[float], None] = time.sleep
    out: Callable[[str], None] = lambda line: print(f'[cut] {line}', flush=True)
    done: List[str] = field(default_factory=list)
    pulls: List[PullState] = field(default_factory=list)
    sha: str = ''
    held_job: bool = False
    built: bool = False
    start_at: Optional[dt.datetime] = None
    deadline: Optional[dt.datetime] = None
    deadline_text: str = ''
    build_folder: Optional[Path] = None
    plan_copy: Optional[Path] = None
    report_url: str = ''

    # ---- small helpers -------------------------------------------------------------------------

    def git(self, *args, check=True) -> str:
        done = subprocess.run(['git', *args], cwd=str(self.settings.repo), capture_output=True, text=True)
        if check and done.returncode != 0:
            raise CutFailed(f'git {" ".join(args)} failed: {done.stderr.strip()}')
        return done.stdout.strip()

    def gh(self, *args) -> Optional[str]:
        try:
            done = subprocess.run([*self.settings.gh, *args], capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout if done.returncode == 0 else None

    def post(self, issue: int, body: str) -> str:
        """Comment on an issue; returns the comment's URL. Raises CutFailed when GitHub refuses."""
        with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as handle:
            handle.write(body)
        try:
            output = self.gh('api', '-X', 'POST', f'repos/{REPO}/issues/{issue}/comments',
                             '-F', f'body=@{handle.name}', '--jq', '.html_url')
        finally:
            os.unlink(handle.name)
        if output is None:
            raise CutFailed(f'could not comment on #{issue} (gh failed)')
        return output.strip()

    def launchctl(self, *args) -> int:
        try:
            return subprocess.run([*self.settings.launchctl, *args], capture_output=True, timeout=60).returncode
        except (OSError, subprocess.TimeoutExpired):
            return -1

    def notify(self, title: str, message: str) -> None:
        """A macOS notification, like scripts/phone-build's. Never fails the cut."""
        if self.settings.notify == 'off':
            return
        script = ['-e', 'on run argv', '-e',
                  'display notification (item 1 of argv) with title (item 2 of argv) sound name "Glass"',
                  '-e', 'end run']
        try:
            subprocess.run([*self.settings.notify.split(), *script, message, title], capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            pass

    def wait_until(self, when: dt.datetime) -> None:
        # Short sleeps against the wall clock, so a Mac that slept through the time starts on waking.
        while True:
            left = (when - self.clock()).total_seconds()
            if left <= 0:
                return
            self.sleep(min(left, 30))

    @property
    def job_target(self) -> str:
        return f'gui/{os.getuid()}/{PHONE_JOB}'

    @property
    def enable_command(self) -> str:
        return (f'launchctl enable gui/$(id -u)/{PHONE_JOB} && '
                f'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/{PHONE_JOB}.plist')

    @property
    def branch(self) -> str:
        return f'release/build-{self.args.build}'

    @property
    def marker(self) -> Path:
        return self.settings.state_dir / f'build-{self.args.build}.json'

    def step(self, text: str) -> None:
        self.done.append(text)
        self.out(text)

    # ---- the steps -----------------------------------------------------------------------------

    def fetch(self) -> None:
        self.git('fetch', 'origin', BRANCH, '--prune', '--quiet')

    def read_pull(self, number: int) -> PullState:
        output = self.gh('api', f'repos/{REPO}/pulls/{number}')
        if output is None:
            raise CutFailed(f'could not read PR #{number} (gh failed)')
        data = json.loads(output)
        return PullState(number, merged=bool(data.get('merged_at')), merge_sha=data.get('merge_commit_sha') or '',
                         merged_at=data.get('merged_at') or '')

    def read_times(self) -> None:
        """Read `--at` and `--deadline` once, at the start: an HH:MM deadline is its next occurrence after the
        start time, so a Mac that slept past both, or a late `--again`, doesn't wait until tomorrow."""
        now = self.clock()
        self.start_at = parse_when(self.args.at, now) if self.args.at else None
        if self.args.deadline:
            self.deadline = parse_when(self.args.deadline, (self.start_at or now) - dt.timedelta(seconds=1))
            self.deadline_text = self.deadline.strftime('%Y-%m-%d %H:%M')

    def wait_for_pulls(self, wait: bool) -> None:
        numbers = pr_numbers(self.args.wait_for or [])
        if not numbers:
            return
        deadline = self.deadline or self.clock()
        while True:
            try:
                states = [self.read_pull(number) for number in numbers]
            except CutFailed as failure:
                # One failed read (a network blip, a rate limit) doesn't end a long wait; the last one does.
                if not wait or self.clock() >= deadline:
                    raise
                self.out(f'{failure}; trying again at the next poll')
                self.sleep(min(self.settings.pr_poll_seconds, max(1.0, (deadline - self.clock()).total_seconds())))
                continue
            if all(state.merged for state in states) or not wait or self.clock() >= deadline:
                break
            waiting = ', '.join(f'#{state.number}' for state in states if not state.merged)
            self.out(f'waiting for {waiting} to merge (until {self.deadline_text})')
            self.sleep(min(self.settings.pr_poll_seconds, max(1.0, (deadline - self.clock()).total_seconds())))
        self.pulls = states

    def resolve_commit(self) -> None:
        if any(state.merged for state in self.pulls):
            self.fetch()  # a PR that merged while we waited moved next
        target = self.args.commit or f'origin/{BRANCH}'
        self.sha = self.git('rev-parse', '--verify', f'{target}^{{commit}}')
        for state in self.pulls:
            state.included = bool(state.merge_sha) and subprocess.run(
                ['git', 'merge-base', '--is-ancestor', state.merge_sha, self.sha], cwd=str(self.settings.repo),
                capture_output=True).returncode == 0

    def remote_branch_sha(self) -> str:
        line = self.git('ls-remote', '--heads', 'origin', self.branch)
        return line.split()[0] if line else ''

    def push_release(self, dry_run: bool) -> None:
        existing = self.remote_branch_sha()
        if existing and existing != self.sha:
            raise CutFailed(f'{self.branch} already exists at {existing[:7]}, not {self.sha[:7]}; '
                            'nothing was pushed (delete the branch or pick that commit with --commit)')
        if existing:
            self.step(f'{self.branch} is already at {self.sha[:7]}')
            return
        if dry_run:
            self.out(f'would push {self.branch} at {self.sha[:7]}')
            return
        push_ref(self.git, self.sha, release_ref(self.args.build))
        self.step(f'pushed {self.branch} at {self.sha[:7]}')

    def hold_phone_job(self) -> None:
        if self.launchctl('print', self.job_target) != 0:
            self.step(f'the rolling phone-build job ({PHONE_JOB}) is not loaded, so nothing to hold')
            return
        if self.launchctl('bootout', self.job_target) != 0:
            raise CutFailed(f'launchctl bootout {self.job_target} failed, so the rolling build could move `latest`')
        self.held_job = True
        # Disabled too, so a restart or login doesn't load it again and move `latest` off the candidate.
        if self.launchctl('disable', self.job_target) != 0:
            raise CutFailed(f'launchctl disable {self.job_target} failed, so a restart would turn the rolling build '
                            'back on')
        self.step(f'held the rolling phone-build job ({PHONE_JOB})')

    def wait_for_phone_lock(self) -> None:
        """A phone build started by hand still holds scripts/phone-build's lock; wait for it."""
        self.settings.phone_dir.mkdir(parents=True, exist_ok=True)
        give_up = self.clock() + dt.timedelta(seconds=self.settings.phone_lock_wait_seconds)
        with open(self.settings.phone_dir / '.phone-build.lock', 'a+') as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    return
                except BlockingIOError:
                    if self.clock() >= give_up:
                        raise CutFailed('another phone build kept running for '
                                        f'{self.settings.phone_lock_wait_seconds / 60:.0f} minutes') from None
                    self.out('another phone build is running; waiting for it to finish')
                    self.sleep(30)

    def phone_build(self) -> None:
        self.wait_for_phone_lock()
        self.out(f'building {self.sha[:7]} for the phone (scripts/phone-build waits for a build slot)')
        try:
            code = subprocess.run([*self.settings.phone_build, '--commit', self.sha], cwd=str(self.settings.repo),
                                  timeout=PHONE_BUILD_TIMEOUT_SECONDS).returncode
        except subprocess.TimeoutExpired:
            raise CutFailed(f'scripts/phone-build ran over {PHONE_BUILD_TIMEOUT_SECONDS // 3600} hours') from None
        except OSError as error:
            raise CutFailed(f'could not run scripts/phone-build: {error}') from None
        if code != 0:
            why = 'it skipped: memory or disk too low' if code == 75 else f'exit {code}'
            raise CutFailed(f'scripts/phone-build failed ({why}); its log is {self.settings.phone_dir}/last-failure.log')
        latest = self.settings.phone_dir / 'latest'
        try:
            info = json.loads((latest / 'build.json').read_text())
        except (OSError, ValueError):
            raise CutFailed(f'scripts/phone-build finished but {latest}/build.json is missing or unreadable') from None
        if info.get('sha') != self.sha:
            raise CutFailed(f'{latest}/build.json names {str(info.get("sha"))[:7]}, not {self.sha[:7]}')
        self.build_folder = latest.resolve()
        self.built = True
        version = info.get('bundle_version')
        self.step(f'built {self.sha[:7]} for the phone: {self.build_folder}'
                  + (f' (bundle version {version})' if version else ''))

    def candidate_section(self) -> str:
        lines = [f'## Build {self.args.build} candidate', '',
                 f'Release branch `{self.branch}` at `{self.sha[:7]}`.']
        if self.pulls:
            lines.append('Waited for: ' + '; '.join(state.describe(self.deadline_text) for state in self.pulls) + '.')
        lines.append('')
        if self.args.known_issues:
            known = Path(self.args.known_issues).read_text().strip()
            if not known.startswith('#'):
                known = '### Known issues\n\n' + known
            lines += [known, '']
        else:
            lines += ['No known issues were given for this candidate.', '']
        return '\n'.join(lines)

    def update_plan(self) -> None:
        plan = self.build_folder / 'test-plan.md'
        if not plan.exists():
            raise CutFailed(f'{plan} is missing, so there is no test plan to send')
        text = plan.read_text()
        heading = f'## Build {self.args.build} candidate'
        if heading not in text:  # `--again` on the same build doesn't add it twice
            plan.write_text(text.rstrip('\n') + '\n\n' + self.candidate_section())
        try:
            self.settings.icloud.mkdir(parents=True, exist_ok=True)
            self.plan_copy = self.settings.icloud / f'Build {self.args.build} test plan {self.sha[:7]}.md'
            shutil.copyfile(plan, self.plan_copy)
        except OSError as error:
            raise CutFailed(f'could not copy the test plan to iCloud Drive ({self.settings.icloud}): {error}') from None
        self.step(f'test plan ready: iCloud Drive > {self.settings.icloud.name} > {self.plan_copy.name}')

    def t5_request(self) -> str:
        waited = '; '.join(state.describe(self.deadline_text) for state in self.pulls)
        return '\n'.join([
            '/lane T5',
            f'commit: {self.sha[:7]}',
            f'changed: Build {self.args.build} release candidate, branch `{self.branch}`'
            + (f' (waited for {waited})' if waited else ''),
            'run: --plan fast, --plan app and every journey',
            'watch for: anything that would stop the owner using this build on his phone',
            f'not needed: the phone build of {self.sha[:7]} (done by the release cut script, #687)',
        ])

    def candidate_note(self) -> str:
        items = [f'Branch `{self.branch}` at `{self.sha}`.']
        if self.pulls:
            items.append('Waited for: ' + '; '.join(state.describe(self.deadline_text) for state in self.pulls) + '.')
        items += [
            f'Phone build: `{self.build_folder}`. Install it with "Install Spoken Margins on iPhone" on the Desktop.',
            f'Test plan: Files > iCloud Drive > {self.settings.icloud.name} > {self.plan_copy.name}'
            + (' (known issues added).' if self.args.known_issues else '.'),
            f'T5 requested on #{REPORTS_ISSUE}' + (f': {self.report_url}' if self.report_url else '.'),
        ]
        if self.held_job:
            items.append('The rolling phone build is held, so `latest` stays on this candidate. '
                         f'Turn it back on with `{self.enable_command}`')
        return '\n'.join([f'**Build {self.args.build} candidate cut** (release cut script, #687)', '',
                          *[f'{n}. {item}' for n, item in enumerate(items, 1)], '',
                          "Not done by the script, and the owner's call: the version bump, archive, upload, tag "
                          'and `main`.'])

    # ---- the run -------------------------------------------------------------------------------

    def dry_run(self) -> int:
        self.out(f'dry run for Build {self.args.build}; nothing is pushed, built, held, copied or posted')
        self.read_times()
        if self.start_at:
            self.out(f'would wait until {self.start_at:%Y-%m-%d %H:%M}')
        self.fetch()
        self.wait_for_pulls(wait=False)
        for state in self.pulls:
            self.out(f'PR #{state.number}: ' + ('merged' if state.merged else
                     f'not merged yet; would wait until {self.deadline_text}'))
        self.resolve_commit()
        self.out(f'candidate commit: {self.sha[:7]} ({self.git("log", "-1", "--format=%s", self.sha)})')
        self.push_release(dry_run=True)
        self.out(f'would hold {PHONE_JOB} if loaded, then run: {" ".join(self.settings.phone_build)} --commit {self.sha}')
        self.out(f'would add the "Build {self.args.build} candidate" section to the test plan'
                 + (f' with {self.args.known_issues}' if self.args.known_issues else ', with no known issues')
                 + f', and copy it to {self.settings.icloud}')
        self.out(f'would post on #{REPORTS_ISSUE}:\n{self.t5_request()}')
        self.out(f'would post the candidate note on #{STATUS_ISSUE} and send a Mac notification')
        return 0

    def run(self) -> int:
        if self.args.dry_run:
            try:
                return self.dry_run()
            except CutFailed as failure:
                self.out(f'the real run would stop here: {failure}')
                return 1
        self.settings.state_dir.mkdir(parents=True, exist_ok=True)
        with open(self.settings.state_dir / '.cut.lock', 'a+') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.out('another release cut is running; nothing to do')
                return 0
            return self.cut()

    def cut(self) -> int:
        if self.marker.exists() and not self.args.again:
            self.out(f'Build {self.args.build} was already cut or stopped ({self.marker}); '
                     'nothing to do. Run again with --again.')
            return 0
        try:
            self.read_times()
            if self.start_at:
                self.out(f'waiting until {self.start_at:%Y-%m-%d %H:%M}')
                self.wait_until(self.start_at)
            self.fetch()
            self.wait_for_pulls(wait=True)
            self.resolve_commit()
            self.push_release(dry_run=False)
            self.hold_phone_job()
            self.phone_build()
            self.update_plan()
            self.report_url = self.post(REPORTS_ISSUE, self.t5_request())
            self.step(f'asked for T5 on #{REPORTS_ISSUE}')
            self.post(STATUS_ISSUE, self.candidate_note())
            self.step(f'posted the candidate note on #{STATUS_ISSUE}')
        except Exception as failure:  # noqa: BLE001 - any failure stops the cut and is reported
            return self.stopped(failure)
        self.record('cut')
        if self.held_job:
            self.out(f'to turn the rolling phone build back on: {self.enable_command}')
        self.notify(f'Spoken Margins: Build {self.args.build} candidate ready',
                    f'Commit {self.sha[:7]} is on {self.branch} and built for the phone. '
                    f'Test plan: iCloud Drive > {self.settings.icloud.name}.')
        return 0

    def stopped(self, failure: Exception) -> int:
        reason = str(failure) if isinstance(failure, CutFailed) else f'{type(failure).__name__}: {failure}'
        self.out(f'STOPPED: {reason}')
        # Before the build, a stop gives the rolling build back. After it, `latest` is a good candidate, and the
        # job's RunAtLoad would replace it at once, so it stays held.
        if self.held_job and not self.built and self.launchctl('enable', self.job_target) == 0 and self.launchctl(
                'bootstrap', f'gui/{os.getuid()}', str(Path.home() / f'Library/LaunchAgents/{PHONE_JOB}.plist')) == 0:
            self.held_job = False
            self.step('turned the rolling phone-build job back on')
        lines = [f'**Build {self.args.build} cut stopped** (release cut script, #687): {reason}', '']
        if self.done:
            lines += ['Done before it stopped:'] + [f'{n}. {text}' for n, text in enumerate(self.done, 1)] + ['']
        if self.held_job:
            self.out(f'the rolling phone build is still held; to turn it back on: {self.enable_command}')
            lines += [f'The rolling phone build is still held, so `latest` stays on the build above. Turn it back on '
                      f'with `{self.enable_command}`', '']
        # Once release/build-N is pushed, next moves on; a retry must name the same commit or the push refuses.
        pinned = f' --commit {self.sha}' if self.sha and not self.args.commit else ''
        lines.append(f'Nothing was retried. To try again after fixing it: `python3 ops/release/cut_candidate.py '
                     f'--build {self.args.build} --again{pinned}` with the same other options.')
        try:
            self.post(STATUS_ISSUE, '\n'.join(lines))
        except CutFailed as posting:
            self.out(f'and {posting}')
        self.record(f'stopped: {reason}')
        self.notify(f'Spoken Margins: Build {self.args.build} cut stopped', reason[:200])
        return 1

    def record(self, result: str) -> None:
        details = {'build': self.args.build, 'result': result, 'sha': self.sha, 'branch': self.branch,
                   'at': self.clock().isoformat(timespec='seconds'), 'done': self.done,
                   'pulls': {f'#{state.number}': state.included for state in self.pulls}}
        try:
            self.marker.write_text(json.dumps(details, indent=2) + '\n')
        except OSError as error:
            self.out(f'could not write {self.marker}: {error}')


def push_ref(git: Callable[..., str], sha: str, ref: str) -> None:
    """The only push this script makes: a new release/build-N branch. Never main, next or a tag."""
    if not RELEASE_REF.match(ref):
        raise CutFailed(f'refusing to push {ref}: only refs/heads/release/build-<N>')
    git('push', 'origin', f'{sha}:{ref}')


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--build', type=int, required=True, help='the build number, e.g. 30')
    parser.add_argument('--commit', help="cut this commit instead of origin/next's tip")
    parser.add_argument('--at', help='start at this time: HH:MM (its next occurrence) or YYYY-MM-DDTHH:MM')
    parser.add_argument('--wait-for', action='append', metavar='PR',
                        help='PRs to wait for before cutting, e.g. 604 or 604,608 (repeatable)')
    parser.add_argument('--deadline', help='stop waiting for PRs at this time (HH:MM or YYYY-MM-DDTHH:MM)')
    parser.add_argument('--known-issues', metavar='FILE', help='a Markdown file appended to the test plan')
    parser.add_argument('--again', action='store_true', help='run even though this build was cut or stopped before')
    parser.add_argument('--dry-run', action='store_true', help='print the plan; push, build, hold and post nothing')
    args = parser.parse_args(argv)
    if args.build <= 0:
        parser.error('--build must be a positive number')
    if args.deadline and not args.wait_for:
        parser.error('--deadline needs --wait-for')
    if args.wait_for and not args.deadline:
        parser.error('--wait-for needs --deadline, so the cut never waits forever')
    try:
        pr_numbers(args.wait_for or [])
        for value in (args.at, args.deadline):
            if value:
                parse_when(value, dt.datetime.now())
    except ValueError as error:
        parser.error(str(error))
    if args.known_issues and not Path(args.known_issues).is_file():
        parser.error(f'--known-issues: no such file: {args.known_issues}')
    return args


def main(argv: List[str]) -> int:
    return Cut(parse_args(argv), Settings.from_env()).run()


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
