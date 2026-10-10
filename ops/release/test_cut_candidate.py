"""ops/release/cut_candidate.py (#687).

Each test builds a scratch origin (a bare repo with `next`) and a clone of it, and runs the cut
in-process against fake `gh`, phone-build, launchctl and notification commands that log every call.
The clock and sleep are injected, so waiting for a time or for PRs takes no real time. Nothing
reaches GitHub, launchd or a phone.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cut_candidate  # noqa: E402


class ReleaseUploadConfigurationTests(unittest.TestCase):
    def test_normal_upload_remains_eligible_for_external_review(self):
        path = Path(__file__).resolve().parents[2] / 'scripts' / 'TestFlightUploadOptions.plist'
        with path.open('rb') as source:
            options = plistlib.load(source)
        self.assertEqual(options['method'], 'app-store-connect')
        self.assertFalse(options.get('testFlightInternalTestingOnly', False),
                         'Internal tester assignment must not prevent later external review')

# Answers `gh api repos/.../pulls/N` from FAKE_PULLS (a JSON file the test may change while the cut
# waits) and records comments, with the body file's text, in FAKE_LOG.
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
entry = {"tool": "gh", "args": args}
for index, arg in enumerate(args):
    if arg.startswith("body=@"):
        entry["body"] = open(arg[6:]).read()
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\n")
path = args[1] if len(args) > 1 and args[0] == "api" and not args[1].startswith("-") else ""
if "-X" in args and args[args.index("-X") + 1] == "POST":
    if os.environ.get("FAKE_GH_POST_FAIL"):
        sys.exit(1)
    number = re.search(r"issues/(\d+)/comments", " ".join(args)).group(1)
    print(f"https://github.com/example/issues/{number}#issuecomment-1")
    sys.exit(0)
match = re.match(r"repos/[^/]+/[^/]+/pulls/(\d+)$", path)
if match and os.path.exists(os.environ["FAKE_PULLS"] + ".fail"):
    sys.exit(1)
if match:
    pulls = json.load(open(os.environ["FAKE_PULLS"]))
    print(json.dumps(pulls.get(match.group(1), {"merged_at": None, "merge_commit_sha": None})))
    sys.exit(0)
sys.exit(97)
'''

# Makes a build folder the way scripts/phone-build does: <stamp>-<sha7>/ with build.json and
# test-plan.md, and `latest` pointing at it. FAKE_BUILD_EXIT fails it; FAKE_BUILD_SHA names another commit.
FAKE_PHONE_BUILD = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "phone-build", "args": args}) + "\n")
code = int(os.environ.get("FAKE_BUILD_EXIT", "0"))
if code:
    sys.exit(code)
sha = os.environ.get("FAKE_BUILD_SHA") or args[args.index("--commit") + 1]
phone = Path(os.environ["SM_PHONE_DIR"])
folder = phone / f"20261004-210500-{sha[:7]}"
folder.mkdir(parents=True, exist_ok=True)
(folder / "build.json").write_text(json.dumps({"sha": sha, "bundle_version": "29"}))
(folder / "test-plan.md").write_text(f"# Phone build `{sha[:7]}`: what to try\n\n1. **Try the thing**\n")
link = phone / "latest"
if link.is_symlink():
    link.unlink()
os.symlink(folder.name, link)
'''

# `print` succeeds while FAKE_LOADED exists; bootout removes it, bootstrap creates it. Like launchd,
# bootstrap refuses a disabled job (FAKE_LOADED.disabled, made by disable, removed by enable).
FAKE_LAUNCHCTL = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "launchctl", "args": args}) + "\n")
loaded = os.environ["FAKE_LOADED"]
if args[0] == "print":
    sys.exit(0 if os.path.exists(loaded) else 113)
if args[0] == "bootout":
    os.remove(loaded)
if args[0] == "disable":
    open(loaded + ".disabled", "w").close()
if args[0] == "enable" and os.path.exists(loaded + ".disabled"):
    os.remove(loaded + ".disabled")
if args[0] == "bootstrap":
    if os.path.exists(loaded + ".disabled"):
        sys.exit(5)
    open(loaded, "w").close()
'''

FAKE_NOTIFY = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "notify", "args": sys.argv[1:]}) + "\n")
'''

START = dt.datetime(2026, 10, 4, 18, 0)


def sh(*args, cwd):
    return subprocess.run(args, cwd=str(cwd), check=True, capture_output=True, text=True).stdout.strip()


class FakeTime:
    """A clock that only moves when the cut sleeps. `on_sleep` runs before each move."""

    def __init__(self, start=START):
        self.now = start
        self.slept = 0.0
        self.on_sleep = None

    def clock(self):
        return self.now

    def sleep(self, seconds):
        if self.on_sleep:
            self.on_sleep(self)
        self.slept += seconds
        self.now += dt.timedelta(seconds=seconds)


class CutTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='cut-candidate-'))
        self.addCleanup(subprocess.run, ['rm', '-rf', str(self.tmp)])
        self.origin = self.tmp / 'origin.git'
        self.work = self.tmp / 'work'      # the test's own checkout, used to move origin's next
        self.repo = self.tmp / 'repo'      # the checkout the cut runs in
        sh('git', 'init', '--bare', '-q', '-b', 'main', str(self.origin), cwd=self.tmp)
        sh('git', 'clone', '-q', str(self.origin), str(self.work), cwd=self.tmp)
        for key, value in (('user.email', 'test@example.com'), ('user.name', 'Test')):
            sh('git', 'config', key, value, cwd=self.work)
        self.commit('first')
        sh('git', 'push', '-q', 'origin', 'HEAD:refs/heads/main', 'HEAD:refs/heads/next', cwd=self.work)
        sh('git', 'clone', '-q', str(self.origin), str(self.repo), cwd=self.tmp)
        self.main_before = self.remote('main')

        tools = self.tmp / 'tools'
        tools.mkdir()
        for name, text in (('gh', FAKE_GH), ('phone-build', FAKE_PHONE_BUILD),
                           ('launchctl', FAKE_LAUNCHCTL), ('notify', FAKE_NOTIFY)):
            (tools / name).write_text(text)
            (tools / name).chmod(0o755)
        self.log = self.tmp / 'calls.jsonl'
        self.pulls = self.tmp / 'pulls.json'
        self.pulls.write_text('{}')
        self.loaded = self.tmp / 'phone-job-loaded'
        self.loaded.touch()
        self.phone = self.tmp / 'SpokenMargins-phone'
        self.icloud = self.tmp / 'iCloud' / 'Spoken Margins test plans'
        self.env = {'FAKE_LOG': str(self.log), 'FAKE_PULLS': str(self.pulls), 'FAKE_LOADED': str(self.loaded),
                    'SM_PHONE_DIR': str(self.phone)}
        self.saved_env = {key: os.environ.get(key) for key in
                          (*self.env, 'FAKE_BUILD_EXIT', 'FAKE_BUILD_SHA', 'FAKE_GH_POST_FAIL')}
        os.environ.update(self.env)
        self.addCleanup(self.restore_env)
        self.settings = cut_candidate.Settings(
            repo=self.repo, gh=[str(tools / 'gh')], phone_build=[str(tools / 'phone-build')],
            launchctl=[str(tools / 'launchctl')], notify=str(tools / 'notify'),
            state_dir=self.tmp / 'state', phone_dir=self.phone, icloud=self.icloud,
            pr_poll_seconds=120, phone_lock_wait_seconds=600)
        self.time = FakeTime()
        self.output = []

    def restore_env(self):
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def commit(self, message):
        (self.work / 'file.txt').write_text(message + '\n')
        sh('git', 'add', 'file.txt', cwd=self.work)
        sh('git', 'commit', '-q', '-m', message, cwd=self.work)
        return sh('git', 'rev-parse', 'HEAD', cwd=self.work)

    def merge_into_next(self, message):
        sha = self.commit(message)
        sh('git', 'push', '-q', 'origin', 'HEAD:refs/heads/next', cwd=self.work)
        return sha

    def remote(self, branch):
        line = sh('git', 'ls-remote', str(self.origin), f'refs/heads/{branch}', cwd=self.tmp)
        return line.split()[0] if line else ''

    def set_pull(self, number, merge_sha=None):
        pulls = json.loads(self.pulls.read_text())
        pulls[str(number)] = {'merged_at': '2026-10-04T21:10:00Z' if merge_sha else None,
                              'merge_commit_sha': merge_sha}
        self.pulls.write_text(json.dumps(pulls))

    def calls(self, tool=None):
        if not self.log.exists():
            return []
        entries = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [entry for entry in entries if tool is None or entry['tool'] == tool]

    def posts(self):
        return {int(entry['args'][3].split('/')[4]): entry['body'] for entry in self.calls('gh')
                if '-X' in entry['args']}

    def cut(self, *argv):
        args = cut_candidate.parse_args(['--build', '30', *argv])
        return cut_candidate.Cut(args, self.settings, clock=self.time.clock, sleep=self.time.sleep,
                                 out=self.output.append).run()


class FullCutTests(CutTestCase):
    def test_cut_pushes_builds_sends_the_plan_posts_and_holds(self):
        sha = self.remote('next')
        known = self.tmp / 'known.md'
        known.write_text('- #651 Margin voice can keep playing after Close.\n')

        self.assertEqual(self.cut('--known-issues', str(known)), 0, self.output)

        self.assertEqual(self.remote('release/build-30'), sha)
        self.assertEqual(self.remote('main'), self.main_before)
        self.assertEqual(sh('git', 'ls-remote', '--tags', str(self.origin), cwd=self.tmp), '')
        self.assertEqual(self.calls('phone-build')[0]['args'], ['--commit', sha])
        self.assertFalse(self.loaded.exists(), 'the rolling phone-build job should be held')
        self.assertEqual([entry['args'][0] for entry in self.calls('launchctl')], ['print', 'bootout', 'disable'],
                         'disabled as well, so a restart does not load it again')

        plan = (self.icloud / f'Build 30 test plan {sha[:7]}.md').read_text()
        self.assertIn('## Build 30 candidate', plan)
        self.assertIn('#651 Margin voice', plan)
        self.assertIn('### Known issues', plan)
        self.assertEqual(plan, (self.phone / 'latest' / 'test-plan.md').read_text())

        posts = self.posts()
        self.assertEqual(list(posts), [184, 337], 'T5 request first, then the candidate note')
        self.assertTrue(posts[184].startswith(f'/lane T5\ncommit: {sha[:7]}\n'), posts[184])
        self.assertIn(f'`release/build-30` at `{sha}`', posts[337])
        self.assertIn('launchctl enable gui/$(id -u)/com.spokenmargins.phone-build && '
                      'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.phone-build.plist',
                      posts[337])
        self.assertIn('issuecomment-1', posts[337])
        self.assertIn('Build 30 candidate ready', ' '.join(self.calls('notify')[-1]['args']))
        marker = json.loads((self.tmp / 'state' / 'build-30.json').read_text())
        self.assertEqual((marker['result'], marker['sha']), ('cut', sha))

    def test_existing_branch_at_the_same_commit_is_reused(self):
        sha = self.remote('next')
        sh('git', 'push', '-q', 'origin', f'{sha}:refs/heads/release/build-30', cwd=self.work)
        self.assertEqual(self.cut(), 0, self.output)
        self.assertEqual(self.remote('release/build-30'), sha)
        self.assertIn('No known issues were given', (self.phone / 'latest' / 'test-plan.md').read_text())

    def test_a_job_that_is_not_loaded_is_left_alone(self):
        self.loaded.unlink()
        self.assertEqual(self.cut(), 0, self.output)
        self.assertEqual([entry['args'][0] for entry in self.calls('launchctl')], ['print'])
        self.assertNotIn('Turn it back on', self.posts()[337])

    def test_commit_option_cuts_that_commit(self):
        older = self.remote('next')
        self.merge_into_next('newer')
        self.assertEqual(self.cut('--commit', older), 0, self.output)
        self.assertEqual(self.remote('release/build-30'), older)


class WaitingTests(CutTestCase):
    def test_at_waits_for_the_time_before_doing_anything(self):
        pushed_at = []

        def watch(fake):
            if self.remote('release/build-30'):
                pushed_at.append(fake.now)
        self.time.on_sleep = watch

        self.assertEqual(self.cut('--at', '21:00'), 0, self.output)
        self.assertEqual(pushed_at, [], 'nothing may be pushed while waiting')
        self.assertGreaterEqual(self.time.now, START.replace(hour=21))
        self.assertEqual(self.time.slept, 3 * 3600)

    def test_waits_for_prs_then_records_which_are_in(self):
        self.set_pull(604)
        self.set_pull(608)
        merged = {}

        def merge_604_on_the_second_poll(fake):
            if fake.slept >= 120 and not merged:
                merged['sha'] = self.merge_into_next('fix Following tab (#604)')
                self.set_pull(604, merged['sha'])
        self.time.on_sleep = merge_604_on_the_second_poll

        self.assertEqual(self.cut('--wait-for', '604,608', '--deadline', '18:30'), 0, self.output)

        self.assertEqual(self.remote('release/build-30'), merged['sha'], 'the cut takes next after #604 merged')
        self.assertEqual(self.time.now, START.replace(minute=30), 'it waits until the deadline for #608')
        note = self.posts()[337]
        self.assertIn('#604 in; #608 not merged by 2026-10-04 18:30, so not in', note)
        self.assertIn('#604 in', (self.phone / 'latest' / 'test-plan.md').read_text())

    def test_stops_waiting_once_every_pr_merged(self):
        sha = self.merge_into_next('already merged (#604)')
        self.set_pull(604, sha)
        self.assertEqual(self.cut('--wait-for', '604', '--deadline', '22:30'), 0, self.output)
        self.assertEqual(self.time.slept, 0)

    def test_pr_merged_after_the_chosen_commit_is_not_in(self):
        older = self.remote('next')
        self.set_pull(604, self.merge_into_next('later (#604)'))
        self.assertEqual(self.cut('--commit', older, '--wait-for', '604', '--deadline', '22:30'), 0, self.output)
        self.assertIn('#604 merged after this commit, so not in', self.posts()[337])


class StopTests(CutTestCase):
    def assert_stopped(self, text):
        posts = self.posts()
        self.assertIn(337, posts)
        self.assertIn('**Build 30 cut stopped**', posts[337])
        self.assertIn(text, posts[337])
        self.assertNotIn(184, posts, 'no T5 request for a cut that stopped')
        self.assertIn('cut stopped', ' '.join(self.calls('notify')[-1]['args']))
        marker = json.loads((self.tmp / 'state' / 'build-30.json').read_text())
        self.assertTrue(marker['result'].startswith('stopped:'), marker)
        return posts[337]

    def test_branch_at_another_commit_stops_before_building(self):
        older = self.remote('next')
        sh('git', 'push', '-q', 'origin', f'{older}:refs/heads/release/build-30', cwd=self.work)
        self.merge_into_next('newer')

        self.assertEqual(self.cut(), 1)

        self.assert_stopped(f'already exists at {older[:7]}')
        self.assertEqual(self.remote('release/build-30'), older)
        self.assertEqual(self.calls('phone-build'), [])
        self.assertTrue(self.loaded.exists(), 'the phone-build job was never held')

    def test_phone_build_failure_stops_and_turns_the_job_back_on(self):
        os.environ['FAKE_BUILD_EXIT'] = '1'
        self.assertEqual(self.cut(), 1)
        note = self.assert_stopped('scripts/phone-build failed (exit 1)')
        self.assertIn('pushed release/build-30', note, 'the note lists what was done before the stop')
        self.assertEqual([entry['args'][0] for entry in self.calls('launchctl')],
                         ['print', 'bootout', 'disable', 'enable', 'bootstrap'])
        self.assertTrue(self.loaded.exists())
        self.assertFalse(self.icloud.exists())

    def test_retry_after_a_stop_past_the_push_names_the_same_commit(self):
        sha = self.remote('next')
        os.environ['FAKE_BUILD_EXIT'] = '75'
        self.assertEqual(self.cut(), 1)
        note = self.assert_stopped('memory or disk too low')
        self.assertIn(f'--build 30 --again --commit {sha}`', note)
        del os.environ['FAKE_BUILD_EXIT']
        self.merge_into_next('next moved on overnight')
        self.assertEqual(self.cut('--again', '--commit', sha), 0, self.output)
        self.assertEqual(self.remote('release/build-30'), sha)

    def test_a_stop_after_the_build_keeps_the_job_held(self):
        self.icloud.parent.mkdir(parents=True)
        self.icloud.write_text('a file where the folder should be')
        self.assertEqual(self.cut(), 1)
        note = self.assert_stopped('could not copy the test plan to iCloud Drive')
        self.assertEqual([entry['args'][0] for entry in self.calls('launchctl')], ['print', 'bootout', 'disable'],
                         'turning the job back on would replace the good candidate in `latest` at once')
        self.assertIn('still held', note)

    def test_build_of_another_commit_stops(self):
        os.environ['FAKE_BUILD_SHA'] = 'f' * 40
        self.assertEqual(self.cut(), 1)
        self.assert_stopped('names fffffff, not')

    def test_failed_post_stops_and_still_notifies(self):
        os.environ['FAKE_GH_POST_FAIL'] = '1'
        self.assertEqual(self.cut(), 1)
        self.assertIn('could not comment on #184', ' '.join(self.output))
        self.assertIn('cut stopped', ' '.join(self.calls('notify')[-1]['args']))

    def test_second_run_does_nothing_without_again(self):
        self.assertEqual(self.cut(), 0)
        calls = len(self.calls())
        self.assertEqual(self.cut(), 0)
        self.assertEqual(len(self.calls()), calls, 'a second run must not build or post again')
        self.assertEqual(self.cut('--again'), 0)
        self.assertGreater(len(self.calls('phone-build')), 1)
        plan = (self.phone / 'latest' / 'test-plan.md').read_text()
        self.assertEqual(plan.count('## Build 30 candidate'), 1)


class WaitFailureTests(CutTestCase):
    def test_one_failed_pr_read_does_not_end_the_wait(self):
        self.set_pull(604)
        failing = Path(str(self.pulls) + '.fail')
        failing.touch()
        merged = {}

        def recover_then_merge(fake):
            if failing.exists():
                failing.unlink()
            elif not merged:
                merged['sha'] = self.merge_into_next('fix (#604)')
                self.set_pull(604, merged['sha'])
        self.time.on_sleep = recover_then_merge

        self.assertEqual(self.cut('--wait-for', '604', '--deadline', '19:00'), 0, self.output)
        self.assertIn('could not read PR #604', '\n'.join(self.output))
        self.assertIn('#604 in', self.posts()[337])

    def test_a_failed_read_at_the_deadline_stops(self):
        self.set_pull(604)
        Path(str(self.pulls) + '.fail').touch()
        self.assertEqual(self.cut('--wait-for', '604', '--deadline', '18:10'), 1)
        self.assertEqual(self.time.now, START.replace(minute=10))
        self.assertIn('could not read PR #604', self.posts()[337])
        self.assertEqual(self.calls('phone-build'), [])

    def test_deadline_is_read_from_the_start_time_not_after_a_late_wake(self):
        self.set_pull(604)

        def mac_sleeps_past_both_times(fake):
            if fake.now < START.replace(hour=23):
                fake.now = START.replace(hour=23)
        self.time.on_sleep = mac_sleeps_past_both_times

        self.assertEqual(self.cut('--at', '21:00', '--wait-for', '604', '--deadline', '22:30'), 0, self.output)
        self.assertLess(self.time.now, START.replace(hour=23, minute=5), 'it must not wait until tomorrow 22:30')
        self.assertIn('#604 not merged by 2026-10-04 22:30', self.posts()[337])


class DryRunTests(CutTestCase):
    def test_dry_run_changes_nothing(self):
        self.set_pull(604)
        self.assertEqual(self.cut('--dry-run', '--at', '21:00', '--wait-for', '604', '--deadline', '22:30'), 0)
        text = '\n'.join(self.output)
        self.assertIn('would wait until 2026-10-04 21:00', text)
        self.assertIn('PR #604: not merged yet', text)
        self.assertIn('would push release/build-30', text)
        self.assertIn('/lane T5', text)
        self.assertEqual(self.remote('release/build-30'), '')
        self.assertEqual(self.posts(), {})
        self.assertEqual(self.calls('phone-build') + self.calls('launchctl') + self.calls('notify'), [])
        self.assertTrue(self.loaded.exists())
        self.assertFalse((self.tmp / 'state').exists())
        self.assertEqual(self.time.slept, 0)

    def test_dry_run_reports_a_branch_conflict(self):
        older = self.remote('next')
        sh('git', 'push', '-q', 'origin', f'{older}:refs/heads/release/build-30', cwd=self.work)
        self.merge_into_next('newer')
        self.assertEqual(self.cut('--dry-run'), 1)
        self.assertIn('the real run would stop here', '\n'.join(self.output))
        self.assertEqual(self.posts(), {})


class PieceTests(unittest.TestCase):
    def test_push_refuses_anything_but_a_release_branch(self):
        pushed = []
        for ref in ('refs/heads/main', 'refs/heads/next', 'refs/tags/testflight/0.1-build-30',
                    'refs/heads/release/build-30x'):
            with self.assertRaises(cut_candidate.CutFailed):
                cut_candidate.push_ref(lambda *args: pushed.append(args), 'a' * 40, ref)
        self.assertEqual(pushed, [])
        cut_candidate.push_ref(lambda *args: pushed.append(args), 'a' * 40, 'refs/heads/release/build-30')
        self.assertEqual(pushed, [('push', 'origin', 'a' * 40 + ':refs/heads/release/build-30')])

    def test_parse_when(self):
        now = dt.datetime(2026, 10, 4, 18, 0)
        self.assertEqual(cut_candidate.parse_when('21:00', now), dt.datetime(2026, 10, 4, 21, 0))
        self.assertEqual(cut_candidate.parse_when('06:30', now), dt.datetime(2026, 10, 5, 6, 30))
        self.assertEqual(cut_candidate.parse_when('18:00', now), dt.datetime(2026, 10, 5, 18, 0))
        self.assertEqual(cut_candidate.parse_when('2026-10-06T07:15', now), dt.datetime(2026, 10, 6, 7, 15))
        for bad in ('25:00', 'tonight', '9pm'):
            with self.assertRaises(ValueError):
                cut_candidate.parse_when(bad, now)

    def test_pr_numbers(self):
        self.assertEqual(cut_candidate.pr_numbers(['604,#608', '604 610']), [604, 608, 610])

    def test_arguments_are_checked_before_anything_runs(self):
        for argv in (['--build', '30', '--wait-for', '604'], ['--build', '30', '--deadline', '22:30'],
                     ['--build', '30', '--known-issues', '/no/such/file.md'], ['--build', '0'],
                     ['--build', '30', '--at', 'tonight']):
            with self.assertRaises(SystemExit, msg=argv):
                with open(os.devnull, 'w') as quiet:
                    stderr, sys.stderr = sys.stderr, quiet
                    try:
                        cut_candidate.parse_args(argv)
                    finally:
                        sys.stderr = stderr

    def test_settings_default_to_the_real_tools(self):
        settings = cut_candidate.Settings.from_env({})
        self.assertEqual(settings.gh, ['gh'])
        self.assertEqual(settings.launchctl, ['launchctl'])
        self.assertEqual(settings.phone_build[-1], str(Path(cut_candidate.__file__).resolve().parents[2]
                                                       / 'scripts/phone-build'))
        self.assertTrue(str(settings.icloud).endswith('com~apple~CloudDocs/Spoken Margins test plans'))


if __name__ == '__main__':
    unittest.main()
