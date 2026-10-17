"""scripts/check-gitleaks.sh and .gitleaks.toml (#1839).

The scans run in a scratch repository holding the script, the config and a copy of every tracked file
the config allowlists, so they take seconds instead of a full-tree pass. Tests that need gitleaks skip
when it isn't installed (cloud threads lack it); the config's shape and the "not installed" line are
checked everywhere.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts' / 'check-gitleaks.sh'
CONFIG = ROOT / '.gitleaks.toml'
GITLEAKS = shutil.which('gitleaks')
# High entropy, shaped like an assignment, so gitleaks' generic-api-key rule fires on it. It's assembled
# at run time so this file, and its .pyc, don't hold the line and trip the repository's own scan.
FAKE_KEY_LINE = 'let apiKey = "%s"\n' % 'q8Vx3LmP0zRt7KwN2bYc5HdJ9sFg4AeU'
# Allowlisted files that were moved or removed; the 2026-10-16 all-refs scan found them in old commits.
HISTORY_ONLY_PATHS = {
    r'(?:^|/)Packages/SessionKit/Tests/SessionKitTests/OPMLTests\.swift$',
    r'(?:^|/)Packages/SessionKit/Tests/SessionKitTests/SourceResolutionTests\.swift$',
    r'(?:^|/)artifacts/.+\.(?:ips|txt)$',
    r'(?:^|/)research/B1/recorded/2026-09-28/lookup-02\.json$',
}


def allowlists():
    return tomllib.loads(CONFIG.read_text())['allowlists']


def allowlisted_tracked_files():
    tracked = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, check=True,
                             capture_output=True, text=True).stdout.split('\0')
    patterns = [re.compile(p) for entry in allowlists() for p in entry.get('paths', [])]
    return sorted({path for path in tracked if path and any(p.search(path) for p in patterns)})


class ConfigShapeTests(unittest.TestCase):
    def test_every_allowlist_says_why_and_which_rules(self):
        for entry in allowlists():
            with self.subTest(entry=entry.get('description')):
                self.assertTrue(entry.get('description', '').strip())
                self.assertTrue(entry.get('targetRules'), 'an allowlist must not cover every rule')
                self.assertTrue(entry.get('paths'), 'an allowlist must name its files')

    def test_no_allowlist_clears_a_whole_folder(self):
        # A path entry either names one file, or the entry also pins the exact values (AND) it clears.
        for entry in allowlists():
            for path in entry['paths']:
                with self.subTest(path=path):
                    names_one_file = path.endswith('$') and '.+' not in path and '.*' not in path
                    pinned = entry.get('condition') == 'AND' and entry.get('regexes')
                    self.assertTrue(names_one_file or pinned, path)

    def test_every_allowlisted_path_is_in_the_tree_or_known_history(self):
        # A typo in a path would silently clear nothing. Paths that only exist in history are named here.
        files = allowlisted_tracked_files()
        for entry in allowlists():
            for path in entry['paths']:
                with self.subTest(path=path):
                    if path in HISTORY_ONLY_PATHS:
                        continue
                    self.assertTrue(any(re.search(path, f) for f in files), path)


class CheckGitleaksScriptTests(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix='check-gitleaks-test-'))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        subprocess.run(['git', 'init', '-q', str(self.scratch)], check=True)
        (self.scratch / 'scripts').mkdir()
        shutil.copy2(SCRIPT, self.scratch / 'scripts' / SCRIPT.name)
        shutil.copy2(CONFIG, self.scratch / CONFIG.name)
        (self.scratch / '.gitignore').write_text('artifacts/\n')
        for relative in allowlisted_tracked_files():
            target = self.scratch / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)

    def run_script(self, *args, env=None):
        return subprocess.run(['bash', str(self.scratch / 'scripts' / SCRIPT.name), *args],
                              cwd=self.scratch, capture_output=True, text=True, env=env, timeout=300)

    def test_says_skipped_when_gitleaks_is_missing(self):
        env = dict(os.environ, PATH='/usr/bin:/bin')
        if shutil.which('gitleaks', path=env['PATH']):
            self.skipTest('gitleaks is installed in a system folder')
        result = self.run_script(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('gitleaks not installed, skipped', result.stdout)

    def test_rejects_unknown_arguments(self):
        self.assertEqual(self.run_script('--everything').returncode, 2)

    @unittest.skipUnless(GITLEAKS, 'gitleaks not installed')
    def test_known_look_alikes_scan_clean(self):
        self.assertTrue(allowlisted_tracked_files())
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-2000:])

    @unittest.skipUnless(GITLEAKS, 'gitleaks not installed')
    def test_new_key_in_an_allowlisted_file_still_fails(self):
        target = self.scratch / 'Packages/SessionKit/Tests/SessionKitTests/PrivateFeedLinkTests.swift'
        with target.open('a') as handle:
            handle.write(FAKE_KEY_LINE)
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stdout[-2000:] + result.stderr[-2000:])
        self.assertIn('PrivateFeedLinkTests.swift', result.stdout + result.stderr)

    @unittest.skipUnless(GITLEAKS, 'gitleaks not installed')
    def test_new_key_in_a_new_file_fails(self):
        (self.scratch / 'Config.swift').write_text(FAKE_KEY_LINE)
        self.assertEqual(self.run_script().returncode, 1)

    @unittest.skipUnless(GITLEAKS, 'gitleaks not installed')
    def test_crash_reporter_keys_in_old_crash_reports_scan_clean(self):
        # History only, so the tree scan never sees these; scan a synthetic report with the config.
        # The ID is joined at run time for the same reason as FAKE_KEY_LINE.
        reporter_id = '-'.join(['8C1F2E3A', '4B5D', '6E7F', '8091', 'A2B3C4D5E6F7'])
        report = self.scratch / 'artifacts' / 'review' / 'Safari-2026-09-03.ips'
        report.parent.mkdir(parents=True)
        report.write_text('{\n  "crashReporterKey" : "%s",\n  "pid" : 1\n}\n' % reporter_id)
        (report.parent / 'reported-crash.txt').write_text('Crash Reporter Key:  %s\n' % reporter_id)
        default_rules = self.scratch / 'default-rules.toml'
        default_rules.write_text('[extend]\nuseDefault = true\n')

        def scan(config):
            return subprocess.run([GITLEAKS, 'dir', '--config', str(config), '--no-banner', '--redact',
                                   str(report.parent)], capture_output=True, text=True, timeout=120)

        self.assertEqual(scan(default_rules).returncode, 1, 'the default rules should flag these lines')
        result = scan(CONFIG)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])

    @unittest.skipUnless(GITLEAKS, 'gitleaks not installed')
    def test_ignored_and_deleted_files_stay_out_of_the_tree_scan(self):
        # Local output under an ignored folder is never published, so it isn't scanned.
        (self.scratch / 'artifacts').mkdir()
        (self.scratch / 'artifacts' / 'run.log').write_text(FAKE_KEY_LINE)
        # A tracked file deleted in the working tree is skipped instead of breaking the copy.
        (self.scratch / 'Gone.swift').write_text('let x = 1\n')
        subprocess.run(['git', 'add', 'Gone.swift'], cwd=self.scratch, check=True)
        (self.scratch / 'Gone.swift').unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-2000:])


if __name__ == '__main__':
    unittest.main()
