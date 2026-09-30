"""scripts/phone-build and scripts/install-phone-build.command (#384).

The installer runs against a fake `xcrun` on PATH, so no test can reach a real phone: the fake
answers `devicectl list devices` from FAKE_DEVICES and records every other call. The build runs
against a scratch repo and a fake xcodebuild (SM_LANE_XCODEBUILD) that makes an ad-hoc signed app.
"""
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

    def run_installer(self, devices, **extra):
        env = {**os.environ, 'PATH': f'{self.bin}:/usr/bin:/bin', 'SM_PHONE_DIR': str(self.phone),
               'FAKE_LOG': str(self.log), 'FAKE_DEVICES': json.dumps(devices), **extra}
        done = subprocess.run(['/bin/zsh', str(INSTALLER)], env=env, capture_output=True, text=True, timeout=60)
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

FAKE_GH = r'''#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write("gh " + " ".join(args) + "\n")
tip = os.environ["FAKE_TIP"]
if args[:1] == ["api"] and args[1].endswith("/issues/12/comments"):
    print("**Merge check (triage desk) on `1234567`: PASS.**\n- Tested the merge commit `%s`.\n"
          "- Ran: --plan fast and both builds.\n- Pushing `%s` to next now." % (tip[:7], tip[:7]))
elif args[:1] == ["api"] and args[1].endswith("/issues/337/comments"):
    print("**2026-09-30 09:00 EDT (SM integration run)** · next `%s` PASS, 564 of 564" % tip[:7])
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
        for name, body in (('xcodebuild', FAKE_XCODEBUILD), ('gh', FAKE_GH)):
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
                    'FAKE_PLIST_KEY': '1'}

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
        self.assertIn('564 of 564', plan)
        builds = self.log.read_text()
        self.assertIn('-configuration Release', builds)
        self.assertIn('-allowProvisioningUpdates', builds)
        self.assertNotIn('build-for-testing', builds)  # the runner already tested this commit
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

    def test_owner_check_prefers_the_issue(self):
        pr = {'body': 'Owner check: from the PR', 'issues': [{'body': 'x\n**Owner check:** from the issue\nmore'}]}
        self.assertEqual(self.module.owner_check(pr), 'from the issue')
        self.assertEqual(self.module.owner_check({'body': 'Owner check: from the PR', 'issues': []}), 'from the PR')
        self.assertIsNone(self.module.owner_check({'body': '', 'issues': []}))

    def test_bug_report_steps_stand_in_for_a_missing_owner_check(self):
        issue = {'body': '**Steps:** open an article.\n**Expected:** a label that fits.\n'}
        self.assertEqual(self.module.owner_check({'body': '', 'issues': [issue]}),
                         'open an article. Expected: a label that fits.')


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
        module.latest_verdict = lambda sha: None
        with tempfile.TemporaryDirectory() as folder:
            plan = module.write_plan(Path(folder), 'a' * 40, 'host tests').read_text()
        self.assertEqual(plan.count('Follow a site with a feed and one without.'), 1, plan)
        self.assertIn('[PR #330](https://example/pr/330), [PR #300](https://example/pr/300), '
                      '[issue #80](https://example/issue/80)', plan)
        self.assertIn('1. **Follow sites without a feed** (found on your phone)', plan)
        self.assertIn('2. **Library wording**', plan)
        self.assertNotIn('3. ', plan)


if __name__ == '__main__':
    unittest.main()
