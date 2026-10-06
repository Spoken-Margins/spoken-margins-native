"""scripts/phone-build and scripts/install-phone-build.command (#384).

The installer runs against a fake `xcrun` on PATH, so no test can reach a real phone: the fake
answers `devicectl list devices` from FAKE_DEVICES and records every other call. The build runs
against a scratch repo and a fake xcodebuild (SM_LANE_XCODEBUILD) that makes an ad-hoc signed app.
"""
import datetime
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock

SCRIPTS = Path(__file__).resolve().parents[1]
INSTALLER = SCRIPTS / 'install-phone-build.command'


def load_phone_build():
    loader = importlib.machinery.SourceFileLoader('phone_build', str(SCRIPTS / 'phone-build'))
    spec = importlib.util.spec_from_loader('phone_build', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


FAKE_XCRUN = r'''#!/usr/bin/python3
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]
if args[:3] == ["devicectl", "list", "devices"]:
    out = args[args.index("--json-output") + 1]
    with open(out, "w") as handle:
        json.dump({"result": {"devices": json.loads(os.environ.get("FAKE_DEVICES", "[]"))}}, handle)
    sys.exit(0)
if args[:4] == ["devicectl", "device", "install", "app"]:
    print(os.environ.get("FAKE_INSTALL_OUTPUT", "App installed"))
    sys.exit(int(os.environ.get("FAKE_INSTALL_EXIT", "0")))
sys.exit(97)  # anything else (uninstall, launch, ...) is a test failure
'''

FAKE_OPEN = '''#!/bin/sh
echo "open $*" >> "$FAKE_LOG"
'''


def iphone(identifier, name='Cole iPhone', transport='wired', pairing='paired', kind='iPhone'):
    return {'identifier': identifier, 'deviceProperties': {'name': name},
            'hardwareProperties': {'platform': 'iOS', 'deviceType': kind},
            'connectionProperties': {'transportType': transport, 'pairingState': pairing}}


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.bin, self.phone, self.log = self.tmp / 'bin', self.tmp / 'phone', self.tmp / 'calls.log'
        self.bin.mkdir()
        for name, body in (('xcrun', FAKE_XCRUN), ('open', FAKE_OPEN)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.sha = 'ab' * 20

    def make_build(self):
        folder = self.phone / f'20260930-120000-{self.sha[:7]}'
        (folder / 'SpokenMarginsApp.app').mkdir(parents=True)
        (folder / 'build.json').write_text(json.dumps({'sha': self.sha, 'built_at': '2026-09-30T12:00:00'}))
        (folder / 'test-plan.md').write_text('# plan\n')
        os.symlink(folder.name, self.phone / 'latest')
        return folder

    def run_installer(self, devices, answer='', **extra):
        env = {**os.environ, 'PATH': f'{self.bin}:/usr/bin:/bin', 'SM_PHONE_DIR': str(self.phone),
               'FAKE_LOG': str(self.log), 'FAKE_DEVICES': json.dumps(devices),
               'SM_PHONE_ICLOUD': str(self.tmp / 'icloud'), **extra}
        done = subprocess.run(['/bin/zsh', str(INSTALLER)], env=env, input=answer, capture_output=True, text=True,
                              timeout=60)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return done, calls

    def test_installs_latest_over_the_app_and_records_it(self):
        folder = self.make_build()
        done, calls = self.run_installer([iphone('PHONE-1'), iphone('WATCH', kind='Watch'),
                                          iphone('WIFI', transport='localNetwork')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        installs = [c for c in calls if 'install app' in c]
        self.assertEqual(installs, [f'devicectl device install app --device PHONE-1 '
                                    f'{folder.resolve()}/SpokenMarginsApp.app'])
        self.assertFalse(any('uninstall' in c for c in calls))
        self.assertEqual((self.phone / 'installed.txt').read_text().split()[0], self.sha)
        self.assertIn(f'open {folder.resolve()}/test-plan.md', calls)

    def test_copies_the_test_plan_to_icloud_drive_for_the_phone(self):
        folder = self.make_build()
        (folder / 'test-plan.md').write_text('# Phone build: what to try\n1. Check the Following tab\n')
        icloud = self.tmp / 'icloud'
        icloud.mkdir()
        for old in ('1111111', '2222222', '3333333', '4444444', '5555555'):
            (icloud / f'Test plan {old}.md').write_text('old')
        (icloud / 'my own notes.md').write_text('keep me')
        done, _ = self.run_installer([iphone('PHONE-1')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        copy = icloud / f'Test plan {self.sha[:7]}.md'
        self.assertEqual(copy.read_text(), '# Phone build: what to try\n1. Check the Following tab\n')
        self.assertIn('iCloud Drive', done.stdout)
        plans = sorted(p.name for p in icloud.glob('Test plan *.md'))
        self.assertEqual(len(plans), 5)                  # the newest five, this one included
        self.assertNotIn('Test plan 1111111.md', plans)  # the oldest copy goes
        self.assertTrue((icloud / 'my own notes.md').exists())

    def test_no_icloud_drive_still_installs(self):
        self.make_build()
        done, _ = self.run_installer([iphone('PHONE-1')], SM_PHONE_ICLOUD=str(self.tmp / 'missing' / 'x'))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual((self.phone / 'installed.txt').read_text().split()[0], self.sha)
        self.assertIn("couldn't copy the test plan", done.stdout)

    def test_no_phone_plugged_in(self):
        self.make_build()
        done, calls = self.run_installer([iphone('WIFI', transport='localNetwork')])
        self.assertEqual(done.returncode, 1)
        self.assertIn('No iPhone is plugged in', done.stdout)
        self.assertFalse(any('install app' in c for c in calls))
        self.assertFalse((self.phone / 'installed.txt').exists())

    def test_two_phones_asks_to_unplug_one(self):
        self.make_build()
        done, calls = self.run_installer([iphone('A', name='First'), iphone('B', name='Second')])
        self.assertEqual(done.returncode, 1)
        self.assertIn('More than one iPhone', done.stdout)
        self.assertIn('First', done.stdout)
        self.assertFalse(any('install app' in c for c in calls))

    def test_unpaired_phone(self):
        self.make_build()
        done, calls = self.run_installer([iphone('A', pairing='unpaired')])
        self.assertEqual(done.returncode, 1)
        self.assertIn('tap Trust', done.stdout)
        self.assertFalse(any('install app' in c for c in calls))

    def test_failed_install_keeps_the_record(self):
        self.make_build()
        (self.phone / 'installed.txt').write_text('cd' * 20 + '\n')
        done, _ = self.run_installer([iphone('A')], FAKE_INSTALL_EXIT='1',
                                     FAKE_INSTALL_OUTPUT='ERROR: Developer Mode is disabled')
        self.assertEqual(done.returncode, 1)
        self.assertIn('Turn on Developer Mode', done.stdout)
        self.assertEqual((self.phone / 'installed.txt').read_text().split()[0], 'cd' * 20)

    def test_no_build_yet(self):
        done, calls = self.run_installer([iphone('A')])
        self.assertEqual(done.returncode, 1)
        self.assertIn('no phone build yet', done.stdout)
        self.assertEqual(calls, [])

    def test_names_the_installed_build_before_installing_a_newer_one(self):
        self.make_build()
        (self.phone / 'installed.txt').write_text(f'{"cd" * 20} 2026-09-29T09:05:29 Cole iPhone\n')
        done, calls = self.run_installer([iphone('A')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('Your phone has commit cdcdcdc', done.stdout)
        self.assertIn('This build is newer', done.stdout)
        self.assertTrue(any('install app' in c for c in calls))

    def test_already_installed_says_so_and_changes_nothing(self):
        self.make_build()
        record = f'{self.sha} 2026-09-30T09:05:29 Slaw’s iPhone\n'
        (self.phone / 'installed.txt').write_text(record)
        done, calls = self.run_installer([iphone('A')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(f'Slaw’s iPhone already has this build: commit {self.sha[:7]}', done.stdout)
        self.assertIn('No newer build yet', done.stdout)
        self.assertIn('type R', done.stdout)
        self.assertEqual(calls, [])  # not even a device listing: the phone needn't be plugged in
        self.assertEqual((self.phone / 'installed.txt').read_text(), record)

    def test_already_installed_reinstalls_on_r(self):
        folder = self.make_build()
        (self.phone / 'installed.txt').write_text(f'{self.sha} 2026-09-30T09:05:29 Cole iPhone\n')
        done, calls = self.run_installer([iphone('A')], answer='r\n')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(f'devicectl device install app --device A {folder.resolve()}/SpokenMarginsApp.app', calls)

    def test_already_installed_mentions_a_newer_build_in_progress(self):
        # The installer's clock is pinned: started three minutes before "now" was "today" except in the three
        # minutes after midnight, when it is yesterday's date and the installer rightly says so (#841).
        self.make_build()
        (self.phone / 'installed.txt').write_text(f'{self.sha} 2026-09-30T09:05:29 Cole iPhone\n')
        for now, words in (('2026-10-05T12:00:00', 'today at 11:57'), ('2026-10-05T00:01:00', 'yesterday at 23:58')):
            with self.subTest(now=now):
                work = self.phone / '.work'
                shutil.rmtree(work, ignore_errors=True)
                started = datetime.datetime.fromisoformat(now) - datetime.timedelta(minutes=3)
                (work / f'{started:%Y%m%d-%H%M%S}-1234567').mkdir(parents=True)
                (work / '20200101-000000-7654321').mkdir()  # a leftover, not a running build
                done, calls = self.run_installer([iphone('A')], SM_PHONE_NOW=now)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn(f'being made right now: commit 1234567, started {words}', done.stdout)
                self.assertNotIn('7654321', done.stdout)
                self.assertEqual(calls, [])

    def test_already_installed_mentions_a_failed_newer_attempt(self):
        self.make_build()
        (self.phone / 'installed.txt').write_text(f'{self.sha} 2026-09-30T09:05:29 Cole iPhone\n')
        (self.phone / 'last-attempt.json').write_text(json.dumps(
            {'sha': 'ef' * 20, 'result': 'failed: host tests (--plan fast) failed', 'at': '2026-09-30T11:00:00'}))
        done, _ = self.run_installer([iphone('A')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('commit efefefe, failed', done.stdout)
        self.assertIn('host tests (--plan fast) failed.', done.stdout)


FAKE_XCODEBUILD = r'''#!/usr/bin/python3
import os, plistlib, shutil, subprocess, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if os.environ.get("FAKE_FAIL"):
    print(os.environ["FAKE_FAIL"])
    sys.exit(65)
derived = args[args.index("-derivedDataPath") + 1]
if "build-for-testing" in args:
    sys.exit(0)
commit = next(a.split("=", 1)[1] for a in args if a.startswith("SM_BUILD_COMMIT="))
app = os.path.join(derived, "Build/Products/Release-iphoneos/SpokenMarginsApp.app")
os.makedirs(app)
shutil.copy("/usr/bin/true", os.path.join(app, "SpokenMarginsApp"))
info = {"CFBundleExecutable": "SpokenMarginsApp", "CFBundleIdentifier": "com.example.fake",
        "CFBundleVersion": "29", "CFBundlePackageType": "APPL"}
if os.environ.get("FAKE_PLIST_KEY"):
    info["SMBuildCommit"] = commit
with open(os.path.join(app, "Info.plist"), "wb") as handle:
    plistlib.dump(info, handle)
open(os.path.join(app, "embedded.mobileprovision"), "w").write("profile")
subprocess.check_call(["codesign", "-s", "-", "--force", app], stderr=subprocess.DEVNULL)
'''

FAKE_NOTIFY = '''#!/bin/sh
echo "notify $*" >> "$FAKE_LOG"
'''

FAKE_GH = r'''#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write("gh " + " ".join(args) + "\n")
tip = os.environ["FAKE_TIP"]
if args[:1] == ["api"] and args[1].endswith("/issues/12/comments"):
    print("**Merge check (triage desk) on `1234567`: PASS.**\n- Tested the merge commit `%s`.\n"
          "- Ran: --plan fast and both builds.\n- Pushing `%s` to next now." % (tip[:7], tip[:7]))
elif args[:1] == ["api"] and args[1].endswith("/issues/184/comments"):
    for body in ("```text\nLane report integration-%s — PASS\nran: --plan app (pass: 564 of 564 tests)\n```" % tip[:7],
                 "```text\nLane report journeys-%s — PASS\nran: J4 (pass)\n```" % tip[:7]):
        print(json.dumps(body))
elif args[:2] == ["api", "graphql"]:
    def pr(n, title, files, issue):
        return {"number": n, "title": title, "url": "https://example/pr/%d" % n, "mergedAt": "", "body": "",
                "labels": {"nodes": []}, "files": {"nodes": [{"path": p} for p in files]},
                "closingIssuesReferences": {"nodes": [issue] if issue else []}}
    phone_bug = {"number": 90, "title": "Voice stops", "url": "https://example/issue/90",
                 "body": "**Owner check:** play an article for a minute and hear it keep going.",
                 "labels": {"nodes": [{"name": "found-on-phone"}]}}
    feature = {"number": 91, "title": "Library wording", "url": "https://example/issue/91",
               "body": "**Owner check:** open the Library and read the rows.", "labels": {"nodes": []}}
    print(json.dumps({"data": {"repository": {
        "p12": pr(12, "Library rows say what an item is", ["App/SpokenMarginsApp/Sources/X.swift"], feature),
        "p11": pr(11, "Lane: retry evidence", ["scripts/lane-runner.py"], None),
        "p10": pr(10, "Keep the voice playing", ["Packages/SessionKit/Sources/SessionKit/Y.swift"], phone_bug),
    }}}))
else:
    sys.exit(1)
'''


class PhoneBuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo, self.phone, self.bin, self.log = (self.tmp / 'repo', self.tmp / 'phone', self.tmp / 'bin',
                                                     self.tmp / 'calls.log')
        self.bin.mkdir()
        for name, body in (('xcodebuild', FAKE_XCODEBUILD), ('gh', FAKE_GH), ('notify', FAKE_NOTIFY)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'next')
        self.git('config', 'user.email', 't@example.com')
        self.git('config', 'user.name', 'T')
        (self.repo / 'scripts').mkdir()
        (self.repo / 'scripts/setup-worktree.sh').write_text('#!/bin/bash\nexit 0\n')
        self.git('add', '-A')
        self.git('commit', '-q', '-m', 'base')
        self.git('tag', 'testflight/0.1-build-29')
        for number in (10, 11, 12):
            self.git('commit', '-q', '--allow-empty', '-m', f'Merge pull request #{number}: change {number}')
        self.tip = self.git('rev-parse', 'HEAD')
        self.env = {'SM_PHONE_DIR': str(self.phone), 'SM_PHONE_REPO': str(self.repo), 'SM_PHONE_NO_FETCH': '1',
                    'SM_PHONE_GH': str(self.bin / 'gh'), 'SM_PHONE_DISK_FREE_GB': '100',
                    'SM_LANE_XCODEBUILD': str(self.bin / 'xcodebuild'), 'SM_LANE_STATE_DIR': str(self.tmp / 'lane'),
                    'SM_LANE_MEMORY_PRESSURE': '1', 'FAKE_LOG': str(self.log), 'FAKE_TIP': self.tip,
                    'FAKE_PLIST_KEY': '1', 'SM_PHONE_NOTIFY': str(self.bin / 'notify')}

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=str(self.repo), check=True, capture_output=True,
                              text=True).stdout.strip()

    def run_build(self, *args, **extra):
        env = {**os.environ, **self.env, **extra}
        return subprocess.run(['/usr/bin/python3', str(SCRIPTS / 'phone-build'), '--commit', self.tip, *args],
                              env=env, capture_output=True, text=True, timeout=120)

    def test_builds_writes_plan_and_points_latest(self):
        done = self.run_build()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        latest = (self.phone / 'latest').resolve()
        self.assertTrue(latest.name.endswith(self.tip[:7]))
        info = json.loads((latest / 'build.json').read_text())
        self.assertEqual(info['sha'], self.tip)
        self.assertEqual(info['commit_in_app'], self.tip)
        self.assertIn('lane runner tested', info['checks'])
        app_info = plistlib.loads((latest / 'SpokenMarginsApp.app/Info.plist').read_bytes())
        self.assertEqual(app_info['SMBuildCommit'], self.tip)
        plan = (latest / 'test-plan.md').read_text()
        self.assertIn('testflight/0.1-build-29', plan)
        self.assertIn('3 pull requests merged; 2 change something you see or hear', plan)
        self.assertLess(plan.index('Keep the voice playing'), plan.index('Library rows'))  # phone bugs first
        self.assertIn('(found on your phone)', plan)
        self.assertIn('play an article for a minute', plan)
        self.assertNotIn('Lane: retry evidence', plan)
        self.assertIn(f'Latest integration run for this commit: Lane report integration-{self.tip[:7]} — PASS.', plan)
        self.assertIn(f'Latest journeys run for this commit: Lane report journeys-{self.tip[:7]} — PASS.', plan)
        builds = self.log.read_text()
        self.assertIn('-configuration Release', builds)
        self.assertIn('-allowProvisioningUpdates', builds)
        self.assertNotIn('build-for-testing', builds)  # the runner already tested this commit
        self.assertIn(f'Commit {self.tip[:7]} is ready: 2 things to try.', builds)  # the owner's notification
        self.assertFalse(any((self.phone / '.work').iterdir()))  # scratch worktree and DerivedData gone
        self.assertNotIn('.work', self.git('worktree', 'list'))

    def test_plan_starts_at_the_installed_build(self):
        second = self.git('rev-parse', 'HEAD~1')  # after #10 and #11
        self.phone.mkdir()
        (self.phone / 'installed.txt').write_text(f'{second} 2026-09-30T08:00:00 phone\n')
        done = self.run_build()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        plan = (self.phone / 'latest/test-plan.md').read_text()
        self.assertIn(f'the build you last installed (`{second[:7]}`', plan)
        self.assertIn('1 pull requests merged', plan)
        self.assertNotIn('Keep the voice playing', plan)

    def test_untested_commit_runs_host_checks_first(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'Merge pull request #13 from someone/branch')
        self.tip = self.git('rev-parse', 'HEAD')
        (self.repo / '.venv/bin').mkdir(parents=True)
        (self.repo / '.venv/bin/python').write_text('#!/bin/sh\necho "fast $*" >> "$FAKE_LOG"\n')
        (self.repo / '.venv/bin/python').chmod(0o755)
        (self.repo / '.gitignore').write_text('')
        self.git('add', '-f', '.venv/bin/python')
        self.git('commit', '-q', '-m', 'Merge pull request #14 from someone/venv')
        self.tip = self.git('rev-parse', 'HEAD')
        done = self.run_build(FAKE_TIP=self.tip)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        calls = self.log.read_text()
        self.assertIn('fast scripts/verify-tests.py --plan fast', calls)
        self.assertIn('build-for-testing', calls)
        self.assertIn('passed here', json.loads((self.phone / 'latest/build.json').read_text())['checks'])

    def test_signing_failure_names_the_owner_step_and_is_not_retried(self):
        done = self.run_build(FAKE_FAIL='error: errSecInternalComponent')
        self.assertEqual(done.returncode, 1)
        self.assertIn('Always Allow', done.stdout)
        self.assertIn('phone build needs you', self.log.read_text())
        self.assertNotIn('is ready', self.log.read_text())
        self.assertFalse((self.phone / 'latest').exists())
        self.assertTrue((self.phone / 'last-failure.log').exists())
        again = self.run_build('--if-changed')
        self.assertEqual(again.returncode, 0)
        self.assertIn('already failed', again.stdout)

    def test_if_changed_skips_when_latest_is_the_tip(self):
        self.assertEqual(self.run_build().returncode, 0)
        self.log.unlink()
        done = self.run_build('--if-changed')
        self.assertEqual(done.returncode, 0)
        self.assertIn('nothing to do', done.stdout)
        self.assertFalse(self.log.exists())

    def test_guards_skip_on_memory_or_disk(self):
        done = self.run_build(SM_LANE_MEMORY_PRESSURE='2')
        self.assertEqual(done.returncode, 75)
        self.assertIn('memory pressure is warn', done.stdout)
        done = self.run_build(SM_PHONE_DISK_FREE_GB='13')
        self.assertEqual(done.returncode, 75)
        self.assertIn('needs 14 GB', done.stdout)
        self.assertFalse(self.log.exists())

    def test_keeps_the_three_newest_builds(self):
        module = load_phone_build()
        self.phone.mkdir()
        names = [f'2026093{day}-120000-abcdef{day}' for day in range(5)]
        for name in names:
            (self.phone / name).mkdir()
        (self.phone / 'installed.txt').write_text('x')
        with unittest.mock.patch.dict(os.environ, {'SM_PHONE_DIR': str(self.phone)}):
            module.prune()
        self.assertEqual(sorted(p.name for p in self.phone.iterdir()), sorted(names[2:] + ['installed.txt']))


class ListenerRuleTests(unittest.TestCase):
    def setUp(self):
        self.module = load_phone_build()

    def pr(self, title, *paths):
        return {'title': title, 'files': {'nodes': [{'path': p} for p in paths]}}

    def test_rule(self):
        facing = self.module.listener_facing
        self.assertTrue(facing(self.pr('Keep error banners', 'App/SpokenMarginsApp/Sources/A.swift')))
        self.assertTrue(facing(self.pr('Split articles', 'Packages/SessionKit/Sources/SessionKit/B.swift')))
        self.assertFalse(facing(self.pr('Fix a flaky test', 'Packages/SessionKit/Tests/SessionKitTests/C.swift')))
        self.assertFalse(facing(self.pr('Runner docs', 'docs/x.md', 'scripts/lane-runner.py')))
        self.assertFalse(facing(self.pr('A2 M1 step 3: move ExportScreen to its own file (#320)',
                                        'App/SpokenMarginsApp/Sources/ExportScreen.swift')))
        self.assertFalse(facing(self.pr('Test that a Build 29 Library keeps completion',
                                        'App/SpokenMarginsAppTests/D.swift', 'App/SpokenMarginsApp/Sources/E.swift')))

    def test_lane_work_is_not_listener_facing(self):
        # #374 (stream:A1) touched fifteen SessionKit sources, all to build them on Linux (#504).
        linux = self.pr("Run SessionKit's core tests on Linux (T1) and on every PR into next",
                        'Packages/SessionKit/Sources/SessionKit/SessionEngine.swift', 'scripts/verify-tests.py')
        self.assertTrue(self.module.listener_facing(linux))  # the paths alone would count it
        linux['labels'] = {'nodes': [{'name': 'stream:A1'}, {'name': 'automerge'}]}
        self.assertFalse(self.module.listener_facing(linux))

    def test_owner_check_none_is_no_check(self):
        # #124 says "**Owner check:** none." and the 9b0d275 plan printed "Check: none." (#504).
        none = {'body': '**Where:** cloud.\n**Owner check:** none.\n**Taken by:** nobody yet.'}
        self.assertIsNone(self.module.owner_check({'body': '', 'issues': [none]}))
        self.assertIsNone(self.module.owner_check({'body': 'Owner check: n/a', 'issues': []}))
        self.assertEqual(self.module.owner_check({'body': 'Owner check: open a chapter list.', 'issues': [none]}),
                         'open a chapter list.')
        self.assertIsNone(self.module.owner_check({'body': 'Owner check: nothing (lane only)', 'issues': []}))
        real = {'body': '**Owner check:** Nothing plays twice after a call.\n'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [real]}), 'Nothing plays twice after a call.')

    def test_owner_check_prefers_the_issue(self):
        pr = {'body': 'Owner check: from the PR', 'issues': [{'body': 'x\n**Owner check:** from the issue\nmore'}]}
        self.assertEqual(self.module.owner_check(pr), 'from the issue')
        self.assertEqual(self.module.owner_check({'body': 'Owner check: from the PR', 'issues': []}), 'from the PR')
        self.assertIsNone(self.module.owner_check({'body': '', 'issues': []}))

    def test_bug_report_steps_stand_in_for_a_missing_owner_check(self):
        issue = {'body': '**Steps:** open an article.\n**Expected:** a label that fits.\n'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [issue]}),
                         'open an article. Expected: a label that fits.')


class VerdictTests(unittest.TestCase):
    """#444: the plan looked for the verdict on #337, but the integration run and the Test Desk post their
    reports on #184, so a commit that passed read "No integration run has reported on this commit yet"."""

    # Recorded from #184 on 2026-09-30 (bodies cut after their first lines).
    RECORDED = [
        {'user': {'login': 'uncomposed'}, 'created_at': '2026-09-30T13:58:52Z',
         'body': "```text\nLane report integration-ebf1185 — PASS\ncommit ebf11851 (next's tip) · integration run: "
                 '--plan app · simulator SM Lane Desk erase-approval (1330F268), iOS 26.5, erased first · about 15 min\n'
                 'ran: --plan app (pass: 566 of 566 tests, 0 failures; build 47 s)\n```'},
        {'user': {'login': 'uncomposed'}, 'created_at': '2026-09-30T15:26:25Z',
         'body': "```text\nLane report integration-828597e — PASS\ncommit 828597e7 (next's tip) · integration run: "
                 '--plan app · simulator SM Lane Desk erase-approval (1330F268), iOS 26.5, erased first · about 16 min '
                 '(11:09–11:25)\nrun by: Test Desk\nran: --plan app (pass: 566 of 566 tests)\n```'},
        {'user': {'login': 'uncomposed'}, 'created_at': '2026-09-30T15:41:23Z',
         'body': '```text\nLane report journeys-828597e — PASS\ncommit 828597e7 · attended journeys after '
                 'integration-828597e PASS\n```'},
        {'user': {'login': 'uncomposed'}, 'created_at': '2026-09-30T15:50:00Z',
         'body': '## Test Desk hand-off\n\nLane report integration-828597e — FAIL is not a first line.'},
    ]

    def setUp(self):
        self.module = load_phone_build()
        self.calls = []

        def gh(*args):
            self.calls.append(args)
            # jq's @json leaves non-ASCII as is, U+2028 included
            return ''.join(json.dumps(c['body'], ensure_ascii=False) + '\n' for c in self.RECORDED)
        self.module.gh = gh

    def test_the_integration_report_on_184_for_the_commit_is_found(self):
        self.assertEqual(self.module.latest_verdict('828597e7' + '0' * 32), 'Lane report integration-828597e — PASS')
        self.assertEqual(self.calls[0][1], 'repos/uncomposed/spoken-margins-native/issues/184/comments')

    def test_a_report_for_another_commit_is_not_found(self):
        self.assertIsNone(self.module.latest_verdict('1234567' + '0' * 33))
        self.assertIsNone(self.module.latest_verdict('828597f' + '0' * 33))
        self.assertEqual(self.module.latest_verdict('ebf11851' + '0' * 32), 'Lane report integration-ebf1185 — PASS')

    def test_the_newest_report_for_the_commit_wins(self):
        rerun = {'body': '```text\nLane report integration-828597e — FAIL\n```'}
        self.RECORDED = self.RECORDED[:2] + [rerun]
        self.assertEqual(self.module.latest_verdict('828597e' + '0' * 33), 'Lane report integration-828597e — FAIL')

    def test_the_plan_shows_the_integration_and_journeys_reports(self):
        module = self.module
        module.plan_base = lambda sha: (None, 'the start')
        module.merged_prs = lambda base, sha: {}
        with tempfile.TemporaryDirectory() as folder:
            plan = module.write_plan(Path(folder), '828597e7' + '0' * 32, 'host tests').read_text()
        self.assertIn('Latest integration run for this commit: Lane report integration-828597e — PASS.', plan)
        self.assertIn('Latest journeys run for this commit: Lane report journeys-828597e — PASS.', plan)
        self.assertEqual(len(self.calls), 1)  # one read of #184 for both lines

    def test_without_github_the_plan_says_the_verdict_is_unknown(self):
        module = self.module
        module.gh = lambda *args: None
        module.plan_base = lambda sha: (None, 'the start')
        module.merged_prs = lambda base, sha: {}
        with tempfile.TemporaryDirectory() as folder:
            plan = module.write_plan(Path(folder), '828597e7' + '0' * 32, 'host tests').read_text()
        self.assertIn('GitHub could not be reached, so the integration verdict (on #184) is unknown.', plan)
        self.assertNotIn('No integration run has reported', plan)  # it may have: nobody could look
        self.assertNotIn('journeys run', plan)

    def test_with_no_report_yet_the_plan_says_so(self):
        self.RECORDED = self.RECORDED[:1]
        self.module.plan_base = lambda sha: (None, 'the start')
        self.module.merged_prs = lambda base, sha: {}
        with tempfile.TemporaryDirectory() as folder:
            plan = self.module.write_plan(Path(folder), '828597e7' + '0' * 32, 'host tests').read_text()
        self.assertIn('No integration run has reported on this commit yet.', plan)

    def plan_with(self, recorded):
        self.RECORDED = recorded
        self.module.plan_base = lambda sha: (None, 'the start')
        self.module.merged_prs = lambda base, sha: {}
        with tempfile.TemporaryDirectory() as folder:
            return self.module.write_plan(Path(folder), '828597e7' + '0' * 32, 'host tests').read_text()

    # #627: the shape the Test Desk posts when step 3b skips --plan app on a commit.
    SKIPPED_JOURNEYS = {'body': '```text\nLane report journeys-828597e — PASS\ncommit 828597e7 (next\'s tip) · J1, J4\n'
                                'run by: Test Desk\nintegration: skipped (every merged PR had its own T3 PASS; '
                                'last --plan app 1 h ago)\ncrashes: none\n```'}

    def test_a_deliberate_skip_says_why_instead_of_no_run_yet(self):
        plan = self.plan_with(self.RECORDED[:1] + [self.SKIPPED_JOURNEYS])
        self.assertIn('Integration run skipped by the Test Desk: every merged PR had its own T3 PASS; '
                      'last --plan app 1 h ago.', plan)
        self.assertNotIn('No integration run has reported', plan)
        self.assertIn('Latest journeys run for this commit: Lane report journeys-828597e — PASS.', plan)

    def test_an_integration_report_wins_over_a_skip_line(self):
        plan = self.plan_with(self.RECORDED[:2] + [self.SKIPPED_JOURNEYS])
        self.assertIn('Latest integration run for this commit: Lane report integration-828597e — PASS.', plan)
        self.assertNotIn('skipped by the Test Desk', plan)

    def test_a_skip_line_for_another_commit_or_a_ran_line_is_ignored(self):
        other = {'body': self.SKIPPED_JOURNEYS['body'].replace('828597e', '1234567')}
        ran = {'body': '```text\nLane report journeys-828597e — PASS\nintegration: ran (#612 touched Packages/)\n```'}
        plan = self.plan_with(self.RECORDED[:1] + [other, ran])
        self.assertIn('No integration run has reported on this commit yet.', plan)
        self.assertNotIn('skipped by the Test Desk', plan)

    def test_odd_bodies_are_skipped_not_fatal(self):
        line_separator = {'body': 'a note\u2028with a line separator'}
        self.RECORDED = [{'body': None}, line_separator] + self.RECORDED
        self.assertEqual(self.module.latest_verdict('828597e' + '0' * 33), 'Lane report integration-828597e — PASS')
        self.assertEqual(self.module.report_comments()[0], 'a note\u2028with a line separator')  # None skipped


class PlanGroupingTests(unittest.TestCase):
    """#427: two Follow PRs gave the owner the same check twice (checks 1 and 5)."""

    def setUp(self):
        self.module = load_phone_build()

    @staticmethod
    def pr(number, title, issues=(), body=''):
        return {'number': number, 'title': title, 'url': f'https://example/pr/{number}', 'body': body,
                'labels': {'nodes': []}, 'files': {'nodes': [{'path': 'App/SpokenMarginsApp/Sources/F.swift'}]},
                'issues': list(issues)}

    @staticmethod
    def issue(number, check, phone=False):
        return {'number': number, 'title': f'Issue {number}', 'url': f'https://example/issue/{number}',
                'body': f'**Owner check:** {check}\n',
                'labels': {'nodes': [{'name': 'found-on-phone'}] if phone else []}}

    def test_prs_for_one_issue_or_one_check_are_one_entry(self):
        follow = self.issue(80, 'Follow a site with a feed and one without.')
        entries = self.module.plan_entries([
            self.pr(330, 'Follow sites without a feed', [follow]),
            self.pr(310, 'Speak the error banner', body='Owner check: trigger an error and hear it.'),
            self.pr(300, 'Follow: show the feed name', [follow]),
            self.pr(290, 'Error banner stays', body='Owner check: Trigger an error  and hear it.'),
            self.pr(280, 'Library wording', [self.issue(81, 'Read the Library rows.')]),
        ])
        self.assertEqual([[pr['number'] for pr in entry] for entry in entries], [[330, 300], [310, 290], [280]])

    def test_the_plan_lists_a_shared_check_once_with_every_pr(self):
        follow = self.issue(80, 'Follow a site with a feed and one without.', phone=True)
        prs = {330: self.pr(330, 'Follow sites without a feed', [follow]),
               300: self.pr(300, 'Follow: show the feed name', [follow]),
               280: self.pr(280, 'Library wording', [self.issue(81, 'Read the Library rows.')])}
        module = self.module
        module.plan_base = lambda sha: (None, 'the start')
        module.merged_prs = lambda base, sha: {n: f'Merge pull request #{n}' for n in prs}
        module.fetch_prs = lambda numbers: prs
        module.report_comments = lambda: []
        with tempfile.TemporaryDirectory() as folder:
            plan = module.write_plan(Path(folder), 'a' * 40, 'host tests').read_text()
        self.assertEqual(plan.count('Follow a site with a feed and one without.'), 1, plan)
        self.assertIn('[PR #330](https://example/pr/330), [PR #300](https://example/pr/300), '
                      '[issue #80](https://example/issue/80)', plan)
        self.assertIn('1. **Follow sites without a feed** (found on your phone)', plan)
        self.assertIn('2. **Library wording**', plan)
        self.assertNotIn('3. ', plan)

    def write(self, prs):
        module = self.module
        module.plan_base = lambda sha: (None, 'the start')
        module.merged_prs = lambda base, sha: {n: f'Merge pull request #{n}' for n in prs}
        module.fetch_prs = lambda numbers: prs
        module.report_comments = lambda: []
        with tempfile.TemporaryDirectory() as folder:
            return module.write_plan(Path(folder), 'a' * 40, 'host tests').read_text()

    def test_only_what_the_owner_can_check_is_in_the_ten_minutes(self):
        # The 828597e plan (#504): one checkable item, one he couldn't judge, one that can't be seen on a phone.
        linux = self.pr(374, "Run SessionKit's core tests on Linux (T1) and on every PR into next")
        linux['labels'] = {'nodes': [{'name': 'stream:A1'}]}
        chapters = self.pr(497, 'Article import: give closing notes one chapter', [
            {'number': 124, 'title': 'Notes', 'url': 'https://example/issue/124', 'labels': {'nodes': []},
             'body': '**Owner check:** none.\n'}])
        fixed = self.pr(401, 'Voice keeps going after a call', [
            {'number': 90, 'title': 'Voice stops', 'url': 'https://example/issue/90', 'body': 'It stopped.',
             'labels': {'nodes': [{'name': 'found-on-phone'}]}}])
        plan = self.write({
            424: self.pr(424, "Show the build's commit in Settings", [self.issue(384, 'Double-click the Desktop icon.')]),
            366: self.pr(366, 'Take the rendered speech cache out of the offline storage ledger'),
            374: linux, 497: chapters, 401: fixed})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertIn("**Show the build's commit in Settings**", ten_minutes)
        self.assertIn('Double-click the Desktop icon.', ten_minutes)
        self.assertIn('**Voice keeps going after a call** (found on your phone)', ten_minutes)
        self.assertIn('repeat what you did when you found it', ten_minutes)
        self.assertNotIn('storage ledger', ten_minutes)
        self.assertNotIn('closing notes', ten_minutes)
        unchecked = plan.split('## Also changed (no phone check written)')[1].split('Behind the scenes')[0]
        self.assertIn('- Take the rendered speech cache out of the offline storage ledger ([#366]', unchecked)
        self.assertIn('- Article import: give closing notes one chapter ([#497]', unchecked)
        self.assertNotIn('Linux', plan)
        self.assertIn('5 pull requests merged; 4 change something you see or hear.', plan)
        self.assertIn('Behind the scenes: 1 more pull requests', plan)
        self.assertNotIn('Check: none', plan)
        self.assertNotIn('look for what the title describes', plan)

    def test_a_phone_found_bug_whose_check_says_none_is_not_in_the_ten_minutes(self):
        # The 5d1e1d5 plan: #283 was found on the phone, but its fix shows only in a diagnostics export,
        # so the issue says "Owner check: none." The plan still told the owner to repeat what found it.
        diagnostics = self.pr(494, "Diagnostics: stop reporting the previous item's failure on a new item", [
            self.issue(283, 'none. Optionally, in a later diagnostics export, a second item shows `failure: none`.',
                       phone=True)])
        plan = self.write({494: diagnostics})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertNotIn('Diagnostics', ten_minutes)
        self.assertNotIn('repeat what you did', plan)
        unchecked = plan.split('## Also changed (no phone check written)')[1]
        self.assertIn("- Diagnostics: stop reporting the previous item's failure on a new item ([#494]", unchecked)

    def test_with_no_written_checks_the_plan_says_so(self):
        plan = self.write({366: self.pr(366, 'Take the rendered speech cache out of the offline storage ledger')})
        self.assertIn('No phone checks were written for this build', plan)
        self.assertNotIn('Use the app as usual', plan)
        self.assertNotIn('1. ', plan)


if __name__ == '__main__':
    unittest.main()
