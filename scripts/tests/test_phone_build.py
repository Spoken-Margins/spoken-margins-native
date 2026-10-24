"""scripts/phone-build and scripts/install-phone-build.command (#384).

The installer runs against a fake `xcrun` on PATH, so no test can reach a real phone: the fake
answers `devicectl list devices` from FAKE_DEVICES and records every other call. The build runs
against a scratch repo and a fake xcodebuild (SM_LANE_XCODEBUILD) that makes an ad-hoc signed app.
"""
import contextlib
import datetime
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
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
    def test_daily_pin_installs_its_binary_even_after_latest_advances(self):
        folder = self.make_build()
        (self.phone / 'daily-ready').symlink_to(folder.name)
        newer = self.phone / '20261014-170000-bbbbbbb'
        newer.mkdir()
        (newer / 'SpokenMarginsApp.app').mkdir()
        (newer / 'build.json').write_text(json.dumps({'sha': 'b' * 40, 'built_at': '2026-10-14T17:00:00'}))
        (self.phone / 'latest').unlink()
        (self.phone / 'latest').symlink_to(newer.name)
        done, calls = self.run_installer([iphone('PHONE-1')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([call for call in calls if 'install app' in call],
                         [f'devicectl device install app --device PHONE-1 {folder.resolve()}/SpokenMarginsApp.app'])
        self.assertEqual((self.phone / 'installed.txt').read_text().split()[0], self.sha)
        self.assertFalse(any('uninstall' in call for call in calls))

    def other_build(self, name, sha, built_at):
        folder = self.phone / name
        (folder / 'SpokenMarginsApp.app').mkdir(parents=True)
        (folder / 'build.json').write_text(json.dumps({'sha': sha, 'built_at': built_at}))
        (folder / 'test-plan.md').write_text(f'# plan {sha[:7]}\n')
        return folder

    def point_latest_at(self, folder):
        (self.phone / 'latest').unlink()
        (self.phone / 'latest').symlink_to(folder.name)

    def pin_daily_at(self, folder, when):
        (self.phone / 'daily-ready').symlink_to(folder.name)
        stamp = datetime.datetime.fromisoformat(when).timestamp()
        os.utime(self.phone / 'daily-ready', (stamp, stamp), follow_symlinks=False)

    def test_daily_pin_never_goes_over_a_newer_build_on_the_phone(self):
        pin = self.make_build()
        self.pin_daily_at(pin, '2026-09-30T13:00:00')
        newer = self.other_build('20260930-150000-ccccccc', 'c' * 40, '2026-09-30T15:00:00')
        self.point_latest_at(newer)
        (self.phone / 'installed.txt').write_text('c' * 40 + ' 2026-09-30T15:10:00 Cole iPhone\n')
        done, calls = self.run_installer([iphone('PHONE-1')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertFalse(any('install app' in call for call in calls), calls)
        self.assertIn('newer build than this morning', done.stdout)
        self.assertIn('already has this build: commit ccccccc', done.stdout)
        self.assertNotIn(f'open {pin.resolve()}/test-plan.md', calls)

    def test_pruned_newer_build_on_the_phone_gets_latest_not_the_pin(self):
        # Seen 2026-10-15 (#1691): the phone's 10:47 build was pruned; the pin was the 05:16 build.
        pin = self.make_build()
        self.pin_daily_at(pin, '2026-09-30T13:00:00')
        latest = self.other_build('20260930-170000-ddddddd', 'd' * 40, '2026-09-30T17:00:00')
        self.point_latest_at(latest)
        (self.phone / 'installed.txt').write_text('c' * 40 + ' 2026-09-30T15:10:00 Cole iPhone\n')
        done, calls = self.run_installer([iphone('PHONE-1')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([call for call in calls if 'install app' in call],
                         [f'devicectl device install app --device PHONE-1 {latest.resolve()}/SpokenMarginsApp.app'])
        self.assertEqual((self.phone / 'installed.txt').read_text().split()[0], 'd' * 40)
        self.assertIn(f'open {latest.resolve()}/test-plan.md', calls)

    def test_daily_pin_still_goes_over_an_older_build_on_the_phone(self):
        pin = self.make_build()
        self.pin_daily_at(pin, '2026-09-30T13:00:00')
        self.other_build('20260929-090000-eeeeeee', 'e' * 40, '2026-09-29T09:00:00')
        latest = self.other_build('20260930-170000-ddddddd', 'd' * 40, '2026-09-30T17:00:00')
        self.point_latest_at(latest)
        (self.phone / 'installed.txt').write_text('e' * 40 + ' 2026-09-30T14:00:00 Cole iPhone\n')
        done, calls = self.run_installer([iphone('PHONE-1')])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([call for call in calls if 'install app' in call],
                         [f'devicectl device install app --device PHONE-1 {pin.resolve()}/SpokenMarginsApp.app'])
        self.assertIn('install the daily phone pass', done.stdout)

    def test_already_installed_daily_binary_opens_plan_without_reinstall(self):
        folder = self.make_build()
        (self.phone / 'daily-ready').symlink_to(folder.name)
        (self.phone / 'installed.txt').write_text(self.sha + '\n')
        done, calls = self.run_installer([])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(f'open {folder.resolve()}/test-plan.md', calls)
        self.assertFalse(any('install app' in call for call in calls))
        self.assertEqual((self.tmp / 'icloud' / f'Test plan {self.sha[:7]}.md').read_text(), '# plan\n')

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
os.makedirs(app, exist_ok=True)
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

# Off the Mac only (#2268): stand-ins for the two macOS tools phone-build itself runs after the Release build.
MAC_TOOL_STUBS = {
    'codesign': '#!/bin/sh\nexit 0\n',  # the fake xcodebuild's ad-hoc signature and phone-build's --verify
    'ditto': '#!/bin/sh\nexec cp -R "$1" "$2"\n',  # phone-build's one use: copy the .app to a new path
}

FAKE_GH = r'''#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
def bot_comment(body):
    return json.dumps({"body": body, "author_association": "NONE", "user": {"login": "github-actions[bot]"}})
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write("gh " + " ".join(args) + "\n")
tip = os.environ["FAKE_TIP"]
if args[:1] == ["api"] and args[1].endswith("/issues/12/comments"):
    if os.environ.get("FAKE_SAFE_REMERGE"):
        print(bot_comment("**Merge check (triage desk) on `1234567`: PASS, re-merged onto the newest next without re-testing.**\n"
              "- Tested this PR merged with next at `7654321`. Ran: host tests (--plan fast).\n"
              "- next hasn't moved since (the test ran in the automerge run held for T3).\n"
              "- So the re-merge `%s` goes to next not re-tested. The Test Desk tests next's merged tip end to end."
              % tip[:7]))
    else:
        print(bot_comment("**Merge check (triage desk) on `1234567`: %s.**\n- Tested the merge commit `%s`.\n"
              "- Ran: --plan fast and both builds.\n- Pushing `%s` to next now."
              % (os.environ.get("FAKE_MERGE_VERDICT", "PASS"), tip[:7], tip[:7])))
elif args[:1] == ["api"] and args[1].endswith("/issues/184/comments"):
    for body in ("```text\nLane report integration-%s — PASS\nran: --plan app (pass: 564 of 564 tests)\n```" % tip[:7],
                 "```text\nLane report journeys-%s — PASS\nran: J4 (pass)\n```" % tip[:7]):
        print(bot_comment(body))
elif args[:2] in (["issue", "list"], ["issue", "create"], ["issue", "edit"], ["issue", "close"],
                  ["issue", "comment"]):
    path = os.environ.get("FAKE_ISSUES")
    if not path:
        sys.exit(1)  # GitHub unreachable for issues
    items = json.load(open(path)) if os.path.exists(path) else []
    def option(name):
        return args[args.index(name) + 1]
    if args[1] == "list":
        print(json.dumps(items))
    elif args[1] == "create":
        items.append({"number": 100 + len(items), "title": option("--title"), "body": option("--body"),
                      "labels": option("--label")})
    elif args[1] == "edit":
        for item in items:
            if str(item["number"]) == args[2]:
                item["body"] = option("--body")
    elif args[1] == "close":
        items = [item for item in items if str(item["number"]) != args[2]]
    json.dump(items, open(path, "w"))
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
                    'FAKE_PLIST_KEY': '1', 'SM_PHONE_NOTIFY': str(self.bin / 'notify'),
                    'SM_PHONE_ICLOUD': str(self.tmp / 'icloud' / 'plans')}
        missing = [tool for tool in MAC_TOOL_STUBS if shutil.which(tool) is None]
        if missing:
            # On the VPS's fast-portable run (Linux) there is no codesign or ditto. Stubs let the tests about what
            # the build decides run anywhere; on the Mac the real tools still sign, verify and copy the app.
            tools = self.tmp / 'mac-tools'
            tools.mkdir()
            for tool in missing:
                (tools / tool).write_text(MAC_TOOL_STUBS[tool])
                (tools / tool).chmod(0o755)
            self.env['PATH'] = f'{tools}{os.pathsep}{os.environ.get("PATH", "")}'

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
        self.assertFalse(any((self.phone / '.work').iterdir()))  # temporary logs gone; cache persists
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

    def test_host_checks_leave_the_hot_file_ratchet_to_the_merge(self):
        # The ratchet is a merge rule, not a build check: an unmerged PR that grows a hot file (a compaction the
        # owner asked to see on his phone first, or a hot-file-ok PR) still gets a phone build (#2180 audit).
        (self.repo / '.venv/bin').mkdir(parents=True)
        python = self.repo / '.venv/bin/python'
        python.write_text('#!/bin/sh\necho "fast hot-file-ok=${SM_HOT_FILE_OK:-unset} $*" >> "$FAKE_LOG"\n'
                          '[ "$SM_HOT_FILE_OK" = 1 ]\n')
        python.chmod(0o755)
        self.git('add', '-f', '.venv/bin/python')
        self.git('commit', '-q', '-m', 'Grow Gate1RootView.swift for the compaction mockup')
        self.tip = self.git('rev-parse', 'HEAD')
        done = self.run_build(FAKE_TIP=self.tip)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('fast hot-file-ok=1 scripts/verify-tests.py --plan fast', self.log.read_text())

    def commit_the_host_check_python(self, subject):
        """Commit a fake `.venv/bin/python` (what the build runs verify-tests.py with) as the new tip.

        It logs its command line to FAKE_LOG and exits with FAKE_FAST_EXIT."""
        (self.repo / '.venv/bin').mkdir(parents=True)
        python = self.repo / '.venv/bin/python'
        python.write_text('#!/bin/sh\necho "fast $*" >> "$FAKE_LOG"\nexit ${FAKE_FAST_EXIT:-0}\n')
        python.chmod(0o755)
        self.git('add', '-f', '.venv/bin/python')
        self.git('commit', '-q', '-m', subject)
        self.tip = self.git('rev-parse', 'HEAD')

    def build_the_merge_commit(self, runs_checks, **extra):
        """Build a tip that reads "Merge pull request #12: ..." (the fake gh serves PR 12's merge check)."""
        self.commit_the_host_check_python('Merge pull request #12: Keep the voice playing')
        done = self.run_build(**{'FAKE_TIP': self.tip, **extra})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        calls = self.log.read_text()
        self.assertEqual('fast scripts/verify-tests.py --plan fast' in calls, runs_checks, calls)
        self.assertEqual('build-for-testing' in calls, runs_checks, calls)
        self.assertIn('-configuration Release', calls)  # either way the phone build itself ran
        checks = json.loads((self.phone / 'latest/build.json').read_text())['checks']
        self.assertEqual('passed here' in checks, runs_checks, checks)

    def test_a_merge_check_that_passed_and_pushed_this_commit_skips_the_host_checks(self):
        self.build_the_merge_commit(runs_checks=False)

    def test_a_safe_remerge_builds_release_without_repeating_host_or_simulator_checks(self):
        self.build_the_merge_commit(runs_checks=False, FAKE_SAFE_REMERGE='1')
        checks = json.loads((self.phone / 'latest/build.json').read_text())['checks']
        self.assertIn('safely re-merged', checks)

    def test_a_merge_check_that_pushed_another_commit_does_not_count_so_the_host_checks_run(self):
        # The PR was re-merged after the runner's test (its comment says "Pushing `<sha7>`" of the old merge).
        self.build_the_merge_commit(runs_checks=True, FAKE_TIP='deadbee' + '0' * 33)

    def test_a_merge_check_that_says_fail_does_not_count_so_the_host_checks_run(self):
        self.build_the_merge_commit(runs_checks=True, FAKE_MERGE_VERDICT='FAIL')

    def assert_build_stopped(self, done, why, builds_after):
        """A build that failed its checks: exit 1, the reason recorded, and nothing installable made."""
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(f'FAILED on {self.tip[:7]}: {why}', done.stdout)
        attempt = json.loads((self.phone / 'last-attempt.json').read_text())
        self.assertEqual((attempt['sha'], attempt['result']), (self.tip, f'failed: {why}'))
        self.assertTrue((self.phone / 'last-failure.log').exists())
        self.assertFalse((self.phone / 'latest').exists())
        calls = self.log.read_text()
        self.assertEqual('-configuration Release' in calls, builds_after, calls)  # the Release build never ran
        self.assertNotIn('is ready', calls)  # and the owner was not told to install anything

    def test_failing_host_tests_stop_the_build_before_any_xcodebuild(self):
        self.commit_the_host_check_python('Merge pull request #14 from someone/venv')  # no merge check: runs them
        done = self.run_build(FAKE_FAST_EXIT='1')
        self.assert_build_stopped(done, 'host tests (--plan fast) failed', builds_after=False)
        calls = self.log.read_text()
        self.assertIn('fast scripts/verify-tests.py --plan fast', calls)
        self.assertNotIn('build-for-testing', calls)  # not even the simulator build

    def test_a_failing_simulator_build_stops_the_build_before_the_release_build(self):
        self.commit_the_host_check_python('Merge pull request #14 from someone/venv')
        done = self.run_build(FAKE_FAIL='error: cannot find type in scope')
        self.assert_build_stopped(done, 'the simulator build failed', builds_after=False)
        calls = self.log.read_text()
        self.assertIn('fast scripts/verify-tests.py --plan fast', calls)  # the host tests passed first
        self.assertIn('build-for-testing', calls)
        self.assertNotIn('Signing needs the owner', done.stdout)

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

    def next_tip(self):
        """Another merge of PR 12 on next, which the fake gh says the lane runner tested."""
        self.git('commit', '-q', '--allow-empty', '-m', 'Merge pull request #12: another change')
        self.tip = self.git('rev-parse', 'HEAD')
        self.env['FAKE_TIP'] = self.tip

    def release_items(self):
        return json.loads(self.issues.read_text()) if self.issues.exists() else []

    def test_a_failed_release_build_opens_one_item_updates_it_and_the_next_success_closes_it(self):
        """#1465: Release phone builds failed for two days while Debug tips passed, and nobody was told."""
        self.issues = self.tmp / 'issues.json'
        self.env['FAKE_ISSUES'] = str(self.issues)
        self.assertEqual(self.run_build().returncode, 0)
        good = self.tip[:7]
        self.assertEqual(self.release_items(), [])  # a success with nothing open files nothing

        self.next_tip()
        failed = self.run_build(FAKE_FAIL='error: Command CodeSign failed')
        self.assertEqual(failed.returncode, 1)
        (item,) = self.release_items()
        self.assertEqual(item['title'], 'Release phone build is failing on next')
        self.assertIn(self.tip, item['body'])                       # the failed commit
        self.assertIn(f'Last good binary: `{good}`', item['body'])  # and what can still be installed
        self.assertIn('Command CodeSign failed', item['body'])

        self.next_tip()
        self.assertEqual(self.run_build(FAKE_FAIL='error: Command CodeSign failed').returncode, 1)
        (item,) = self.release_items()                              # still one item, now naming the newer commit
        self.assertIn(self.tip, item['body'])
        self.assertIn('Another commit fails the Release build', self.log.read_text())

        self.next_tip()
        self.assertEqual(self.run_build().returncode, 0)
        self.assertEqual(self.release_items(), [])                  # the success closed it
        self.assertIn('issue close', self.log.read_text())

    def test_a_signing_failure_already_tells_the_owner_so_it_files_nothing(self):
        self.issues = self.tmp / 'issues.json'
        self.env['FAKE_ISSUES'] = str(self.issues)
        done = self.run_build(FAKE_FAIL='error: errSecInternalComponent')
        self.assertEqual(done.returncode, 1)
        self.assertIn('phone build needs you', self.log.read_text())
        self.assertEqual(self.release_items(), [])

    def test_only_the_exact_title_is_the_owned_item(self):
        self.issues = self.tmp / 'issues.json'
        lookalike = {'number': 7, 'title': 'Release phone build is failing on next branch', 'body': 'someone else\'s'}
        self.issues.write_text(json.dumps([lookalike]))
        self.env['FAKE_ISSUES'] = str(self.issues)
        self.assertEqual(self.run_build(FAKE_FAIL='error: Command CodeSign failed').returncode, 1)
        items = self.release_items()
        self.assertEqual([i['title'] for i in items],
                         ['Release phone build is failing on next branch', 'Release phone build is failing on next'])
        self.assertEqual(items[0], lookalike)
        listed = [l for l in self.log.read_text().splitlines() if l.startswith('gh issue list')]
        self.assertTrue(listed and '--search' not in listed[0] and '--label where:mac' in listed[0], listed)

    def test_a_release_failure_with_github_unreachable_still_fails_the_build_plainly(self):
        done = self.run_build(FAKE_FAIL='error: Command CodeSign failed')  # no FAKE_ISSUES: gh issue exits 1
        self.assertEqual(done.returncode, 1)
        self.assertIn('could not reach GitHub to report the Release failure', done.stdout)

    def test_if_changed_skips_when_latest_is_the_tip(self):
        self.assertEqual(self.run_build().returncode, 0)
        self.log.unlink()
        done = self.run_build('--if-changed')
        self.assertEqual(done.returncode, 0)
        self.assertIn('nothing to do', done.stdout)
        self.assertFalse(self.log.exists())

    def test_release_cache_and_source_survive_and_are_reused_for_the_next_tip(self):
        self.assertEqual(self.run_build().returncode, 0)
        cache = self.phone / '.cache'
        derived = cache / 'dd-release'
        self.assertTrue((derived / 'Build/Products/Release-iphoneos/SpokenMarginsApp.app').exists())
        source = cache / 'src/scripts/setup-worktree.sh'
        unchanged = source.stat().st_mtime_ns
        marker = derived / 'incremental-marker'
        marker.write_text('keep compiled intermediates')
        self.git('commit', '-q', '--allow-empty', '-m', 'Merge pull request #12: another tested change')
        self.tip = self.git('rev-parse', 'HEAD')
        done = self.run_build(FAKE_TIP=self.tip)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(marker.read_text(), 'keep compiled intermediates')
        self.assertEqual(source.stat().st_mtime_ns, unchanged)
        self.assertEqual(self.git('-C', str(cache / 'src'), 'rev-parse', 'HEAD'), self.tip)
        self.assertEqual(json.loads((self.phone / 'latest/build.json').read_text())['sha'], self.tip)
        releases = [line for line in self.log.read_text().splitlines() if '-configuration Release' in line]
        self.assertEqual(len(releases), 2)
        self.assertTrue(all(f'-derivedDataPath {derived}' in line for line in releases))
        self.assertFalse(any((self.phone / '.work').iterdir()))

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


FAKE_HOSTED_GH = r"""#!/usr/bin/python3
import json, os, shutil, subprocess, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write("gh " + " ".join(args) + "\n")
tip = os.environ["FAKE_TIP"]
run = {"id": 77, "head_sha": tip, "head_branch": "main", "event": os.environ.get("FAKE_HOSTED_EVENT", "schedule"),
       "conclusion": "success", "path": os.environ.get("FAKE_HOSTED_PATH", ".github/workflows/phone-build.yml"),
       "html_url": "https://github.com/x/y/actions/runs/77"}
if args[:1] == ["api"] and "/actions/workflows/phone-build.yml/runs" in args[1]:
    print(json.dumps({"workflow_runs": [run]}))
elif args[:2] == ["api", "repos/Spoken-Margins/spoken-margins-native/actions/runs/77/artifacts"]:
    print(json.dumps({"artifacts": [{"name": "phone-build-" + tip, "expired": bool(os.environ.get("FAKE_EXPIRED")),
                                     "created_at": "2026-10-21T12:30:00Z"}]}))
elif args[:2] == ["run", "download"]:
    out = args[args.index("-D") + 1]
    os.makedirs(out)
    shutil.copy(os.environ["FAKE_HOSTED_ZIP"], os.path.join(out, "SpokenMarginsApp.app.zip"))
    json.dump({"sha": tip, "build_seconds": 1500}, open(os.path.join(out, "build.json"), "w"))
    open(os.path.join(out, "build.log"), "w").write("** BUILD SUCCEEDED ** (hosted)\n")
else:
    sys.exit(subprocess.call([os.environ["FAKE_BASE_GH"], *args]))
"""


@unittest.skipUnless(shutil.which('ditto') and shutil.which('codesign'), 'needs the Mac\'s ditto and codesign')
class HostedPhoneBuildTests(unittest.TestCase):
    """--source hosted (#2357): the Mac takes the GitHub-hosted build instead of building."""
    setUp_base = PhoneBuildTests.setUp
    git = PhoneBuildTests.git
    run_build = PhoneBuildTests.run_build

    def setUp(self):
        self.setUp_base()
        (self.bin / 'gh').rename(self.bin / 'gh-base')
        (self.bin / 'gh').write_text(FAKE_HOSTED_GH)
        (self.bin / 'gh').chmod(0o755)
        self.zip = self.make_zip(self.tip)
        self.env.update({'SM_PHONE_SOURCE': 'hosted', 'FAKE_BASE_GH': str(self.bin / 'gh-base'),
                         'FAKE_HOSTED_ZIP': str(self.zip)})

    def make_zip(self, commit):
        """The artifact's app: ad-hoc signed, with a profile and the commit in Info.plist."""
        app = self.tmp / 'hosted' / commit[:7] / 'SpokenMarginsApp.app'
        app.mkdir(parents=True)
        shutil.copy('/usr/bin/true', app / 'SpokenMarginsApp')
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'SpokenMarginsApp', 'CFBundleIdentifier': 'com.example.fake',
            'CFBundleVersion': '35', 'CFBundlePackageType': 'APPL', 'SMBuildCommit': commit}))
        (app / 'embedded.mobileprovision').write_text('profile')
        subprocess.check_call(['codesign', '-s', '-', '--force', str(app)], stderr=subprocess.DEVNULL)
        archive = app.parent / 'SpokenMarginsApp.app.zip'
        subprocess.check_call(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)])
        return archive

    def test_takes_the_hosted_build_without_building_and_writes_the_installers_folder(self):
        done = self.run_build()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        latest = (self.phone / 'latest').resolve()
        self.assertTrue(latest.name.endswith(self.tip[:7]))
        info = json.loads((latest / 'build.json').read_text())
        self.assertEqual((info['sha'], info['bundle_version'], info['built_on']), (self.tip, '35', 'github-hosted'))
        self.assertEqual(info['build_seconds'], 1500)
        self.assertIn('built and signed on a GitHub-hosted Mac (https://github.com/x/y/actions/runs/77)', info['checks'])
        # The installer compares built_at as a naive local time.
        self.assertIsNone(datetime.datetime.fromisoformat(info['built_at']).tzinfo)
        self.assertEqual(plistlib.loads((latest / 'SpokenMarginsApp.app/Info.plist').read_bytes())['SMBuildCommit'],
                         self.tip)
        self.assertTrue((latest / 'test-plan.md').exists())
        self.assertIn('(hosted)', (latest / 'build.log').read_text())
        calls = self.log.read_text()
        self.assertIn('gh run download 77 -R Spoken-Margins/spoken-margins-native -n phone-build-' + self.tip, calls)
        self.assertNotIn('-configuration Release', calls)  # no xcodebuild at all
        self.assertNotIn('verify-tests.py', calls)

    def test_only_the_workflows_own_schedule_or_dispatch_runs_count(self):
        for extra in ({'FAKE_HOSTED_EVENT': 'pull_request'}, {'FAKE_HOSTED_EVENT': 'push'},
                      {'FAKE_HOSTED_PATH': '.github/workflows/other.yml'}, {'FAKE_EXPIRED': '1'}):
            with self.subTest(**extra):
                done = self.run_build(**extra)
                self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
                self.assertIn('no hosted phone build', done.stdout)
                self.assertFalse((self.phone / 'latest').exists())
                self.assertNotIn('run download', self.log.read_text())

    def test_if_changed_does_nothing_when_latest_is_the_hosted_build(self):
        self.assertEqual(self.run_build().returncode, 0)
        before = self.log.read_text().count('run download')
        done = self.run_build('--if-changed')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('latest is already the hosted build', done.stdout)
        self.assertEqual(self.log.read_text().count('run download'), before)

    def test_an_app_from_another_commit_is_refused(self):
        self.env['FAKE_HOSTED_ZIP'] = str(self.make_zip('f' * 40))
        done = self.run_build()
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn('the app says it was built from', done.stdout)
        self.assertFalse((self.phone / 'latest').exists())
        self.assertTrue(json.loads((self.phone / 'last-attempt.json').read_text())['result'].startswith('failed'))

    def test_the_source_file_switches_and_the_environment_wins(self):
        del self.env['SM_PHONE_SOURCE']
        self.phone.mkdir()
        (self.phone / 'source').write_text('hosted\n')
        done = self.run_build()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('downloading the hosted phone build', done.stdout)
        done = self.run_build(SM_PHONE_SOURCE='mac')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('-configuration Release', self.log.read_text())  # built here


class PhoneBuildFolderTests(unittest.TestCase):
    def test_two_builds_of_one_commit_in_the_same_second_get_different_folders(self):
        # #2537: the folder is named by the second and the commit, so the second build used to fail.
        module = load_phone_build()
        with tempfile.TemporaryDirectory() as tmp, unittest.mock.patch.dict(os.environ, {'SM_PHONE_DIR': tmp}):
            sha = 'ab' * 20
            first = module.new_build_folder('20261023-094656', sha)
            second = module.new_build_folder('20261023-094656', sha)
            third = module.new_build_folder('20261023-094656', sha)
            self.assertEqual([first.name, second.name, third.name],
                             ['20261023-094656-abababa', '20261023-094657-abababa', '20261023-094658-abababa'])
            for folder in (first, second, third):
                self.assertRegex(folder.name, r'\d{8}-\d{6}-[0-9a-f]{7}$')  # still what prune() matches
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), [first.name, second.name, third.name])


class PhoneBuildCoalescingTests(unittest.TestCase):
    def setUp(self):
        self.module = load_phone_build()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.phone = Path(self.tmp.name)
        self.sha = 'ab' * 20
        self.now = datetime.datetime(2026, 10, 10, 12, tzinfo=datetime.timezone.utc)
        self.addCleanup(unittest.mock.patch.stopall)
        unittest.mock.patch.dict(os.environ, {'SM_PHONE_DIR': str(self.phone), 'SM_PHONE_NO_FETCH': '1'}).start()
        clock = unittest.mock.patch.object(self.module.datetime, 'datetime', wraps=datetime.datetime).start()
        clock.now.return_value = self.now
        self.module.git = unittest.mock.Mock(return_value=self.sha)
        self.module.latest_build = unittest.mock.Mock(return_value={})
        self.module.latest_verdict = unittest.mock.Mock(return_value=None)
        self.module.guard_reason = unittest.mock.Mock(return_value=None)
        self.module.clear_work = unittest.mock.Mock()
        self.module.build = unittest.mock.Mock(return_value=0)

    def attempt(self, minutes, filename='last-attempt.json', result='built'):
        (self.phone / filename).write_text(json.dumps({
            'sha': 'cd' * 20, 'result': result,
            'at': (self.now - datetime.timedelta(minutes=minutes)).isoformat()}))

    def test_changed_tips_coalesce_until_an_hour_after_the_previous_build(self):
        self.attempt(20)
        self.assertEqual(self.module.main(['--if-changed']), 0)
        self.module.build.assert_not_called()
        self.module.guard_reason.assert_not_called()
        self.module.clear_work.assert_not_called()

    def test_hour_boundary_and_first_build_run(self):
        for minutes in (None, 60, 70):
            with self.subTest(minutes=minutes):
                (self.phone / 'last-start.json').unlink(missing_ok=True)
                if minutes is not None:
                    self.attempt(minutes)
                self.assertEqual(self.module.main(['--if-changed']), 0)
        self.assertEqual(self.module.build.call_count, 3)

    def test_owner_request_bypasses_the_hourly_delay(self):
        self.attempt(5)
        self.assertEqual(self.module.main(['--commit', self.sha]), 0)
        self.module.build.assert_called_once_with(self.sha)

    def test_integration_pass_can_build_early_but_fail_and_inconclusive_cannot(self):
        self.attempt(5)
        for outcome in ('FAIL', 'INCONCLUSIVE', 'PASS'):
            with self.subTest(outcome=outcome):
                self.module.latest_verdict.return_value = f'Lane report integration-{self.sha[:7]} — {outcome}'
                self.assertEqual(self.module.main(['--if-changed']), 0)
                self.assertEqual(self.module.build.call_count, int(outcome == 'PASS'))
        self.module.latest_verdict.assert_called_with(self.sha)

    def test_start_is_saved_before_build_and_new_tips_do_not_reset_the_timer(self):
        def build(sha):
            state = json.loads((self.phone / 'last-start.json').read_text())
            self.assertEqual(state['sha'], sha)
            self.assertEqual(state['at'], self.now.isoformat(timespec='seconds'))
            return 1
        self.module.build.side_effect = build
        self.assertEqual(self.module.main(['--if-changed']), 1)
        self.module.git.return_value = 'ef' * 20
        self.assertEqual(self.module.main(['--if-changed']), 0)
        self.module.build.assert_called_once_with(self.sha)

    def test_guards_do_not_consume_the_hour_and_failed_tip_is_not_retried(self):
        self.module.guard_reason.return_value = 'low disk'
        self.assertEqual(self.module.main(['--if-changed']), 75)
        self.assertFalse((self.phone / 'last-start.json').exists())
        self.attempt(70, result='failed: signing')
        self.module.git.return_value = 'cd' * 20
        self.assertEqual(self.module.main(['--if-changed']), 0)
        self.module.build.assert_not_called()

    def test_in_progress_start_takes_precedence_over_older_completion(self):
        self.attempt(120)
        self.attempt(10, filename='last-start.json')
        self.assertEqual(self.module.main(['--if-changed']), 0)
        self.module.build.assert_not_called()

    def test_old_local_timestamps_and_unavailable_github_still_coalesce(self):
        local = datetime.datetime.fromtimestamp(self.now.timestamp() - 10 * 60)
        (self.phone / 'last-attempt.json').write_text(json.dumps({'at': local.isoformat()}))
        self.assertEqual(self.module.main(['--if-changed']), 0)
        self.module.build.assert_not_called()

    def test_invalid_or_future_state_does_not_stall_builds(self):
        for at in ('not a date', None, (self.now + datetime.timedelta(hours=1)).isoformat()):
            with self.subTest(at=at):
                (self.phone / 'last-start.json').write_text(json.dumps({'at': at}))
                self.assertEqual(self.module.main(['--if-changed']), 0)
        self.assertEqual(self.module.build.call_count, 3)


class PhoneBuildMergeEvidenceTests(unittest.TestCase):
    def test_runner_safe_remerge_skips_duplicate_checks_only_for_its_named_commit(self):
        module = load_phone_build()
        sha = 'ab' * 20
        module.git = unittest.mock.Mock(return_value='Merge pull request #12: tested change')
        recorded = ('**Merge check (triage desk) on `1234567`: PASS, re-merged onto the newest next '
                    'without re-testing.**\n'
                    '- Tested this PR merged with next at `7654321`. Ran: host tests (--plan fast).\n'
                    '- next has since moved to `1111111`, and its commits touch none of this PR\'s files '
                    'and no build inputs: `2222222`.\n'
                    f'- So the re-merge `{sha[:7]}` goes to next not re-tested. '
                    'The Test Desk tests next\'s merged tip end to end.\n'
                    '_Posted by the lane runner (scripts/lane-runner.py)._')
        for body, accepts in ((recorded, True), (recorded.replace('PASS,', 'FAIL,'), False),
                              (recorded.replace(sha[:7], 'deadbee'), False),
                              (recorded.replace('goes to next', 'goes to main'), False)):
            with self.subTest(body=body):
                module.gh = unittest.mock.Mock(return_value=json.dumps(
                    {'body': body, 'author_association': 'NONE', 'user': {'login': 'github-actions[bot]'}}))
                self.assertEqual(module.runner_tested(sha) is not None, accepts)


class StrangerEvidenceTests(unittest.TestCase):
    """#1822: the plan says "the lane tested this" and "the integration run passed" from comments, so those come
    only from the owner, collaborators and the bot."""
    CHECK = ('**Merge check (triage desk) on `1234567`: PASS.**\n- Tested the merge commit `%s`.\n'
             '- Ran: --plan fast and both builds.\n- Pushing `%s` to next now.')

    def setUp(self):
        self.module = load_phone_build()
        self.sha = 'ab' * 20
        self.module.git = unittest.mock.Mock(return_value='Merge pull request #12: tested change')

    def comment(self, body, login, association):
        return json.dumps({'body': body, 'author_association': association, 'user': {'login': login}}) + '\n'

    def test_a_strangers_merge_check_is_not_evidence(self):
        body = self.CHECK % (self.sha[:7], self.sha[:7])
        self.module.gh = lambda *args: self.comment(body, 'mallory', 'NONE')
        self.assertIsNone(self.module.runner_tested(self.sha))
        self.module.gh = lambda *args: self.comment(body, 'github-actions', 'NONE')
        self.assertIsNone(self.module.runner_tested(self.sha))
        self.module.gh = lambda *args: self.comment(body, 'github-actions[bot]', 'NONE')
        self.assertIsNotNone(self.module.runner_tested(self.sha))

    def test_a_strangers_report_on_the_report_issue_is_not_a_verdict(self):
        fake = '```text\nLane report integration-%s — PASS\n```' % self.sha[:7]
        self.module.gh = lambda *args: self.comment(fake, 'mallory', 'NONE')
        self.assertEqual(self.module.report_comments(), [])
        self.module.gh = lambda *args: self.comment(fake, 'uncomposed', 'OWNER') + self.comment('x', 'mallory', 'NONE')
        self.assertEqual(self.module.report_comments(), [fake])


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
        # #1193: #177's "none now; #178's journey covers ..." must not reach the plan as a check.
        now = {'body': "**Owner check:** none now; #178's journey covers the paid-feed case on the phone."}
        self.assertIsNone(self.module.owner_check({'body': '', 'issues': [now]}))
        real = {'body': '**Owner check:** Nothing plays twice after a call.\n'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [real]}), 'Nothing plays twice after a call.')

    def test_owner_check_prefers_the_issue(self):
        pr = {'body': 'Owner check: from the PR', 'issues': [{'body': 'x\n**Owner check:** from the issue\nmore'}]}
        self.assertEqual(self.module.owner_check(pr), 'from the issue')
        self.assertEqual(self.module.owner_check({'body': 'Owner check: from the PR', 'issues': []}), 'from the PR')
        self.assertIsNone(self.module.owner_check({'body': '', 'issues': []}))

    def test_an_owner_check_field_is_its_line_and_the_steps_under_it(self):
        field = self.module.check_field
        rows = [  # (body, the check)
            ('**Owner check:** open it.\n**Taken by:** nobody yet.', 'open it.'),
            ('**Owner check:** none needed. **Taken by:** none.', 'none needed.'),
            ('**Owner check:** tap **Add a Margin** and hold.', 'tap **Add a Margin** and hold.'),
            ('**Owner check:** after #551 is deployed:\n1. Opt in.\n2. Play it.\n\n**Taken by:** none',
             'after #551 is deployed:\n1. Opt in.\n2. Play it.'),
            ('**Owner check:** open Safari:\n\n- go to a page\n- share it\n\nSplit from #144.',
             'open Safari:\n- go to a page\n- share it'),
            ('**Owner check:** open it.\n\n- an unrelated list', 'open it.'),
            ('**Owner check:** open it.\nRelated: #5', 'open it.'),
            ('**Owner check:** play it:\n- Expected: the Margin plays.\nRelated: #5',
             'play it:\n- Expected: the Margin plays.'),
            ('**Owner check:**\nOpen the Library.\nMore prose.', 'Open the Library.'),
            ('**Owner check:**\n1. Open the Library.\n2. Tap a row.', '1. Open the Library.\n2. Tap a row.'),
            ('**Owner check:** paste this:\n```\nHello\n\n- not a step\n```\n**Taken by:** x',
             'paste this:\n```\nHello\n\n- not a step\n```'),
            ('- **Owner check:** open it.\n- **Taken by:** none', 'open it.'),
            ('Closes #5\n\nOwner check: open the Library\n- tap a row\n\n## How\n- moved',
             'open the Library\n- tap a row'),
            ('**Owner check:** open it.\n---\n_Filed by a session_', 'open it.'),
            ('**Owner check**: open it.', 'open it.'),
            ('No check here.', None),
        ]
        for body, check in rows:
            with self.subTest(body=body):
                self.assertEqual(field(body), check)

    def test_the_check_shapes_threads_write(self):
        # #927: the 887c560 plan said "No phone checks were written" while #907, #854 and #180 had one.
        # Neighbouring inputs (#882): shapes that are checks, and look-alikes that aren't.
        field = self.module.check_field
        rows = [  # (body, the check)
            ('4. **Owner check (phone):** play an article.\n\n## Must not break', 'play an article.'),   # PR #907
            ('3. A test fails.\n4. Owner check: play an article.\n\n## Evidence', 'play an article.'),   # #854
            ('4. **Owner check:** play it.\n5. **Tier.** T1', 'play it.'),
            ('4. Owner check: play it:\n   1. Open it.\n   2. Tap play.\n5. The tests pass.',
             'play it:\n   1. Open it.\n   2. Tap play.'),
            ('- Owner check: open the Library.\n- Done.', 'open the Library.'),
            ('**Phone check:** record two Margins.\n\n---\n_Generated_', 'record two Margins.'),       # #180
            ('**Owner Check:** open it.', 'open it.'),
            ('Owner check (phone): open it.', 'open it.'),
            ('## Owner check\n\nOn the next build, open the plan.\n\n## Tier', 'On the next build, open the plan.'),
            ('### Owner check (phone)\n1. Open it.\n2. Play it.\n### Taken by', '1. Open it.\n2. Play it.'),
            ('## Owner check\n\nNone this time: diagnostics only.\n\n\U0001f916 Generated with Claude Code\n\nhttps://x',
             'None this time: diagnostics only.'),                                                         # PR #811
            ('## Owner check\nopen it:\n\n- tap a row\n\nSplit from #5.', 'open it:\n- tap a row'),
            ('4. Owner check:\n1. Open it.\n2. Tap play.\n5. The tests pass.', '1. Open it.\n2. Tap play.'),
            ('4. **Owner check:** open the app:\n1. Tap play.\n2. Look.\n5. Tier T1', 'open the app:\n1. Tap play.\n2. Look.'),
            ('## Owner check: play it for a minute.\n\n## Tier', 'play it for a minute.'),
            ('## Owner check: none\nThe change is only in diagnostics.', 'none'),
            ('I think **Phone check** is useless', None),
            ('Phone check on build `6360767`, step 2: not exercised.', None),                              # #288
            ("For your phone check once it's in Build 30: import a packet.", None),                        # #158
            ('No app test drives it. The phone check covers that.', None),                                  # PR #907
            ('The PR adds a watchdog. Owner check: on a PDF, any silence clears.', None),                  # #288
            ('## Owner checks we skipped\nnone', None),
            ('**Phone check on build:** x', None),
        ]
        for body, check in rows:
            with self.subTest(body=body):
                self.assertEqual(field(body), check)

    def test_steps_and_expected_written_as_headings(self):
        # #854: "## Steps" heading with numbered steps, then a bold Expected. #180: both headings.
        steps = {'body': '## Steps\n1. Play an article.\n2. Swipe away.\n\n**Expected:** it keeps playing.\n'
                         '**Actual:** silence.\n\n## Likely cause\nx'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [steps]}),
                         '1. Play an article.\n2. Swipe away.\nExpected: it keeps playing.')
        both = {'body': '## Steps (owner, iPhone)\n1. Record a Margin.\n\n## Evidence\nlogs\n\n## Expected\n'
                        'Playback resumes.\n\n## Acceptance criteria\n- x'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [both]}),
                         '1. Record a Margin.\nExpected: Playback resumes.')

    def test_the_newest_check_in_an_issues_comments_wins(self):
        def issue(body, *comments):
            return {'number': 5, 'body': body, 'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': c} for c in comments]}}
        check = self.module.owner_check
        written = issue('**Owner check:** the old check.', '**Phone check:** the first.', 'Merged in #907.',
                        '**Phone check:** the newest.\n\n---\n_Generated_')
        self.assertEqual(check({'body': 'Owner check: the PR\'s.', 'issues': [written]}), 'the newest.')
        self.assertEqual(check({'body': '', 'issues': [issue('**Owner check:** the body.', 'Fixed on next.')]}),
                         'the body.')
        # #288: a later comment takes it off the plans, whatever the body or the PR says.
        off = issue('x', 'Owner check: on a PDF, any silence clears.',
                    'Phone check on build `6360767`: not exercised.\n\nLeave this off the owner\'s plans until it '
                    'shows up in diagnostics.')
        self.assertIsNone(check({'body': '**Owner check:** play a PDF.', 'issues': [off]}))
        self.assertTrue(self.module.says_no_check({'body': '**Owner check:** play a PDF.', 'issues': [off]}))
        none = issue('**Owner check:** play it.', '**Owner check:** none (it needs the app deleted first).')
        self.assertIsNone(check({'body': '', 'issues': [none]}))
        again = issue('x', '**Owner check:** none.', '**Phone check:** it can be checked now: play it.')
        self.assertEqual(check({'body': '', 'issues': [again]}), 'it can be checked now: play it.')

    def test_a_strangers_comment_never_changes_the_owners_plan(self):
        """#1822: "Owner check: none" or "Merged in #N" from a stranger must not take a fix off the plan."""
        def node(body, who='OWNER'):
            return {'authorAssociation': who, 'author': {'login': 'x'}, 'body': body}
        issue = {'number': 5, 'body': '**Owner check:** play it.',
                 'comments': {'nodes': [node('**Owner check:** none.', 'NONE'),
                                        node('Leave this off the owner\'s plans.', 'CONTRIBUTOR'),
                                        node('Merged in #907.', 'FIRST_TIME_CONTRIBUTOR')]}}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [issue]}), 'play it.')
        self.assertFalse(self.module.says_no_check({'body': '', 'issues': [issue]}))
        self.assertEqual(self.module.trusted_nodes(issue), [])
        issue['comments']['nodes'].append(node('**Owner check:** none.'))
        self.assertIsNone(self.module.owner_check({'body': '', 'issues': [issue]}))

    def test_a_comment_names_the_fix_only_when_it_says_so(self):
        found = self.module.FIXED_IN.findall
        text = 'Merged in #907; not fixed by PR #300 yet. PR #257 (merged as 4446e90). Related: PR #9, see #12.'
        self.assertEqual([a or b for a, b in found(text)], ['907', '257'])

    def test_an_issue_with_a_check_in_the_pr_body_is_still_a_check(self):
        # The issue body says none, the PR body has a real check: the main plan lists it, so must this section.
        issue = {'number': 5, 'body': '**Owner check:** none.', 'comments': {'nodes': []},
                 'timelineItems': {'nodes': []}, 'labels': {'nodes': []}}
        pr = {'number': 50, 'title': 'Fix (#5)', 'body': 'Owner check: play it.', 'url': 'u', 'merged': True}
        issue['timelineItems']['nodes'] = [{'source': pr}]
        fixes = self.module.waiting_fixes([issue], {50}, set())
        self.assertEqual([(f['check'], f['none']) for f in fixes], [('play it.', False)])
        # Two linked issues: one comment says none, the other gives a check: the check stands.
        both = {'issues': [{'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': 'Owner check: none.'}]}},
                           {'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': 'Phone check: play it.'}]}}], 'body': ''}
        self.assertFalse(self.module.taken_off(both))

    def test_ways_of_saying_there_is_no_check(self):
        none = self.module.NO_CHECK
        for text in ('none.', 'None this time: diagnostics only.', 'none needed.', 'Nothing yet.', 'n/a',
                     'none (needs the app deleted)',
                     # #1193: #177 said "none now; #178's journey covers the paid-feed case" and reached the plan
                     "none now; #178's journey covers the paid-feed case on the phone.", 'None now.',
                     'none at the moment', 'none currently', 'None right now.', 'none for now', 'none yet',
                     'not needed', 'Not needed.', 'no owner check', 'No owner check needed.', 'no phone check.',
                     'None needed for now.', 'none needed right now', 'none required', 'none at all.',
                     'none at this time', 'no check', 'No check needed.'):
            with self.subTest(text=text):
                self.assertTrue(none.match(text))
        for text in ('Nothing plays twice after a call.', 'None of the Margins move when you seek.',
                     'Nonetheless, play it.', 'None nowhere near the end: skip to the last chapter.',
                     'Not needed offline? Turn Wi-Fi off and play it.', 'No owner checkpoint here, open it.',
                     'Nowadays the title reads wrong.', 'Nothing at all plays after the call.',
                     'None required fields stay empty.', 'No checkmark shows.'):
            with self.subTest(text=text):
                self.assertFalse(none.match(text))

    def test_bug_report_steps_stand_in_for_a_missing_owner_check(self):
        issue = {'body': '**Steps:** open an article.\n**Expected:** a label that fits.\n'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [issue]}),
                         'open an article. Expected: a label that fits.')
        # #585 (#847 review): the action was step 2, and only step 1 reached the plan.
        numbered = {'body': '**Steps**\n1. Library, with items listed.\n2. Swipe the top row and Complete it.\n\n'
                            '**Expected:** the row slides out.\n\n**Actual:** it stays.'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [numbered]}),
                         '1. Library, with items listed.\n2. Swipe the top row and Complete it.\n'
                         'Expected: the row slides out.')


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
            return ''.join(json.dumps({'body': c['body'], 'author_association': 'OWNER',
                                       'user': c.get('user') or {'login': 'uncomposed'}}, ensure_ascii=False) + '\n'
                           for c in self.RECORDED)
        self.module.gh = gh

    def test_the_integration_report_on_184_for_the_commit_is_found(self):
        self.assertEqual(self.module.latest_verdict('828597e7' + '0' * 32), 'Lane report integration-828597e — PASS')
        self.assertEqual(self.calls[0][1], 'repos/Spoken-Margins/spoken-margins-native/issues/184/comments')

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
        reads = [call for call in self.calls if call[1].endswith('/issues/184/comments')]
        self.assertEqual(len(reads), 1)  # one read of #184 for both lines

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

    # #1465: the integration run's PASS is app tests only; the plan says what else was or wasn't tested.
    MIXED = {'body': "```text\nLane report integration-828597e — PASS\ncommit 828597e7 (next's tip) · integration run: "
                     '--plan app · 11:09–11:25 local, 2026-10-12\nrun by: Test Desk\nran:\n'
                     '  1. --plan app: 566 passed, 0 failed, 0 skipped  ← verdict input\n'
                     '  scripted journeys (probation, not verdict input): J1Tests/testOpen failed, J4Tests/testPlay passed\n'
                     'failing: \nflaky: none this run\ncrashes: none recorded\n'
                     "not run: agent-driven journeys (they need an attended session)\n"
                     "not verified (owner's phone): audible content, Bluetooth\nevidence: /mac/evidence\n```\n\n"
                     '828597e is the current phone candidate: app tests passed; scripted journeys failed '
                     '(testOpen); attended journeys not run.'}

    def outcomes(self, recorded):
        plan = self.plan_with(recorded)
        section = plan.split('## What was tested on this commit', 1)[1].split('\n## ', 1)[0]
        return plan, {line[2:].split(':', 1)[0]: line for line in section.splitlines() if line.startswith('- ')}

    def test_each_kind_of_check_gets_its_own_outcome_for_the_commit(self):
        _, got = self.outcomes([self.MIXED])
        self.assertIn('**pass** (1. --plan app: 566 passed', got['App tests'])
        self.assertIn('**pass**', got['Release device build'])
        self.assertIn('**fail** (J1Tests/testOpen failed, J4Tests/testPlay passed)', got['Scripted journeys'])
        self.assertIn('**not run** (agent-driven journeys need an attended session)', got['Attended journeys'])
        self.assertIn('**not run**', got['Upgrade from the last shipped build'])
        self.assertIn('**not run** (yours', got['Phone checks'])

    def test_a_unit_test_pass_with_journeys_failed_keeps_both_exclusions_visible(self):
        plan, _ = self.outcomes([self.MIXED])
        self.assertIn("- not run: agent-driven journeys (they need an attended session)", plan)
        self.assertIn("- not verified (owner's phone): audible content, Bluetooth", plan)

    def test_a_unit_test_pass_with_journeys_not_run_says_not_run(self):
        quiet = {'body': self.MIXED['body'].replace(
            '  scripted journeys (probation, not verdict input): J1Tests/testOpen failed, J4Tests/testPlay passed\n', '')}
        _, got = self.outcomes([quiet])
        self.assertIn('**not run** (the integration report lists no scripted journeys)', got['Scripted journeys'])
        _, got = self.outcomes([{'body': self.MIXED['body'].replace('J1Tests/testOpen failed, J4Tests/testPlay passed',
                                                                    'J1Tests/testOpen not_run')}])
        self.assertIn('**not run**', got['Scripted journeys'])

    def test_failing_tests_and_the_attended_verdict_reach_the_plan(self):
        failing = {'body': self.MIXED['body'].replace('PASS', 'FAIL', 1).replace('failing: \n', 'failing: AppTests/testX\n')}
        attended = {'body': '```text\nLane report journeys-828597e — FAIL\ncommit 828597e7\nfailing: J4 step 3\n```'}
        plan, got = self.outcomes([failing, attended])
        self.assertIn('**fail**', got['App tests'])
        self.assertIn('**fail** (Lane report journeys-828597e — FAIL)', got['Attended journeys'])
        self.assertIn('- failing: AppTests/testX', plan)
        self.assertIn('- failing: J4 step 3', plan)

    def report_with(self, extra, verdict='PASS'):
        body = self.MIXED['body'].replace('PASS', verdict, 1).replace('failing: \n', '')
        return {'body': body.replace('flaky: none this run\n', extra + 'flaky: none this run\n')}

    def test_an_upgrade_line_is_a_pass_or_fail_only_when_it_says_so(self):
        for line, status in (('upgrade: passed (Build 30 library opened)', 'pass'), ('upgrade: FAILED (database)', 'fail'),
                             ('upgrade: not run (no Build 29 library)', 'not run'), ('upgrade: skipped', 'not run'),
                             ('upgrade: blocked', 'not run'), ('upgrade: 0 failed', 'not run'),
                             ('upgrade: unclear', 'not run')):
            _, got = self.outcomes([self.report_with(line + '\n')])
            self.assertIn(f'**{status}**', got['Upgrade from the last shipped build'], line)

    def test_journeys_that_did_not_all_run_are_not_a_pass(self):
        partial = {'body': self.MIXED['body'].replace('J1Tests/testOpen failed, J4Tests/testPlay passed',
                                                      'J1Tests/testOpen passed, J4Tests/testPlay not_run')}
        _, got = self.outcomes([partial])
        self.assertIn('**not run**', got['Scripted journeys'])

    def test_an_inconclusive_run_proves_no_scripted_journey(self):
        _, got = self.outcomes([self.report_with('', verdict='INCONCLUSIVE')])
        self.assertIn('**not run (inconclusive)**', got['App tests'])
        self.assertIn('**not run** (the integration run did not finish)', got['Scripted journeys'])

    def test_flakes_and_crashes_reach_the_plan_but_empty_lines_do_not(self):
        body = self.MIXED['body'].replace('flaky: none this run', 'flaky: AppTests/testSlow').replace(
            'crashes: none recorded', 'crashes: SpokenMarginsApp-2026-10-12.ips').replace('failing: \n', 'failing: none\n')
        plan, _ = self.outcomes([{'body': body}])
        self.assertIn('- flaky: AppTests/testSlow', plan)
        self.assertIn('- crashes: SpokenMarginsApp-2026-10-12.ips', plan)
        self.assertNotIn('- failing:', plan)
        plan, _ = self.outcomes([self.MIXED])
        self.assertNotIn('- flaky:', plan)
        self.assertNotIn('- crashes:', plan)

    def test_a_commit_with_no_report_has_every_check_not_run(self):
        _, got = self.outcomes([])
        for kind in ('App tests', 'Scripted journeys', 'Attended journeys', 'Upgrade from the last shipped build'):
            self.assertIn('**not run**', got[kind], kind)

    def test_a_report_for_another_commit_is_not_this_commits_record(self):
        other = {'body': self.MIXED['body'].replace('828597e', '1234567')}
        _, got = self.outcomes([other])
        self.assertIn('**not run** (no integration report for this commit)', got['App tests'])

    def test_without_github_the_outcomes_are_unknown_not_not_run(self):
        self.module.gh = lambda *args: None
        self.module.plan_base = lambda sha: (None, 'the start')
        self.module.merged_prs = lambda base, sha: {}
        with tempfile.TemporaryDirectory() as folder:
            plan = self.module.write_plan(Path(folder), '828597e7' + '0' * 32, 'host tests').read_text()
        self.assertIn('- App tests: **unknown**', plan)

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
        module.fetch_waiting = lambda: []
        with tempfile.TemporaryDirectory() as folder:
            plan = module.write_plan(Path(folder), 'a' * 40, 'host tests').read_text()
        self.assertEqual(plan.count('Follow a site with a feed and one without.'), 1, plan)
        self.assertIn('[PR #330](https://example/pr/330), [PR #300](https://example/pr/300), '
                      '[issue #80](https://example/issue/80)', plan)
        self.assertIn('1. **Follow sites without a feed** (found on your phone)', plan)
        self.assertIn('2. **Library wording**', plan)
        self.assertNotIn('3. ', plan)

    def write(self, prs, items=None, built=(), waiting=(), built_prs=()):
        module = self.module
        module.plan_base = lambda sha: (None, 'the start')
        module.merged_prs = lambda base, sha: {n: f'Merge pull request #{n}' for n in prs}
        module.fetch_prs = lambda numbers: prs
        module.fetch_waiting = lambda: None if waiting is None else list(waiting)
        module.build_prs = lambda sha: set(built_prs)
        module.fetch_items = lambda numbers: {n: item for n, item in (items or {}).items() if n in numbers}
        module.built_numbers = lambda sha: set(built)
        module.report_comments = lambda: []
        printed = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(printed):
            plan = module.write_plan(Path(folder), 'a' * 40, 'host tests').read_text()
        self.printed = printed.getvalue()
        return plan

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
        self.assertNotIn('Voice keeps going', ten_minutes)  # found on the phone, but nothing says how to check it (#847)
        self.assertNotIn('storage ledger', ten_minutes)
        self.assertNotIn('closing notes', ten_minutes)
        unchecked = plan.split('## Also changed (no phone check written)')[1].split('Behind the scenes')[0]
        self.assertIn('- Take the rendered speech cache out of the offline storage ledger ([#366]', unchecked)
        self.assertIn('- Article import: give closing notes one chapter ([#497]', unchecked)
        self.assertIn('- Voice keeps going after a call (found on your phone) ([#401]', unchecked)
        self.assertNotIn('Linux', plan)
        self.assertIn('5 pull requests merged; 4 change something you see or hear.', plan)
        self.assertNotIn('repeat what you did', plan)
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
        self.assertIn("- Diagnostics: stop reporting the previous item's failure on a new item (found on your phone) ([#494]",
                      unchecked)

    def test_a_phone_found_bug_with_no_written_check_asks_for_one(self):
        # The f0f4c1f plan (#847): steps 6 and 8 said "repeat what you did when you found it", which sent the
        # owner back to the issue to rediscover his own steps and content.
        voice = self.pr(744, 'Voice keeps going after a call', [
            {'number': 90, 'title': 'Voice stops', 'url': 'https://example/issue/90', 'body': 'It stopped.',
             'labels': {'nodes': [{'name': 'found-on-phone'}]}}])
        diagnostics = self.pr(494, 'Diagnostics: name the failing item', [self.issue(283, 'none.', phone=True)])
        library = self.pr(280, 'Library wording', [self.issue(81, 'Read the Library rows.')])
        plan = self.write({744: voice, 494: diagnostics, 280: library})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertNotIn('repeat what you did', plan)
        self.assertNotIn('Voice keeps going', ten_minutes)
        self.assertIn('1. **Library wording**', ten_minutes)
        unchecked = plan.split('## Also changed (no phone check written)')[1]
        self.assertIn('- Voice keeps going after a call (found on your phone) ([#744]', unchecked)
        self.assertIn('Owner check', self.printed)
        self.assertIn('#90', self.printed)
        self.assertNotIn('#283', self.printed)  # it says "Owner check: none", so it needs no line
        self.assertNotIn('#81', self.printed)

    def test_a_check_that_waits_on_an_open_issue_is_not_in_the_ten_minutes(self):
        # The f0f4c1f plan (#847): step 2 asked for something that needs #547, which was still open.
        publisher = self.pr(809, 'Publisher audio: show the source', [
            self.issue(600, 'after #547 is also on the phone, open a BBC article: it plays the publisher audio.')])
        library = self.pr(280, 'Library wording', [self.issue(81, 'Read the Library rows. (Fixed in #279.)')])
        items = {547: {'__typename': 'Issue', 'number': 547, 'title': 'Play publisher audio by default',
                       'url': 'https://example/issue/547', 'state': 'OPEN', 'labels': {'nodes': [{'name': 'ready'}]}},
                 279: {'__typename': 'PullRequest', 'number': 279, 'title': 'Library rows',
                       'url': 'https://example/pr/279', 'state': 'MERGED'}}
        plan = self.write({809: publisher, 280: library}, items=items, built={279})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertNotIn('BBC', ten_minutes)
        self.assertIn('1. **Library wording**', ten_minutes)
        self.assertNotIn('2. ', ten_minutes)
        waiting = plan.split('## Waiting on another change')[1].split('## ')[0]
        self.assertIn('- Publisher audio: show the source ([#809]', waiting)
        alone = self.write({809: publisher}, items=items)
        self.assertIn('Nothing is ready to check on the phone yet', alone)
        self.assertNotIn('Nothing a listener would notice', alone)
        self.assertIn('[#547](https://example/issue/547)', waiting)
        self.assertIn('Play publisher audio by default', waiting)

    def test_a_check_that_asks_for_a_file_it_does_not_supply_waits_for_one(self):
        # The 8065265 plan (#1038): "import a book PDF that has bookmarks" with no PDF; the owner had nothing
        # to test with. A check with a link or a repo file to attach still goes in.
        outline = self.pr(376, 'PDF outline chapters', [self.issue(
            347, 'import a book PDF that has bookmarks but no printed chapter headings.', phone=True)])
        arxiv = self.pr(758, 'Add arXiv PDFs', [self.issue(
            759, 'Library > + > Link, paste `https://arxiv.org/pdf/2608.09666`, Add.')])
        stamp = {'number': 162, 'title': 'PDF download stamp read aloud', 'url': 'https://example/issue/162',
                 'state': 'OPEN', 'createdAt': '2026-09-25T00:00:00Z', 'milestone': None,
                 'labels': {'nodes': [{'name': 'status: needs-human-validation'}]},
                 'body': '**Owner check:** import a PDF whose footer has a download stamp, then listen.\n',
                 'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': 'Merged in #600.'}]}, 'timelineItems': {'nodes': []}}
        plan = self.write({376: outline, 758: arxiv}, waiting=[stamp], built_prs={600})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertIn('1. **Add arXiv PDFs**', ten_minutes)
        self.assertNotIn('bookmarks', ten_minutes)
        self.assertNotIn('Still waiting on your check', plan)
        waiting = plan.split('## Waiting on another change or a test file')[1].split('## ')[0]
        self.assertIn('- PDF outline chapters (found on your phone) ([#376]', waiting)
        self.assertIn(': needs a test PDF, not supplied yet', waiting)
        also = plan.split('## Also waiting on your check')[1]
        self.assertIn('- PDF download stamp read aloud ([#162](https://example/issue/162), [#600]', also)
        self.assertIn(': needs a test PDF, not supplied yet', also)
        self.assertIn('#347, #162', self.printed)
        self.assertNotIn('#759', self.printed)

    def test_which_checks_lack_the_file_they_ask_for(self):
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                return subprocess.run(['git', *args], cwd=repo, check=True, capture_output=True,
                                      text=True).stdout.strip()
            git('init', '-q')
            files = Path(repo) / 'TestPlans' / 'phone-files'
            files.mkdir(parents=True)
            (files / 'footer-stamp-test.pdf').write_bytes(b'%PDF-1.4')
            git('add', '-A')
            git('-c', 'user.email=t@example.com', '-c', 'user.name=T', 'commit', '-q', '-m', 'pdf')
            sha = git('rev-parse', 'HEAD')
            with unittest.mock.patch.dict(os.environ, {'SM_PHONE_REPO': repo}):
                module = load_phone_build()
            rows = [  # (check, the file kind it lacks, or None)
                ('Import a PDF whose footer has a stamp, then listen.', 'PDF'),
                ('import two pdfs and compare them', 'PDF'),
                ('Open the EPUB and play chapter 2.', 'EPUB'),
                ('Import an audiobook with chapters.', 'audiobook'),
                ('AirDrop the packet to the phone and import it.', 'packet'),
                ('open `Hollywood-Was-Cooked.spokenmargins` and tap Import', 'packet'),
                ('Open `TestPlans/phone-files/footer-stamp-test.pdf` from Files, then listen.', None),
                ('Open `TestPlans/phone-files/missing.pdf` from Files.', 'PDF'),  # named, but not in the commit
                ('Open <https://arxiv.org/pdf/2608.09666> in Safari, Share, Spoken Margins.', None),
                ('Open https://example.org/book.epub in Safari.', None),
                ('import a PDF once https://github.com/uncomposed/spoken-margins-native/issues/547 lands', 'PDF'),
                ('import a PDF once https://GitHub.com/Spoken-Margins/Spoken-Margins-Native/pull/547 lands', 'PDF'),
                ('Play a podcast and tap Add Margin.', None),
                ('Read the PDFKit-backed reader page; nothing to import.', None),  # a word, not a file
                ('', None),
            ]
            for check, lacks in rows:
                with self.subTest(check=check):
                    self.assertEqual(module.missing_material(check, sha), lacks)

    def test_one_unknown_number_does_not_hide_the_others(self):
        # gh fails a whole GraphQL query when one alias names no issue or PR (#847 review).
        module = self.module

        def graphql(fields):
            if any('9999' in query for query in fields.values()):
                return {}
            return {alias: {'__typename': 'Issue', 'number': int(alias[1:]), 'state': 'OPEN'} for alias in fields}
        module.graphql = graphql
        self.assertEqual(sorted(module.fetch_items([547, 9999, 548])), [547, 548])

    def test_what_counts_as_a_prerequisite_still_waiting(self):
        def issue(state='OPEN', *names):
            return {'__typename': 'Issue', 'number': 547, 'title': 'T', 'url': 'u', 'state': state,
                    'labels': {'nodes': [{'name': name} for name in names]}}

        def pr(state):
            return {'__typename': 'PullRequest', 'number': 547, 'title': 'T', 'url': 'u', 'state': state}
        rows = [  # (check, its own issues and PRs, numbers in the build's history, #547 on GitHub, waits?)
            ('after #547 is on the phone, play it', set(), set(), issue(), True),
            ('After #547, play it', set(), set(), issue('OPEN', 'status: needs-human-validation'), False),
            ('after #547 is on the phone, play it', set(), set(), issue('CLOSED'), False),
            ('after #547 is on the phone, play it', set(), {547}, issue(), False),
            ('play it (this is #547)', {547}, set(), issue(), False),
            ('once #547 merges, play it', set(), set(), pr('OPEN'), True),
            ('once #547 merges, play it', set(), {547}, pr('MERGED'), False),
            ('once #547 merges, play it', set(), set(), pr('MERGED'), True),  # merged after this build
            ('once #547 merges, play it', set(), set(), pr('CLOSED'), False),
            ('after https://github.com/uncomposed/spoken-margins-native/issues/547 lands', set(), set(), issue(), True),
            ('after https://github.com/Spoken-Margins/spoken-margins-native/issues/547 lands', set(), set(), issue(), True),
            ('after https://github.com/spoken-margins/spoken-margins-native/issues/547 lands', set(), set(), issue(), True),
            ('after https://GitHub.com/SPOKEN-MARGINS/Spoken-Margins-Native/issues/547 lands', set(), set(), issue(), True),
            ('after #547 is on the phone, play it', set(), set(), None, False),  # GitHub didn't say: keep the check
            ('Build 29 still plays it; tap item 547', set(), set(), issue(), False),
        ]
        for check, own, built, item, waits in rows:
            with self.subTest(check=check, item=item and (item['__typename'], item['state'])):
                found = self.module.waiting_on(check, own, built, {547: item} if item else {})
                self.assertEqual(bool(found), waits)

    def test_a_check_carries_its_steps_and_links_in_the_step(self):
        # #552's check is "after #551 is deployed:" plus three numbered steps; only the first line reached
        # the plan (#847). #758's check names a URL in code, which no viewer makes tappable.
        steps = self.pr(552, 'Upload transcript maps', [self.issue(
            552, 'open Settings:\n1. Opt in.\n2. Play a public episode.\n\n**Taken by:** nobody yet.')])
        steps['issues'][0]['body'] = ('**Where:** cloud.\n**Owner check:** open Settings:\n1. Opt in.\n'
                                      '2. Play a public episode.\n\n**Taken by:** nobody yet.\n\nPart of #51.')
        arxiv = self.pr(758, 'Add arXiv PDFs', [self.issue(
            759, 'Library > + > Link, paste `https://arxiv.org/pdf/2608.09666`, Add. **Taken by:** none.')])
        plan = self.write({552: steps, 758: arxiv})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertIn('   - Check: open Settings:\n     1. Opt in.\n     2. Play a public episode.\n   - Links:',
                      ten_minutes)
        self.assertIn('paste <https://arxiv.org/pdf/2608.09666>, Add.\n', ten_minutes)
        self.assertNotIn('Taken by', plan)
        self.assertNotIn('Part of', plan)

    def test_a_repo_file_named_in_a_check_comes_with_the_plan(self):
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                return subprocess.run(['git', *args], cwd=repo, check=True, capture_output=True,
                                      text=True).stdout.strip()
            git('init', '-q')
            git('-c', 'user.email=t@example.com', '-c', 'user.name=T', 'commit', '-q', '--allow-empty', '-m', 'base')
            fixtures = Path(repo) / 'Contracts' / 'fixtures'
            fixtures.mkdir(parents=True)
            (fixtures / 'two-margins.spokenmargins').write_bytes(b'PK\x03\x04 packet')
            git('add', '-A')
            git('-c', 'user.email=t@example.com', '-c', 'user.name=T', 'commit', '-q', '-m', 'packet')
            sha = git('rev-parse', 'HEAD')
            (fixtures / 'two-margins.spokenmargins').write_bytes(b'changed after the build')
            with unittest.mock.patch.dict(os.environ, {'SM_PHONE_REPO': repo}):
                module = load_phone_build()
            module.plan_base = lambda target: (None, 'the start')
            module.merged_prs = lambda base, target: {500: 'Merge pull request #500'}
            module.fetch_prs = lambda numbers: {500: self.pr(500, 'Import shared Margins', [self.issue(
                501, 'open `Contracts/fixtures/two-margins.spokenmargins` from Files; both Margins import. '
                     '`Contracts/fixtures/missing.spokenmargins` and `Contracts/fixtures` are not files.')])}
            module.report_comments = lambda: []
            module.fetch_waiting = lambda: []
            with tempfile.TemporaryDirectory() as folder:
                plan = module.write_plan(Path(folder), sha, 'host tests').read_text()
                files = sorted(p.name for p in (Path(folder) / 'files').iterdir())
                copied = (Path(folder) / 'files' / 'two-margins.spokenmargins').read_bytes()
                (Path(folder) / 'files' / 'stale.pdf').write_text('from an older plan')
                module.write_plan(Path(folder), sha, 'host tests')
                rewritten = sorted(p.name for p in (Path(folder) / 'files').iterdir())
        self.assertEqual(files, ['two-margins.spokenmargins'])
        self.assertEqual(copied, b'PK\x03\x04 packet')  # as built, not as the checkout is now
        self.assertEqual(rewritten, ['two-margins.spokenmargins'])
        self.assertIn(f'   - File: `two-margins.spokenmargins` comes with this plan. On the phone: Files > iCloud '
                      f'Drive > Spoken Margins test plans > Test plan {sha[:7]} files.', plan)
        self.assertNotIn('missing.spokenmargins` comes', plan)

    def test_the_plans_files_go_to_icloud_drive_and_old_ones_leave(self):
        with tempfile.TemporaryDirectory() as tmp:
            phone, icloud = Path(tmp) / 'phone', Path(tmp) / 'CloudDocs' / 'plans'
            sha, kept, gone = 'c' * 40, 'b' * 7, 'a' * 7
            build = phone / f'20261007-120000-{sha[:7]}'
            (build / 'files').mkdir(parents=True)
            (build / 'files' / 'two-margins.spokenmargins').write_bytes(b'packet')
            (phone / f'20261006-120000-{kept}').mkdir()     # built, not installed yet: its files stay
            for sha7 in (sha[:7], kept, gone, 'd' * 7):
                (icloud / f'Test plan {sha7} files').mkdir(parents=True)
            (icloud / f'Test plan {sha[:7]} files' / 'stale.pdf').write_text('from a rewritten plan')
            (icloud / f'Test plan {"d" * 7}.md').write_text('installed, its plan still here: its files stay')
            (icloud / 'Test plan old files').mkdir()  # the owner's own folder: never ours to delete
            with unittest.mock.patch.dict(os.environ, {'SM_PHONE_DIR': str(phone), 'SM_PHONE_ICLOUD': str(icloud)}):
                self.module.share_files(build, sha)
            names = sorted(p.name for p in icloud.iterdir())
            shared = sorted(p.name for p in (icloud / f'Test plan {sha[:7]} files').iterdir())
        self.assertEqual(shared, ['two-margins.spokenmargins'])
        self.assertEqual(names, [f'Test plan {kept} files', f'Test plan {sha[:7]} files',
                                 f'Test plan {"d" * 7} files', f'Test plan {"d" * 7}.md', 'Test plan old files'])

    def test_without_icloud_drive_sharing_files_does_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'build' / 'files').mkdir(parents=True)
            icloud = Path(tmp) / 'no-icloud' / 'plans'
            with unittest.mock.patch.dict(os.environ, {'SM_PHONE_DIR': tmp, 'SM_PHONE_ICLOUD': str(icloud)}):
                self.module.share_files(Path(tmp) / 'build', 'c' * 40)
            self.assertFalse(icloud.parent.exists())

    @staticmethod
    def waiting(number, check=None, milestone='Build 30', phone=False, created='2026-09-01', prs=(), comments=()):
        """An open issue labelled `status: needs-human-validation`, as fetch_waiting reads it (#927)."""
        names = ['status: needs-human-validation'] + (['found-on-phone'] if phone else [])
        return {'number': number, 'title': f'Waiting {number}', 'url': f'https://example/issue/{number}',
                'body': f'**Owner check:** {check}\n' if check else 'It broke.', 'createdAt': created,
                'labels': {'nodes': [{'name': name} for name in names]},
                'milestone': {'title': milestone, 'state': 'OPEN'} if milestone else None,
                'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': body} for body in comments]},
                'timelineItems': {'nodes': [{'source': {'number': n, 'title': f'Fix it (#{number})', 'body': '',
                                                        'url': f'https://example/pr/{n}', 'merged': True}}
                                            for n in prs]}}

    def test_fixes_still_waiting_share_the_ten_minutes(self):
        # #927: the 887c560 plan listed only PRs merged since the last install, so ten Build 30 fixes
        # already on the phone, and still unchecked, never reached it.
        self.module.PLAN_CHECKS, self.module.ALSO_WAITING = 5, 3
        new = {280: self.pr(280, 'Library wording', [self.issue(81, 'Read the Library rows.')]),
               281: self.pr(281, 'Speak the banner', body='Owner check: trigger an error and hear it.'),
               282: self.pr(282, 'Chapter list', [self.issue(82, 'Open the chapter list.')])}
        waiting = [
            self.waiting(100, 'play the Build 31 thing.', milestone='Build 31', phone=True, prs=[500]),
            self.waiting(101, 'play the plain Build 30 thing.', created='2026-09-02', prs=[501]),
            self.waiting(102, 'play the newer phone bug.', phone=True, created='2026-09-03', prs=[502]),
            self.waiting(103, 'play the older phone bug.', phone=True, created='2026-08-30', prs=[503]),
            self.waiting(104, 'play the unmerged one.', phone=True, prs=[504]),       # its fix isn't in this build
            self.waiting(105, None, prs=[505]),                                        # no check written
            self.waiting(106, 'none (it needs the app deleted).', phone=True, prs=[506]),
            self.waiting(81, 'Read the Library rows.', prs=[280]),                     # already in the plan
            self.waiting(108, None, milestone='Build 31', created='2026-09-04',          # a direct merge names it
                         comments=['**Phone check:** open the merged thing.']),
            self.waiting(109, 'after #547 is on the phone, play it.', created='2026-09-05', prs=[509]),
        ]
        items = {547: {'__typename': 'Issue', 'number': 547, 'title': 'Publisher audio', 'state': 'OPEN',
                       'url': 'https://example/issue/547', 'labels': {'nodes': []}}}
        plan = self.write(new, items=items, built={108}, waiting=waiting, built_prs={500, 501, 502, 503, 505, 506,
                                                                                    509, 280})
        ten_minutes = plan.split('## Try these')[1].split('## Also waiting')[0]
        self.assertIn('3. **', ten_minutes)
        still = ten_minutes.split('## Still waiting on your check')[1]
        self.assertIn('4. **Waiting 103** (found on your phone)\n   - Check: play the older phone bug.\n'
                      '   - Links: [issue #103](https://example/issue/103), [PR #503](https://example/pr/503)', still)
        self.assertIn('5. **Waiting 102** (found on your phone)', still)
        self.assertNotIn('6. ', still)
        also = plan.split('## Also waiting on your check (not in the ten minutes)')[1].split('## ')[0]
        self.assertEqual([line[:13] for line in also.split('\n\n')[1].splitlines()],
                         ['- Waiting 101', '- Waiting 109', '- Waiting 100', '- and 1 more:'])
        self.assertIn('- Waiting 109 ([#109](https://example/issue/109), [#509](https://example/pr/509)): needs '
                      '[#547](https://example/issue/547) on your phone first', also)
        for gone in ('Waiting 104', 'Waiting 105', 'Waiting 106', 'Waiting 81', 'Waiting 108'):
            self.assertNotIn(gone, plan)
        self.assertIn('label%3A%22status%3A+needs-human-validation%22', also)
        self.assertIn('#105', self.printed)  # no check written: the run asks for one
        self.assertNotIn('#106', self.printed)  # it says none
        self.module.PLAN_CHECKS, self.module.ALSO_WAITING = 8, 10
        roomy = self.write(new, items=items, built={108}, waiting=waiting, built_prs={500, 501, 502, 503, 509, 280})
        self.assertIn('8. **Waiting 108**\n   - Check: open the merged thing.\n'
                      '   - Links: [issue #108](https://example/issue/108)\n', roomy)

    def test_held_milestones_wait_outside_the_ten_minutes(self):
        # fdda29c: a Later diagnostics fix led the plan and two Co-op Experience checks filled it, though co-op
        # work starts only after Solid Ground ships (AGENTS.md Current focus, owner 2026-10-08).
        later = self.issue(1682, 'Play an article until the phone is warm.', phone=True)
        later['milestone'] = {'title': 'Later', 'state': 'OPEN'}
        current = self.issue(1700, 'Open the Library and read the rows.')
        current['milestone'] = {'title': 'Solid Ground', 'state': 'OPEN'}
        mixed = self.issue(1701, 'Tap Play now on a Following entry.')
        mixed['milestone'] = {'title': 'Co-op Experience', 'state': 'OPEN'}
        new = {1710: self.pr(1710, 'Diagnostics: record why iOS ended the last run', [later]),
               1711: self.pr(1711, 'Library wording', [current]),
               1712: self.pr(1712, 'Play now from Following', [mixed, current])}
        waiting = [self.waiting(473, 'Reply to a friend and see it threaded.', milestone='Co-op Experience',
                                created='2026-09-01', prs=[1253]),
                   self.waiting(478, 'Long-press a Following entry and use Play now.', milestone=None,
                                created='2026-09-03', prs=[1316]),
                   self.waiting(1600, 'Play the Solid Ground thing.', milestone='Solid Ground',
                                created='2026-09-05', prs=[1601])]
        plan = self.write(new, waiting=waiting, built_prs={1253, 1316, 1601})
        ten_minutes = plan.split('## Try these')[1].split('## Also waiting')[0].split('## Waiting for')[0]
        self.assertNotIn('Diagnostics: record why', ten_minutes)
        self.assertIn('**Library wording**', ten_minutes)
        self.assertIn('Also in this change: Play now from Following', ten_minutes)  # one issue is current
        self.assertNotIn('Waiting 473', ten_minutes)
        still = ten_minutes.split('## Still waiting on your check')[1]
        self.assertLess(still.index('Waiting 1600'), still.index('Waiting 478'))  # current milestone first
        held = plan.split('## Waiting for a later milestone (not in the ten minutes)')[1].split('## ')[0]
        self.assertIn('- Diagnostics: record why iOS ended the last run (found on your phone) '
                      '([#1710](https://example/pr/1710)): waits for Later', held)
        also = plan.split('## Also waiting on your check (not in the ten minutes)')[1].split('## ')[0]
        self.assertIn('- Waiting 473 ([#473](https://example/issue/473), [#1253](https://example/pr/1253)): '
                      'waits for Co-op Experience', also)

    def test_with_nothing_new_to_check_the_waiting_fixes_lead(self):
        plan = self.write({366: self.pr(366, 'Take the rendered speech cache out of the offline storage ledger')},
                          waiting=[self.waiting(103, 'play the older phone bug.', prs=[503])], built_prs={503})
        self.assertNotIn('No phone checks were written for this build', plan)
        self.assertIn('No change new in this build has a phone check. The fixes below, from earlier builds, '
                      'still wait on yours.', plan)
        self.assertIn('1. **Waiting 103**', plan)
        self.assertIn('- Take the rendered speech cache', plan.split('## Also changed (no phone check written)')[1])

    def test_without_github_the_waiting_fixes_say_so(self):
        plan = self.write({280: self.pr(280, 'Library wording', [self.issue(81, 'Read the Library rows.')])},
                          waiting=None)
        self.assertIn('1. **Library wording**', plan)
        self.assertIn("GitHub could not be reached, so earlier fixes still waiting on your check aren't listed.", plan)
        self.assertNotIn('## Still waiting', plan)

    def test_the_887c560_checks_reach_the_plan(self):
        # #927 Done when 5, from the real bodies on 2026-10-07 (cut to the lines that matter).
        issue_854 = {'number': 854, 'title': 'Narration never starts if you leave the app while it is starting',
                     'url': 'https://example/issue/854', 'labels': {'nodes': [{'name': 'found-on-phone'}]},
                     'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': 'Merged in #907; waiting on owner\'s phone check.'}]},
                     'body': '## Steps\n1. Play a text article with the Supertonic voice.\n2. Record a Margin, tap '
                             'Save & resume, and swipe to another app straight away.\n\n**Expected:** narration '
                             'resumes in the background.\n**Actual:** silence.\n\n## Done when\n3. A test fails '
                             'without the fix.\n4. Owner check: play a text article, record a Margin, tap Save & '
                             'resume and swipe to another app immediately; narration continues within a few '
                             'seconds. Then repeat with pause, play and an immediate swipe away.\n'}
        pr_907 = self.pr(907, 'Keep narration starting when you leave the app right after Save & resume or play',
                         [issue_854], body='## Done when\n\n3. **A test fails without the fix.** I ran it.\n4. '
                         '**Owner check (phone):** play a text article with the Supertonic voice, record a Margin, '
                         'tap Save & resume and swipe to another app at once.\n\n## Must not break\n')
        issue_180 = self.waiting(180, phone=True, created='2026-09-26T00:00:00Z', comments=[
            'Fixed on `next`; needs your phone check.\n- PR #257 (merged as `4446e90`, fix `3d28610`): the watchdog.',
            '**Phone check:** on a freshly added article with Supertonic, record a Margin, then a second one about '
            '15 s later. After each, playback should resume by itself, even if it takes more than 10 s, and the Play '
            "button shouldn't come back.\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_"])
        issue_158 = self.waiting(158, created='2026-09-25T00:00:00Z', comments=[
            "Status: **verified**. For your phone check once it's in Build 30: open a podcast's Timeline.",
            "Spec pass: it landed through merge `134f29e` (\"Merge play-this-moment into next\"), a direct merge.\n\n"
            "**Phone check:** open a podcast's Timeline and tap someone's shared Margin. Their voice should land in a "
            'sensible spot, with an "approximate" label when the position isn\'t a verified match. If the clock '
            "sticks afterwards, that's #166.\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_"])
        items = {166: {'__typename': 'Issue', 'number': 166, 'title': 'Clock', 'url': 'https://example/issue/166',
                       'state': 'OPEN', 'labels': {'nodes': [{'name': 'status: needs-human-validation'}]}}}
        plan = self.write({907: pr_907}, items=items, built={158, 156, 159}, waiting=[issue_854, issue_180, issue_158],
                          built_prs={907, 257})
        self.assertIn('1. **Keep narration starting when you leave the app right after Save & resume or play** (found '
                      'on your phone)\n   - Check: play a text article, record a Margin, tap Save & resume and swipe '
                      'to another app immediately;', plan)
        still = plan.split('## Still waiting on your check')[1]
        self.assertIn('2. **Waiting 180** (found on your phone)\n   - Check: on a freshly added article with '
                      'Supertonic, record a Margin, then a second one', still)
        self.assertIn('[issue #180](https://example/issue/180), [PR #257](https://github.com/Spoken-Margins/'
                      'spoken-margins-native/pull/257)', still)
        self.assertIn("3. **Waiting 158**\n   - Check: open a podcast's Timeline and tap someone's shared Margin.",
                      still)
        self.assertNotIn('Generated by', plan)
        self.assertEqual(plan.count('Save & resume and swipe'), 1)  # #854 is #907's entry, not waiting twice

    def test_with_no_written_checks_the_plan_says_so(self):
        plan = self.write({366: self.pr(366, 'Take the rendered speech cache out of the offline storage ledger')})
        self.assertIn('No phone checks were written for this build', plan)
        self.assertNotIn('Use the app as usual', plan)
        self.assertNotIn('1. ', plan)


class PlanFaultTests(unittest.TestCase):
    """#1476: the c9f8bbc plan cost a ten-minute sitting. Lane procedures, a redesign filed under other titles,
    checks that don't say what to look for, and a named paper with no link."""

    PLAYBACK = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackScreen.swift'
    OTHER = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceLibraryScreen.swift'

    def setUp(self):
        self.module = load_phone_build()

    @staticmethod
    def pr(number, title, issues=(), body='', path=None):
        path = path or PlanFaultTests.OTHER
        return {'number': number, 'title': title, 'url': f'https://example/pr/{number}', 'body': body,
                'labels': {'nodes': []}, 'files': {'nodes': [{'path': path}]}, 'issues': list(issues)}

    @staticmethod
    def issue(number, check, title=None):
        return {'number': number, 'title': title or f'Issue {number}', 'url': f'https://example/issue/{number}',
                'body': f'**Owner check:** {check}\n', 'labels': {'nodes': []}}

    def write(self, prs, waiting=(), built_prs=()):
        module = self.module
        module.plan_base = lambda sha: (None, 'the start')
        module.merged_prs = lambda base, sha: {n: f'Merge pull request #{n}' for n in prs}
        module.fetch_prs = lambda numbers: prs
        module.fetch_waiting = lambda: list(waiting)
        module.build_prs = lambda sha: set(built_prs)
        module.fetch_items = lambda numbers: {}
        module.built_numbers = lambda sha: set()
        module.report_comments = lambda: []
        printed = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(printed):
            plan = module.write_plan(Path(folder), 'a' * 40, 'host tests').read_text()
        self.printed = printed.getvalue()
        return plan

    def test_accepted_restoration_is_absent_but_redesign_for_the_same_open_issue_remains(self):
        # #1475 stays open for #1551. Closing the whole issue would hide the new screen; leaving
        # acceptance only on the issue made #1482 appear beside the opposite change in the real plan.
        issue = self.issue(1475, 'Play an article and a podcast; switch Now, Timeline, Margins.')
        issue['state'] = 'OPEN'
        prs = {
            1551: self.pr(1551, 'Re-land the playback-screen redesign (#1475)', [issue], path=self.PLAYBACK),
            1549: self.pr(1549, 'Open Text at the playing sentence',
                          [self.issue(1547, 'Open More > Text at the playing sentence.')], path=self.PLAYBACK),
            1482: self.pr(1482, 'Restore the pre-redesign playback screen (#1475)', [issue], path=self.PLAYBACK),
        }
        plan = self.write(prs)
        self.assertNotIn('Restore the pre-redesign playback screen', plan)
        self.assertNotIn('[PR #1482]', plan)
        self.assertIn('Re-land the playback-screen redesign', plan)
        self.assertIn('Play an article and a podcast; switch Now, Timeline, Margins.', plan)
        self.assertIn('3 pull requests merged;', plan)

    def test_accepted_restoration_does_not_return_through_the_waiting_backlog(self):
        # A plan whose base is after #1482 has no new PR entry to filter. The same accepted check
        # must also stay out of the earlier-build backlog while #1475 is open.
        issue = RevertedPRTests.issue(1475, 'Restore the pre-redesign playback screen',
                                      [(1482, 'Restore the pre-redesign playback screen (#1475)')])
        plan = self.write({}, waiting=[issue], built_prs=[1482])
        self.assertNotIn('Restore the pre-redesign playback screen', plan)
        self.assertNotIn('Still waiting on your check', plan)

    def test_delegated_no_independent_check_is_not_a_phone_action(self):
        # The actual 437fbc9 plan offered this as step 4 even though #447's screen was reverted.
        # Retained SessionKit logic may still be listed, but "none beyond" is not an action.
        for check in ("none beyond #447's feel check.", 'None except #447’s phone check.',
                      'none other than #447.', 'none apart from #447.'):
            with self.subTest(check=check):
                issue = self.issue(448, check)
                pr = self.pr(1397, 'Preserve Timeline passage breaks across blank lines', [issue],
                             path='Packages/SessionKit/Sources/SessionKit/TimelineSourceContent.swift')
                plan = self.write({1397: pr})
                actions = plan.split('## Try these')[1].split('\n## ')[0]
                self.assertNotIn('Preserve Timeline passage breaks', actions)
                self.assertNotIn('Check: ' + check, plan)
                self.assertIn('## Also changed (no phone check written)', plan)

    def test_which_checks_the_owner_cannot_run(self):
        rows = [  # (check, refused)
            ('Run `scripts/xcodebuild-lane -project X.xcodeproj -configuration Release build` and see it succeed.', True),
            ('Run --plan app at 929b5ce on simulator F1E6BBFE and read the result.', True),
            ('Run --plan app and read the result.', True),
            ('Comment `/lane T3` on the PR.', True),
            ('Boot the simulator and open the Library.', True),
            ('Boot 1330F268-5C1B-4B07-9E37-0F6D2A3C41AB and open the Library.', True),
            ('Open build.log and find the failing test.', True),
            ('Look in artifacts/run-1 for the screenshot.', True),
            ('Run the app on `929b5ce`.', True),
            ('Run the app at commit 929b5ce.', True),
            ('Check out 929b5ce and build it.', True),
            ('Test with build 929b5ce.', True),
            ('Re-run the T3 lane on the PR.', True),
            ('Open the crash log.', True),
            ('Run pytest and read the output.', True),
            ('Install the build from 929b5ce1f2.', True),
            ('Run xcodebuild test.', True),
            ('Read the diagnostics field "supertonicOutputCheck".', True),
            ('Read the diagnostics screen: voice should say Supertonic.', True),   # an agent's job even with a result
            ('Read the AI Handoff export of the next test plan.', True),
            ('Read the AI Handoff export of the next test plan once.', True),
            ('Look through the exported log.', True),
            # fdda29c: the field came after the verb, in backticks, with diagnostics before it
            ('reproduce #1679 on Build 32, export diagnostics, and look for `app.previous_exit` naming a CPU '
             'or memory reason.', True),
            ('Look for `playback.stall_count` in the export.', True),
            ('Search diagnostics for the stall.', True),
            # fdda29c: #391's check only pointed at another step
            ('yes, the phone step above.', True),
            ('See the steps below.', True),
            ('Yes: Done when 4.', True),
            # neighbours the owner can run
            ('Settings > Version ends with `929b5ce`.', False),
            ('Open the Library at 2am and play the first item.', False),
            ('Play an item on iPad.', False),
            ('Check the app at deadbeef.', False),           # all letters: a word, not a commit
            ('Check the app at 1234567 words.', False),      # all digits: a number, not a commit
            ('Read the Library rows.', False),
            ('Read the AI Handoff export of the next test plan: the Margins come out in the order you made them, '
             'and each passage is printed once.', False),
            ('Settings > Version is at `929b5ce`.', False),
            ('Settings > Version shows 929b5ce and the build number.', False),
            ('Read the AI Handoff export; you will see two Margins.', False),
            ('Double-click the Desktop icon.', False),
            ('Tap Share Diagnostics and send the file to Claude.', False),
            ('Copy Privacy-Safe Diagnostics here, with a screenshot of Settings > Battery.', False),
            ('Look for the Waiting label on the second row.', False),
            ('Yes: play an article and hear the voice above the music.', False),
            ('Scroll to the row above and tap it.', False),
            ('', False),
        ]
        for check, refused in rows:
            with self.subTest(check=check):
                self.assertEqual(bool(self.module.unusable_check(check)), refused)

    def test_a_check_with_a_lane_procedure_is_not_in_the_ten_minutes_and_the_run_names_its_issue(self):
        # The c9f8bbc plan: #1453 asked for an xcodebuild-lane Release build, #1340 pasted a --plan app re-run.
        release = self.pr(1459, 'Release builds compile the share extension', [self.issue(
            1453, 'Run `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -configuration Release build`.')])
        rerun = self.pr(1352, 'Credit a followed source mid-playback', [self.issue(
            1340, 'Run --plan app at 929b5ce on simulator F1E6BBFE and read the result.')])
        fine = self.pr(1400, 'Library wording', [self.issue(1401, 'Read the Library rows.')])
        plan = self.write({1459: release, 1352: rerun, 1400: fine})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertIn('1. **Library wording**', ten_minutes)
        for text in ('xcodebuild', '--plan', 'simulator', '929b5ce'):
            self.assertNotIn(text, ten_minutes)
        unchecked = plan.split('## Also changed (no phone check written)')[1]
        self.assertIn('- Release builds compile the share extension (', unchecked)
        self.assertIn('- Credit a followed source mid-playback (', unchecked)
        self.assertIn('rewrite its "Owner check:" line: #1453 (', self.printed)
        self.assertIn('#1340 (', self.printed)
        self.assertNotIn('#1401', self.printed)

    def test_a_usable_check_in_the_pr_body_stands_in_for_a_refused_one_in_the_issue(self):
        pr = self.pr(1500, 'Library wording', [self.issue(1501, 'Run --plan app at 929b5ce.')],
                     body='**Owner check:** Open the Library and read the first row.\n')
        plan = self.write({1500: pr})
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertIn('Check: Open the Library and read the first row.', ten_minutes)
        self.assertNotIn('--plan', plan)

    def test_a_fix_waiting_on_a_lane_procedure_is_left_out_and_named(self):
        stuck = {'number': 1340, 'title': 'Credit a followed source', 'url': 'https://example/issue/1340',
                 'state': 'OPEN', 'createdAt': '2026-10-11T00:00:00Z', 'milestone': None,
                 'labels': {'nodes': [{'name': 'status: needs-human-validation'}]},
                 'body': '**Owner check:** Run --plan app at 929b5ce on simulator F1E6BBFE.\n',
                 'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': 'Merged in #1352.'}]}, 'timelineItems': {'nodes': []}}
        plan = self.write({}, waiting=[stuck], built_prs={1352})
        self.assertNotIn('Credit a followed source', plan)
        self.assertIn("can't be run on the phone", self.printed)
        self.assertIn('#1340 (', self.printed)
        self.assertNotIn('no "Owner check:" written', self.printed)

    def test_several_merges_to_one_screen_are_one_item_at_the_top_each_with_its_own_title(self):
        # The c9f8bbc plan filed the playback redesign under "Deliver feedback once across banner presentations"
        # and "Expose playback Margin stacks to VoiceOver".
        feedback = self.issue(430, 'Say if the banner speaks once.', title='Deliver feedback once across banner presentations')
        prs = {
            1355: self.pr(1355, 'Playback bar draws chapters and Margins', [self.issue(428, 'Drag the bar.')],
                          path=self.PLAYBACK),
            1446: self.pr(1446, 'Playback: clarify source labels and move preparation into More', [feedback],
                          path=self.PLAYBACK),
            1441: self.pr(1441, 'Deliver feedback once across banner presentations', [feedback]),
            1480: self.pr(1480, 'Playback shows the transcription status', [self.issue(431, 'Record a Margin.')],
                          path='App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackNowView.swift'),
            1400: self.pr(1400, 'Library wording', [self.issue(1401, 'Read the Library rows.')]),
        }
        plan = self.write(prs)
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertIn('\n1. **The playback screen changed** (3 changes)\n', ten_minutes)
        self.assertNotIn('Deliver feedback once across banner presentations', ten_minutes.split('\n2. ')[0])
        self.assertIn('Check: Open an article and a podcast and say if the playback screen is usable', ten_minutes)
        for title in ('Playback bar draws chapters and Margins',
                      'Playback: clarify source labels and move preparation into More',
                      'Playback shows the transcription status'):
            self.assertEqual(plan.count(f'- {title} ([PR #'), 1, title)
        # The banner PR shares issue #430 with the playback one, but keeps its own title and its own check.
        self.assertIn('2. **Deliver feedback once across banner presentations**', ten_minutes)
        self.assertIn('3. **Library wording**', ten_minutes)
        self.assertEqual(ten_minutes.count('Playback bar draws chapters'), 1)

    def test_the_folded_prs_keep_their_issue_links_and_checks_and_the_rest_are_numbered_after_them(self):
        prs = {n: self.pr(n, f'Playback change {n}', [self.issue(100 + n, f'Try thing {n}.')], path=self.PLAYBACK)
               for n in (1, 2, 3)}
        prs.update({n: self.pr(n, f'Library change {n}', [self.issue(100 + n, f'Try thing {n}.')])
                    for n in range(4, 14)})
        plan = self.write(prs)
        ten_minutes = plan.split('## Try these')[1].split('## ')[0]
        self.assertIn('     - Playback change 2 ([PR #2](https://example/pr/2), [issue #102](https://example/issue/102)): '
                      'Try thing 2.', ten_minutes)
        self.assertIn('\n2. **Library change 4**', ten_minutes)      # numbered after the screen item; 8 slots in all
        self.assertEqual(len(re.findall(r'(?m)^\d+\. \*\*', ten_minutes)), 8)
        self.assertEqual(len(re.findall(r'(?m)^- Library change', plan.split('## Also changed (not in')[1])), 3)

    def test_helpers_and_tests_under_the_playback_name_are_not_the_screen(self):
        helper = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackQualityPresentation.swift'
        prs = [self.pr(n, f'Playback {n}', path=helper) for n in (1, 2, 3)]
        self.assertEqual(self.module.screen_changes([[pr] for pr in prs])[0], [])

    def test_a_refused_check_is_named_even_when_a_usable_one_stands_in(self):
        pr = self.pr(1500, 'Library wording', [self.issue(1501, 'Run --plan app at 929b5ce.')],
                     body='**Owner check:** Open the Library and read the first row.\n')
        self.write({1500: pr})
        self.assertIn('#1501 (', self.printed)

    def test_two_merges_to_a_screen_are_not_a_redesign(self):
        prs = {1355: self.pr(1355, 'Playback bar draws chapters and Margins', [self.issue(428, 'Drag the bar.')],
                             path=self.PLAYBACK),
               1446: self.pr(1446, 'Playback: clarify source labels', [self.issue(430, 'Read the title.')],
                             path=self.PLAYBACK)}
        plan = self.write(prs)
        self.assertNotIn('screen changed', plan)
        self.assertIn('1. **Playback bar draws chapters and Margins**', plan)
        self.assertIn('2. **Playback: clarify source labels**', plan)

    def test_screen_changes_ignores_tests_and_other_screens(self):
        module = self.module
        tests = [self.pr(n, f'Playback test {n}', path='App/SpokenMarginsAppTests/PlaybackScreenTests.swift')
                 for n in (1, 2, 3)]
        other = [self.pr(n, f'Library {n}') for n in (4, 5, 6)]
        self.assertEqual(module.screen_changes([[pr] for pr in tests + other]), ([], [[pr] for pr in tests + other]))
        playback = [self.pr(n, f'Playback {n}', path=self.PLAYBACK) for n in (7, 8, 9)]
        groups, stay = module.screen_changes([[pr] for pr in other + playback])
        self.assertEqual([(g['screen'], [p['number'] for p in g['prs']]) for g in groups], [('playback screen', [7, 8, 9])])
        self.assertEqual([[p['number'] for p in entry] for entry in stay], [[4], [5], [6]])

    def test_prs_sharing_an_issue_each_keep_their_own_title(self):
        shared = self.issue(430, 'Say if the banner speaks once.')
        prs = {1441: self.pr(1441, 'Deliver feedback once across banner presentations', [shared]),
               1446: self.pr(1446, 'Source labels in More', [shared])}
        plan = self.write(prs)
        self.assertIn('   - Also in this change: Source labels in More ([PR #1446](https://example/pr/1446))', plan)
        unchecked = {1441: self.pr(1441, 'Deliver feedback once across banner presentations',
                                   [{**shared, 'body': 'Nothing.'}]),
                     1446: self.pr(1446, 'Source labels in More', [{**shared, 'body': 'Nothing.'}])}
        plan = self.write(unchecked)
        listed = plan.split('## Also changed (no phone check written)')[1]
        self.assertIn('- Deliver feedback once across banner presentations ([#1441]', listed)
        self.assertIn('- Source labels in More ([#1446]', listed)

    def test_a_check_that_names_a_document_without_supplying_it_waits_for_one(self):
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                return subprocess.run(['git', *args], cwd=repo, check=True, capture_output=True,
                                      text=True).stdout.strip()
            git('init', '-q')
            files = Path(repo) / 'TestPlans' / 'phone-files'
            files.mkdir(parents=True)
            (files / 'paper.txt').write_text('text')
            git('add', '-A')
            git('-c', 'user.email=t@example.com', '-c', 'user.name=T', 'commit', '-q', '-m', 'paper')
            sha = git('rev-parse', 'HEAD')
            with unittest.mock.patch.dict(os.environ, {'SM_PHONE_REPO': repo}):
                module = load_phone_build()
            rows = [  # (check, the kind it lacks, or None)
                ('Listen to the arXiv paper at 0.88x and say if the gaps are gone.', 'document'),
                ('Play the arXiv paper and listen to the gaps.', 'document'),
                ('Open this paper and listen.', 'document'),
                ('Listen to the paper for a minute.', 'document'),
                ('Listen to the arXiv paper: <https://arxiv.org/abs/2608.09666>.', None),
                ('Listen to the paper at https://example.org/paper.html.', None),
                ('Listen to `TestPlans/phone-files/paper.txt` from Files.', None),
                ('Library > + > Link, paste `https://arxiv.org/pdf/2608.09666`, Add.', None),
                ('Open a paper you already have and listen.', None),
                ('Tap Paperless in Settings.', None),
                ('Switch to the Paper theme in the reader.', None),
                ('Open the Books tab and pick the book you were reading.', None),
                ('Paste an arXiv URL into Library > Link and play it.', None),
                ('Import the PDF.', 'PDF'),
            ]
            for check, lacks in rows:
                with self.subTest(check=check):
                    self.assertEqual(module.missing_material(check, sha), lacks)

    def test_586_waits_in_the_plan_until_its_paper_is_linked(self):
        gaps = self.issue(586, 'Listen to the arXiv paper at 0.88x and say if the gaps between chunks are gone.')
        plan = self.write({586: self.pr(600, 'Close the gaps between chunks', [gaps])})
        self.assertNotIn('1. **Close the gaps', plan)
        waiting = plan.split('## Waiting on another change or a test file')[1].split('## ')[0]
        self.assertIn('- Close the gaps between chunks (', waiting)
        self.assertIn('needs a test document, not supplied yet', waiting)
        self.assertIn('#586', self.printed)
        linked = self.issue(586, 'Listen to the arXiv paper <https://arxiv.org/abs/2608.09666> at 0.88x and say if '
                                 'the gaps between chunks are gone.')
        plan = self.write({586: self.pr(600, 'Close the gaps between chunks', [linked])})
        self.assertIn('1. **Close the gaps between chunks**', plan)


class PassedChecksTests(unittest.TestCase):
    """#1100: the plan for 41a591e listed four checks the owner had already passed (#854, #537, #281, #223) and
    eight passed fixes under "Also changed". Their issues are closed after an owner pass."""
    pr, issue, write = (staticmethod(PlanGroupingTests.pr), staticmethod(PlanGroupingTests.issue),
                        PlanGroupingTests.write)

    def setUp(self):
        self.module = load_phone_build()

    def closed(self, number, check, phone=False):
        issue = self.issue(number, check, phone)
        issue['state'] = 'CLOSED'
        return issue

    def opened(self, number, check, phone=False):
        issue = self.issue(number, check, phone)
        issue['state'] = 'OPEN'
        return issue

    def prs(self):
        both = self.pr(906, 'Half passed', [self.closed(7, 'Hear the half.'), self.opened(8, 'Hear the other half.')])
        return {n: pr for n, pr in {
            901: self.pr(901, 'James keeps his voice', [self.closed(854, 'Hear James through numbers.')]),
            902: self.pr(902, 'Skim lands on the sentence', [self.closed(537, 'Skim twice.')]),
            903: self.pr(903, 'Speech settings wording', [self.closed(281, 'Read the settings page.')]),
            904: self.pr(904, 'Open fix', [self.opened(905, 'Hear the open fix.')]),
            905: self.pr(905, 'No issue linked', body='Owner check: look at the new banner.'),
            906: both,
            907: self.pr(907, 'Passed fix with no check written', [{
                **self.closed(223, 'x'), 'body': 'It always did this.', 'labels': {'nodes': []}}]),
        }.items()}

    def test_closed_issues_keep_their_changes_out_of_every_section(self):
        self.module.PLAN_CHECKS = 2  # so "Also changed (not in the ten minutes)" has entries too
        plan = self.write(self.prs())
        for passed in ('James keeps his voice', 'Skim lands on the sentence', 'Speech settings wording',
                       'Passed fix with no check written'):
            self.assertNotIn(passed, plan)
        for kept in ('Open fix', 'No issue linked', 'Half passed'):
            self.assertIn(kept, plan)
        self.assertIn('4 changes whose issues are already closed are left out.', plan)
        self.assertIn('7 pull requests merged; ', plan)  # the count of merges stays honest

    def test_the_closed_ones_are_gone_from_the_checks_and_the_unchecked_list_alike(self):
        plan = self.write(self.prs())
        ten_minutes = plan.split('## Try these')[1].split('\n## ')[0]
        self.assertEqual(ten_minutes.count('Links:'), 3, ten_minutes)  # Open fix, No issue linked, Half passed
        self.assertNotIn('## Also changed (no phone check written)', plan)  # the only unchecked one had passed
        self.assertNotIn('found on the phone but no "Owner check:" line', self.printed)  # nor asks for its check

    def test_a_follow_up_pr_merged_after_its_issue_closed_is_still_a_pass(self):
        # The real #223 (read from GitHub, 2026-10-08): closed 10-04 with the owner's pass; PR #578's follow-up
        # #677 merged on 10-05 ("Closes #223") and the owner confirmed it in a later comment on the closed issue.
        issue = self.closed(223, 'Share a Substack post.')
        issue['closedAt'] = '2026-10-04T16:31:31Z'
        first = self.pr(578, 'Fall back to the article extractor (#223)', [issue])
        first['mergedAt'] = '2026-10-01T15:38:45Z'
        follow_up = self.pr(677, 'Preserve article extractor errors for shared links (#223)', [issue])
        follow_up['mergedAt'] = '2026-10-05T15:00:10Z'
        self.assertTrue(self.module.passed_on_phone([follow_up, first]))
        plan = self.write({677: follow_up, 578: first})
        self.assertNotIn('extractor', plan)

    def test_a_closed_issue_that_keeps_a_validation_label_is_not_a_pass(self):
        # 2026-10-22: a merged fix closes its issue and the label stays, so closed no longer means "passed".
        for label in ('found-on-phone', 'needs-human-validation', 'status: needs-human-validation'):
            issue = self.closed(854, 'Hear James through numbers.')
            issue['labels'] = {'nodes': [{'name': label}]}
            entry = [self.pr(901, 'James keeps his voice', [issue])]
            self.assertFalse(self.module.passed_on_phone(entry), label)
            self.assertIn('James keeps his voice', self.write({901: entry[0]}), label)

    def test_a_plan_of_only_passed_changes_says_nothing_is_left_to_check(self):
        plan = self.write({n: pr for n, pr in self.prs().items() if n in (901, 902)})
        self.assertIn('Nothing a listener would notice changed.', plan)
        self.assertIn('2 changes whose issues are already closed are left out.', plan)

    def test_the_plan_asks_github_for_each_issue_s_state(self):
        # The filter reads issue['state']; without it in the queries every issue looks open and nothing is dropped.
        self.assertRegex(self.module.PR_FIELDS, r'closingIssuesReferences\(first:5\)\{nodes\{[^}]*\bstate\b')
        self.assertRegex(self.module.ISSUE_FIELDS, r'\bstate\b')


class WaitingReadsClosedIssuesTests(unittest.TestCase):
    """2026-10-22: a merged fix closes its issue and `status: needs-human-validation` stays on it, so the
    still-waiting list reads closed issues from the last 60 days too."""

    def setUp(self):
        self.module = load_phone_build()

    def page(self, nodes):
        return json.dumps({'data': {'repository': {'issues': {
            'pageInfo': {'hasNextPage': False, 'endCursor': None}, 'nodes': nodes}}}})

    def test_it_queries_open_and_recently_closed_and_drops_older_closed(self):
        calls = []
        recent = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(days=3)).strftime('%Y-%m-%dT%H:%M:%SZ')
        answers = {'OPEN': [{'number': 1, 'createdAt': '2026-10-01T00:00:00Z'}],
                   'CLOSED': [{'number': 2, 'createdAt': '2026-09-01T00:00:00Z', 'closedAt': recent},
                              {'number': 3, 'createdAt': '2026-08-01T00:00:00Z', 'closedAt': '2026-01-01T00:00:00Z'}]}

        def gh(*args):
            query = next(a for a in args if a.startswith('query='))
            calls.append(query)
            return self.page(answers['CLOSED' if 'states: CLOSED' in query else 'OPEN'])
        self.module.gh = gh
        found = self.module.fetch_waiting()
        self.assertEqual([issue['number'] for issue in found], [2, 1])  # oldest first, the stale closed one dropped
        self.assertEqual(len(calls), 2)
        self.assertIn('states: OPEN', calls[0])
        self.assertIn('filterBy: {since:', calls[1])

    def test_a_failed_closed_read_is_not_a_complete_list(self):
        self.module.gh = lambda *args: self.page([]) if 'states: OPEN' in ' '.join(args) else ''
        self.assertIsNone(self.module.fetch_waiting())


class RevertedPRTests(unittest.TestCase):
    """#1545: the 437fbc9 notes asked the owner to check #447, #450 and #451, whose screen PRs had merged and
    then been reverted inside #1482. A reverted PR isn't in the build until it lands again."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.git('init', '-q', '-b', 'next')
        self.commit('Merge pull request #1356: Podcast Now view: logic for the nearest Margins (part of #447)')
        self.commit('Merge pull request #1365: Now view live passage: the logic (part of #451)')
        dock = self.commit('Merge pull request #1371: Keep the playback dock across Now, Timeline and Margins (#447)')
        passage = self.commit('Merge pull request #1404: Show the live source passage in Now (#451)')
        bar = self.commit('Merge pull request #1380 from a/bar-labels')
        rail = self.commit('Merge pull request #1390: Draw chapters on the rail (#452)')
        lane = self.commit('Merge pull request #1407: Wait for imports (#460)')
        # The reverts arrive inside a merged PR, so they aren't first-parent commits of the build (#1482).
        self.git('switch', '-q', '-c', 'restore')
        self.commit(f'Revert #1371: playback dock across Now, Timeline and Margins\n\n'
                    f'This reverts merge {dock[:8]}, reversing changes made to 2390c0df.')
        self.commit(f'Revert #1404: live source passage in Now\n\nThis reverts merge {passage[:8]}.')
        self.commit(f'Revert "Merge pull request #1380 from a/bar-labels"\n\nThis reverts commit {bar}.')
        self.commit(f'Put the old rail back\n\nThis reverts merge {rail[:8]}.')
        self.git('switch', '-q', 'next')
        self.git('merge', '-q', '--no-ff', 'restore', '-m',
                 'Merge pull request #1482: Restore the Build 30 screen (#1475)')
        # The lane runner's revert, then a re-land; git's default revert, then a revert of that revert.
        self.commit(f'Revert #1407: Tested as this exact commit and merged by the lane runner. (integration FAIL)\n\n'
                    f'This reverts commit {lane}.')
        self.commit('Merge pull request #1418: Re-land #1407 and give two import waits a budget (#1413)')
        self.commit('Revert "Revert "Merge pull request #1380 from a/bar-labels""')
        self.commit('Merge pull request #1183: test: pin episode map stored names')
        self.commit('Revert #1183: test: pin episode map stored names')
        self.commit('Merge pull request #1250: test: re-land episode map stored-name pins (#1183)')
        self.tip = self.git('rev-parse', 'HEAD')
        environment = unittest.mock.patch.dict(os.environ, {'SM_PHONE_REPO': str(self.repo)})
        environment.start()
        self.addCleanup(environment.stop)
        self.module = load_phone_build()

    def git(self, *args):
        return subprocess.run(['git', '-c', 'user.email=t@example.com', '-c', 'user.name=T', *args], cwd=self.repo,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message):
        self.git('commit', '-q', '--allow-empty', '-m', message)
        return self.git('rev-parse', 'HEAD')

    @staticmethod
    def issue(number, title, prs, comments=()):
        return {'number': number, 'title': title, 'url': f'https://example/issue/{number}', 'state': 'OPEN',
                'createdAt': f'2026-10-0{number % 9 + 1}T00:00:00Z', 'milestone': None,
                'labels': {'nodes': [{'name': 'status: needs-human-validation'}]},
                'body': f'**Owner check:** open the playback screen and look at {title}.\n',
                'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': body} for body in comments]},
                'timelineItems': {'nodes': [{'source': {'number': n, 'title': t, 'body': '', 'merged': True,
                                                        'url': f'https://example/pr/{n}'}} for n, t in prs]}}

    def test_reverted_prs_follow_commit_order(self):
        # #1371 and #1404 by subject, #1390 by the merge its body names; #1380, #1407 and #1183 came back.
        self.assertEqual(self.module.reverted_prs(self.tip), {1371, 1404, 1390})

    def test_a_reverted_pr_is_not_in_the_build(self):
        self.assertEqual(self.module.build_prs(self.tip), {1356, 1365, 1380, 1407, 1418, 1482, 1183, 1250})
        named = self.module.built_numbers(self.tip)
        self.assertTrue({1371, 1404, 1390, 452}.isdisjoint(named), named)
        self.assertTrue({1356, 447, 451, 1380, 1407, 460}.issubset(named), named)

    def test_an_issue_whose_screen_pr_was_reverted_is_not_waiting_on_the_phone(self):
        # #447: logic PR #1356 kept, screen PR #1371 reverted. #451: #1365 kept, #1404 (named in a comment)
        # reverted. #453 and #460 had theirs reverted and landed again.
        dock = self.issue(447, 'the dock', [(1356, 'Podcast Now view: logic (part of #447)'),
                                            (1371, 'Keep the playback dock (#447)')])
        passage = self.issue(451, 'the live passage', [(1365, 'Now view live passage: the logic (part of #451)')],
                             comments=['Merged in #1404.'])
        labels = self.issue(453, 'the bar labels', [(1380, 'Bar labels (#453)')])
        imports = self.issue(460, 'imports', [(1407, 'Wait for imports (#460)')])
        module = self.module
        fixes = module.waiting_fixes([dock, passage, labels, imports], module.build_prs(self.tip), set(),
                                     module.built_numbers(self.tip), module.reverted_prs(self.tip))
        self.assertEqual(sorted(fix['issue']['number'] for fix in fixes), [453, 460])

    def test_the_new_changes_leave_out_a_pr_reverted_since(self):
        merged = self.module.merged_prs(None, self.tip)
        self.assertNotIn(1371, merged)
        self.assertIn(1407, merged)


class PlanBaseTests(unittest.TestCase):
    """#1100: installed.txt named a build made on the Mac before its changes reached next, so the commit was
    known but not behind next's tip; the plan fell back to Build 29 and listed 332 pull requests."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo, self.phone = Path(temporary.name) / 'repo', Path(temporary.name) / 'phone'
        self.repo.mkdir()
        self.phone.mkdir()
        self.git('init', '-q', '-b', 'next')
        self.first = self.commit('Merge pull request #1 from a/b')
        self.git('tag', 'testflight/0.1-build-29')
        self.second = self.commit('Merge pull request #2 from a/b')
        self.git('switch', '-q', '-c', 'candidate')
        self.candidate = self.commit('Merge pull request #9 from a/local-only')  # built on the Mac, never on next
        self.git('switch', '-q', 'next')
        self.tip = self.commit('Merge pull request #3 from a/b')
        environment = unittest.mock.patch.dict(os.environ, {'SM_PHONE_REPO': str(self.repo), 'SM_PHONE_DIR': str(self.phone)})
        environment.start()
        self.addCleanup(environment.stop)
        self.module = load_phone_build()

    def git(self, *args):
        return subprocess.run(['git', '-c', 'user.email=t@example.com', '-c', 'user.name=T', *args], cwd=self.repo,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, subject):
        self.git('commit', '-q', '--allow-empty', '-m', subject)
        return self.git('rev-parse', 'HEAD')

    def installed(self, sha):
        (self.phone / 'installed.txt').write_text(f'{sha} 2026-10-08T08:00:00 phone\n')

    def test_a_build_behind_next_is_the_base(self):
        self.installed(self.second)
        base, why = self.module.plan_base(self.tip)
        self.assertEqual((base, list(self.module.merged_prs(base, self.tip))), (self.second, [3]))
        self.assertEqual(why, f'the build you last installed (`{self.second[:7]}`, from installed.txt)')

    def test_a_candidate_that_is_not_in_nexts_history_is_still_the_base(self):
        self.installed(self.candidate)
        base, why = self.module.plan_base(self.tip)
        self.assertEqual(base, self.candidate)  # not the TestFlight build
        self.assertEqual(list(self.module.merged_prs(base, self.tip)), [3])  # what next has beyond it, not #1 to #3
        self.assertIn("it isn't part of next's history", why)

    def test_a_commit_this_checkout_does_not_have_falls_back_and_says_so(self):
        self.installed('f' * 40)
        base, why = self.module.plan_base(self.tip)
        self.assertEqual(base, self.first)
        self.assertIn("`fffffff`, which this checkout doesn't have", why)
        self.assertEqual(list(self.module.merged_prs(base, self.tip)), [3, 2])

    def test_a_commit_newer_than_the_build_falls_back_instead_of_planning_nothing(self):
        # --plan-only or --commit for an older tip while the phone has a newer one: "since the installed build"
        # would be empty and the plan would say "this is the same code, rebuilt".
        newer = self.commit('Merge pull request #4 from a/b')
        self.installed(newer)
        base, why = self.module.plan_base(self.tip)
        self.assertEqual(base, self.first)
        self.assertIn('which is newer than this build', why)

    def test_the_build_itself_installed_is_the_base_and_plans_nothing_new(self):
        self.installed(self.tip)
        base, _ = self.module.plan_base(self.tip)
        self.assertEqual((base, self.module.merged_prs(base, self.tip)), (self.tip, {}))

    def test_nothing_installed_yet_falls_back_to_the_last_testflight_build(self):
        base, why = self.module.plan_base(self.tip)
        self.assertEqual(base, self.first)
        self.assertIn('nothing recorded in installed.txt yet', why)



class SolidGroundLeadTests(unittest.TestCase):
    """2026-10-16: the two most important open phone checks never reached the owner's plans. #1708 (priority,
    found on the phone, Solid Ground) had its check only in the hourly dispatch's prose ("This needs the owner's
    Bluetooth headphones: ..."), and #1337's last comment wrote "The owner's phone check: ...". Neither reads as
    "Owner check:", so the fdda29c plan put #1709 under "no phone check written" and the ca6bbd9 plan led with
    #1073 instead."""

    DISPATCH_1708 = (
        'Merged into `next` by #1709 (2026-10-16 06:44Z). Hourly dispatch: released `in-progress` and added '
        "`status: needs-human-validation`. This needs the owner's Bluetooth headphones: on a podcast, tap Add a "
        'Margin and check the recording screen stays open; then press the headphone button mid-Margin and check it '
        'still ends and saves the Margin (#1030). Stays open in Solid Ground until he confirms.\n\n---\n'
        '_Generated by [Claude Code](https://claude.ai/code)_')
    CHECK_1708 = ('on a podcast, tap Add a Margin and check the recording screen stays open; then press the '
                  'headphone button mid-Margin and check it still ends and saves the Margin (#1030).')
    STOPPING_1337 = (
        'Thread "Fallback switch regression test" stopping: #1703 merged into `next`.\n\n'
        '**Still open on this issue.**\n'
        '1. The cause of the 14:31:03 idle transition (the `session.end` records should name it).\n'
        "2. The owner's phone check: background narration through a real Supertonic fallback, a Lock Screen tap, "
        'and the position carrying on.\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_')

    def setUp(self):
        self.module = load_phone_build()

    pr = staticmethod(PlanGroupingTests.pr)
    write = PlanGroupingTests.write

    @staticmethod
    def fix(number, names=(), milestone='Solid Ground', check=None, comments=(), created='2026-10-01', prs=()):
        """An open `status: needs-human-validation` issue as fetch_waiting reads it, with any labels."""
        return {'number': number, 'title': f'Waiting {number}', 'url': f'https://example/issue/{number}',
                'body': f'**Owner check:** {check}\n' if check else 'It broke.\n\nExpected: it works.',
                'createdAt': created, 'state': 'OPEN',
                'labels': {'nodes': [{'name': name} for name in ['status: needs-human-validation', *names]]},
                'milestone': {'title': milestone, 'state': 'OPEN'} if milestone else None,
                'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': body} for body in comments]},
                'timelineItems': {'nodes': [{'source': {'number': n, 'title': f'Fix it (#{number})', 'body': '',
                                                        'url': f'https://example/pr/{n}', 'merged': True}}
                                            for n in prs]}}

    def test_checks_written_the_way_dispatch_and_threads_write_them(self):
        # A table of neighbouring inputs (AGENTS.md): what counts as the owner's check in a comment, and what doesn't.
        comment_check = self.module.comment_check
        cases = [
            (self.DISPATCH_1708, self.CHECK_1708),
            (self.STOPPING_1337, 'background narration through a real Supertonic fallback, a Lock Screen tap, and '
                                 'the position carrying on.'),
            ("The owner’s phone check: open the mini player.", 'open the mini player.'),     # curly apostrophe
            ("- Owner's phone check: open the mini player.", 'open the mini player.'),
            ('**Owner check.** Run your share-sheet shortcut on a link; it finishes in the app with no picker.',
             'Run your share-sheet shortcut on a link; it finishes in the app with no picker.'),  # #574's "."
            ("This needs the owner's phone: open a PDF and read its first page.",
             'open a PDF and read its first page.'),
            ("This needs the owner’s AirPods: press the stem once mid-Margin; it ends and saves.",
             'press the stem once mid-Margin; it ends and saves.'),
            # Not checks: #1030's routing note, a decision asked of him, a dated report, prose.
            ("#1596 merged into `next` at 19:40Z. This needs the owner's phone and headphones to confirm, so it now "
             'waits on his phone check: `in-progress` removed, `status: needs-human-validation` added.', None),
            ("This needs the owner's call: thirty seconds or ten?", None),
            ('Owner phone check, 2026-10-14 evening, candidate 0.1 (32): headphone-button completion did not pass.',
             None),
            ('the phone check covers that: nothing else to do.', None),
            ('', None),
        ]
        for body, expected in cases:
            with self.subTest(body=body[:60]):
                self.assertEqual(comment_check({'comments': {'nodes': [{'authorAssociation': 'OWNER', 'body': body}]}}), expected)

    def test_current_milestone_priority_then_found_on_phone_lead_the_waiting_fixes(self):
        # The ca6bbd9 plan, 2026-10-16: #1073 (no milestone priority) took "Still waiting" while #1708 and #1337
        # (Solid Ground, on the phone, waiting on him) weren't on it at all.
        waiting = [
            self.fix(1073, milestone=None, created='2026-10-08', prs=[1303],
                     check='with one article playing, run a shortcut that adds a Margin to a different article.'),
            self.fix(1337, ['bug', 'found-on-phone'], created='2026-10-10', prs=[1703],
                     comments=[self.STOPPING_1337]),
            self.fix(1708, ['bug', 'regression', 'found-on-phone', 'priority'], created='2026-10-16', prs=[1709],
                     comments=[self.DISPATCH_1708]),
            self.fix(1600, created='2026-09-05', prs=[1601], check='Play the Solid Ground thing.'),
            self.fix(1682, ['found-on-phone', 'priority'], milestone='Later', created='2026-09-01', prs=[1683],
                     check='Play an article until the phone is warm.'),
            self.fix(1679, ['found-on-phone', 'priority', 'validate-by-use'], created='2026-09-02', prs=[1684],
                     check='Listen as usual.', comments=['Owner check: none. Validated by use.']),
            self.fix(1690, ['found-on-phone', 'priority'], created='2026-09-03', prs=[1691],
                     comments=['Owner check: none. Diagnostics show it.']),
        ]
        plan = self.write({366: self.pr(366, 'Take the rendered speech cache out of the offline storage ledger')},
                          waiting=waiting, built_prs={1303, 1703, 1709, 1601, 1683, 1684, 1691})
        still = plan.split('## Still waiting on your check')[1].split('\n## ')[0]
        numbered = re.findall(r'(?m)^\d+\. \*\*(.+?)\*\*', still)
        self.assertEqual(numbered, ['Waiting 1708', 'Waiting 1337', 'Waiting 1600', 'Waiting 1073'], plan)
        self.assertIn('1. **Waiting 1708** (found on your phone)\n   - Check: ' + self.CHECK_1708, still)
        self.assertIn('2. **Waiting 1337** (found on your phone)\n   - Check: background narration through a real '
                      'Supertonic fallback', still)
        also = plan.split('## Also waiting on your check (not in the ten minutes)')[1].split('\n## ')[0]
        self.assertIn('- Waiting 1682 (found on your phone) ([#1682](https://example/issue/1682), '
                      '[#1683](https://example/pr/1683)): waits for Later', also)
        for gone in ('Waiting 1679', 'Waiting 1690'):                    # validate-by-use and "Owner check: none"
            self.assertNotIn(gone, plan)
        for quiet in ('#1679', '#1690'):
            self.assertNotIn(quiet, self.printed)

    def test_the_lead_fixes_keep_their_place_when_new_changes_fill_the_ten_minutes(self):
        self.module.PLAN_CHECKS = 3
        issue = PlanGroupingTests.issue
        new = {n: self.pr(n, f'New change {n}', [issue(n + 1000, f'Try new change {n}.')]) for n in (280, 281, 282)}
        waiting = [self.fix(1708, ['found-on-phone', 'priority'], created='2026-10-16', prs=[1709],
                            comments=[self.DISPATCH_1708]),
                   self.fix(1600, created='2026-09-05', prs=[1601], check='Play the Solid Ground thing.')]
        plan = self.write(new, waiting=waiting, built_prs={1709, 1601})
        still = plan.split('## Still waiting on your check')[1].split('\n## ')[0]
        self.assertIn('**Waiting 1708**', still)
        self.assertEqual(len(re.findall(r'(?m)^\d+\. \*\*', plan.split('## Also')[0])), 3, plan)
        self.assertIn('Waiting 1600', plan.split('## Also waiting on your check')[1])

    def test_a_new_priority_fix_with_no_steps_yet_is_not_filed_under_nothing_to_test(self):
        # The fdda29c plan, 08:51Z on 2026-10-16: #1709 fixed #1708 (priority, found on the phone, Solid Ground)
        # before dispatch wrote the check at 09:22Z, and the plan said "You don't need to test these" about it.
        bluetooth = self.fix(1708, ['bug', 'regression', 'found-on-phone', 'priority'])
        everyday = self.fix(1700, ['found-on-phone', 'validate-by-use'])
        plan = self.write({1709: self.pr(1709, 'Ignore a Now Playing play in the first moment of a Margin recording '
                                               '(#1708)', [bluetooth]),
                           1701: self.pr(1701, 'Everyday fix', [everyday]),
                           366: self.pr(366, 'Take the rendered speech cache out of the offline storage ledger')})
        unchecked = plan.split('## Also changed (no phone check written)')[1]
        self.assertNotIn('Ignore a Now Playing play', unchecked)
        self.assertIn('Everyday fix', unchecked)                          # validate-by-use: his use checks it
        steps = plan.split('## Important, but no phone steps written yet')[1].split('\n## ')[0]
        self.assertIn('- Ignore a Now Playing play in the first moment of a Margin recording (#1708) (found on your '
                      'phone) ([#1709](https://example/pr/1709))', steps)
        self.assertIn('#1708', self.printed)
        alone = self.write({1709: self.pr(1709, 'Ignore a Now Playing play (#1708)', [bluetooth])})
        self.assertNotIn('Nothing a listener would notice changed', alone)
        self.assertIn('- Ignore a Now Playing play (#1708) (found on your phone)', alone)

    def test_once_dispatch_writes_the_check_the_new_fix_leads_the_ten_minutes(self):
        bluetooth = self.fix(1708, ['bug', 'regression', 'found-on-phone', 'priority'], comments=[self.DISPATCH_1708])
        issue = PlanGroupingTests.issue
        plan = self.write({1720: self.pr(1720, 'Library wording', [issue(81, 'Read the Library rows.', phone=True)]),
                           1709: self.pr(1709, 'Ignore a Now Playing play in the first moment of a Margin recording '
                                               '(#1708)', [bluetooth])})
        self.assertIn('1. **Ignore a Now Playing play in the first moment of a Margin recording (#1708)** (found on '
                      'your phone)\n   - Check: ' + self.CHECK_1708, plan)
        self.assertIn('2. **Library wording**', plan)
        self.assertNotIn('no phone steps written', plan)

if __name__ == '__main__':
    unittest.main()
