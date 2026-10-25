"""ops/install-launchd.py and the plist templates it renders (#1843)."""
import importlib.util
import os
import plistlib
import re
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

OPS = Path(__file__).resolve().parent
ROOT = OPS.parent
spec = importlib.util.spec_from_file_location('install_launchd', OPS / 'install-launchd.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

HOME = '/Users/someone'
CHECKOUTS = ('SpokenMarginsOps/repo/', 'Documents/GitHub/spoken-margins-native/', 'Library/Caches/SpokenMarginsLane/tools/')


def render_all(home=HOME):
    return {name: installer.render(path.read_text(), {'HOME': home, 'SM_REPO': ''})
            for name, path in installer.jobs().items()}


class TemplateTests(unittest.TestCase):
    def test_the_live_jobs_are_found(self):
        self.assertEqual(set(installer.jobs()), {'claude-worker', 'codex-audit', 'disk-relief', 'lane-power-guard',
                                                 'lane-tools-refresh',
                                                 'keep-awake', 'integration-run', 'daily-phone-plan', 'phone-build'})

    def test_every_template_renders_to_a_plist_with_no_placeholder_or_home_left(self):
        for name, text in render_all().items():
            with self.subTest(name):
                plistlib.loads(text.encode())
                self.assertIsNone(re.search(r'@[A-Z][A-Z0-9_]*@', text))
                self.assertNotIn('/Users/colemiller', text)
                self.assertIn(HOME, text)

    def test_the_label_equals_the_file_name(self):
        for name, path in installer.jobs().items():
            with self.subTest(name):
                data = plistlib.loads(installer.render(path.read_text(), {'HOME': HOME}).encode())
                self.assertEqual(data['Label'], installer.label_of(path))
                self.assertTrue(data['Label'].startswith(installer.PREFIX))

    def test_every_script_a_job_runs_exists_in_the_repository(self):
        for name, text in render_all().items():
            with self.subTest(name):
                arguments = plistlib.loads(text.encode())['ProgramArguments']
                scripts = [a for a in arguments if a.startswith(HOME + '/') and any(c in a for c in CHECKOUTS)]
                self.assertTrue(scripts, f'{name} runs nothing from a checkout')
                for argument in scripts:
                    relative = next(argument.split(c, 1)[1] for c in CHECKOUTS if c in argument)
                    self.assertTrue((ROOT / relative).is_file(), relative)

    def test_no_other_plist_in_the_repository_carries_the_owners_home(self):
        found = {str(p.relative_to(ROOT)) for folder in ('ops', 'scripts') for p in (ROOT / folder).rglob('*.plist')
                 if '/Users/colemiller' in p.read_text(errors='replace')}
        self.assertEqual(found, set())


class RenderTests(unittest.TestCase):
    TEMPLATE = '<?xml version="1.0"?><plist version="1.0"><dict><key>K</key><string>@HOME@/x</string></dict></plist>'

    def test_a_home_with_spaces_and_xml_characters_stays_one_valid_string(self):
        for home in ('/Users/a b', '/Users/a&b', '/Users/<x>'):
            with self.subTest(home):
                out = installer.render(self.TEMPLATE, {'HOME': home})
                self.assertEqual(plistlib.loads(out.encode())['K'], home + '/x')

    def test_a_missing_variable_fails_loudly(self):
        with self.assertRaisesRegex(installer.TemplateError, '@OTHER@'):
            installer.render(self.TEMPLATE.replace('@HOME@', '@OTHER@'), {'HOME': HOME})
        with self.assertRaisesRegex(installer.TemplateError, '@SM_REPO@'):
            installer.render(self.TEMPLATE.replace('@HOME@', '@SM_REPO@'), {'HOME': HOME, 'SM_REPO': ''})

    def test_text_that_is_no_longer_a_plist_fails_loudly(self):
        with self.assertRaisesRegex(installer.TemplateError, 'not a valid plist'):
            installer.render('<plist><dict>@HOME@', {'HOME': HOME})

    def test_an_unset_or_relative_home_is_refused(self):
        args = SimpleNamespace(home=None, repo=None)
        for env in ({}, {'HOME': ''}, {'HOME': 'relative/path'}):
            with self.subTest(env):
                with self.assertRaises(installer.TemplateError):
                    installer.values_from(args, env)
        self.assertEqual(installer.values_from(SimpleNamespace(home='/h/', repo=None), {})['HOME'], '/h')
        self.assertEqual(installer.values_from(args, {'HOME': '/h', 'SM_REPO': '/r'})['SM_REPO'], '/r')


class InstallTests(unittest.TestCase):
    def run_main(self, *argv, calls=None):
        def fake(command, **kwargs):
            if calls is not None:
                calls.append(command)
            return SimpleNamespace(returncode=0, stdout='', stderr='')
        return installer.main(list(argv), env={'HOME': HOME}, run=fake)

    def test_print_writes_nothing_and_runs_nothing(self):
        calls = []
        with tempfile.TemporaryDirectory() as agents, mock.patch('sys.stdout'):
            self.assertEqual(self.run_main('--print', 'disk-relief', '--agents-dir', agents, calls=calls), 0)
            self.assertEqual(os.listdir(agents), [])
        self.assertEqual(calls, [])

    def test_install_writes_the_rendered_plist_then_boots_out_and_bootstraps(self):
        calls = []
        with tempfile.TemporaryDirectory() as agents, mock.patch('sys.stdout'):
            self.assertEqual(self.run_main('--install', 'keep-awake', '--agents-dir', agents, calls=calls), 0)
            target = Path(agents) / 'com.spokenmargins.keep-awake.plist'
            self.assertEqual(plistlib.loads(target.read_bytes())['Label'], 'com.spokenmargins.keep-awake')
            self.assertNotIn('@HOME@', target.read_text())
        uid = os.getuid()
        self.assertEqual(calls, [['launchctl', 'bootout', f'gui/{uid}/com.spokenmargins.keep-awake'],
                                 ['launchctl', 'bootstrap', f'gui/{uid}', str(target)]])

    def test_remove_boots_out_and_deletes_the_file(self):
        calls = []
        with tempfile.TemporaryDirectory() as agents, mock.patch('sys.stdout'):
            target = Path(agents) / 'com.spokenmargins.keep-awake.plist'
            target.write_text('x')
            self.assertEqual(self.run_main('--remove', 'keep-awake', '--agents-dir', agents, calls=calls), 0)
            self.assertFalse(target.exists())
        self.assertEqual([c[1] for c in calls], ['bootout'])

    def test_unknown_job_and_install_all_are_refused_without_side_effects(self):
        calls = []
        with mock.patch('sys.stderr'):
            self.assertEqual(self.run_main('--install', 'nope', calls=calls), 1)
            self.assertEqual(self.run_main('--install', 'all', calls=calls), 1)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
