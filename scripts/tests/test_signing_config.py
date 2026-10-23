"""The signing team is a local setting, not a tracked literal (#1841).

A fork builds for the simulator with no team and for a device with its own, by creating the git-ignored
Config/Local.xcconfig. The owner's worktrees sign as before because scripts/xcodebuild-lane links the main
checkout's copy into a worktree that has none.
"""
import importlib.machinery
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts'


def load_wrapper():
    loader = importlib.machinery.SourceFileLoader('xcodebuild_lane_signing', str(SCRIPTS / 'xcodebuild-lane'))
    spec = importlib.util.spec_from_loader('xcodebuild_lane_signing', loader)
    wrapper = importlib.util.module_from_spec(spec)
    loader.exec_module(wrapper)
    return wrapper


def git(*args, cwd):
    subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True)


class TrackedFilesTests(unittest.TestCase):
    def test_no_tracked_project_file_names_a_team(self):
        project = (ROOT / 'project.yml').read_text()
        pbxproj = (ROOT / 'SpokenMarginsNative.xcodeproj/project.pbxproj').read_text()
        self.assertNotRegex(project, r'DEVELOPMENT_TEAM\s*:')
        self.assertNotRegex(pbxproj, r'DEVELOPMENT_TEAM\s*=|DevelopmentTeam\s*=')

    def test_both_project_configurations_read_the_optional_local_file(self):
        pbxproj = (ROOT / 'SpokenMarginsNative.xcodeproj/project.pbxproj').read_text()
        self.assertEqual(len(re.findall(r'baseConfigurationReference = \w+ /\* Signing\.xcconfig \*/', pbxproj)), 2)
        signing = (ROOT / 'Config/Signing.xcconfig').read_text()
        self.assertIn('#include? "Local.xcconfig"', signing.splitlines())

    def test_the_local_file_is_ignored_and_the_example_says_what_goes_in_it(self):
        ignored = subprocess.run(['git', 'check-ignore', '-q', '--no-index', 'Config/Local.xcconfig'], cwd=ROOT)
        self.assertEqual(ignored.returncode, 0, 'Config/Local.xcconfig must be git-ignored')
        example = (ROOT / 'Config/Local.xcconfig.example').read_text()
        self.assertRegex(example, r'(?m)^DEVELOPMENT_TEAM = \w+$')


class LinkLocalConfigTests(unittest.TestCase):
    def setUp(self):
        self.wrapper = load_wrapper()
        self.tmp = tempfile.TemporaryDirectory()
        self.main = Path(self.tmp.name) / 'main'
        (self.main / 'Config').mkdir(parents=True)
        (self.main / 'Config/Signing.xcconfig').write_text('#include? "Local.xcconfig"\n')
        git('init', '-q', cwd=self.main)
        git('add', '.', cwd=self.main)
        git('-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'init',
            cwd=self.main)
        self.worktree = Path(self.tmp.name) / 'wt'
        git('worktree', 'add', '-q', '--detach', str(self.worktree), cwd=self.main)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_worktree_gets_the_main_checkouts_team(self):
        local = self.main / 'Config/Local.xcconfig'
        local.write_text('DEVELOPMENT_TEAM = ABCDE12345\n')
        logged = []
        link = self.wrapper.link_local_config(self.worktree, log=logged.append)
        self.assertEqual(link, self.worktree / 'Config/Local.xcconfig')
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), local.resolve())
        self.assertIn('#1841', logged[0])
        self.assertIsNone(self.wrapper.link_local_config(self.worktree), 'a second call links nothing')

    def test_nothing_is_linked_when_the_main_checkout_has_none_into_the_main_checkout_or_over_a_worktrees_own(self):
        self.assertIsNone(self.wrapper.link_local_config(self.worktree))
        self.assertFalse((self.worktree / 'Config/Local.xcconfig').is_symlink())
        (self.main / 'Config/Local.xcconfig').write_text('DEVELOPMENT_TEAM = ABCDE12345\n')
        self.assertIsNone(self.wrapper.link_local_config(self.main))
        self.assertFalse((self.main / 'Config/Local.xcconfig').is_symlink())
        own = self.worktree / 'Config/Local.xcconfig'
        own.write_text('DEVELOPMENT_TEAM = FORK000000\n')
        self.assertIsNone(self.wrapper.link_local_config(self.worktree))
        self.assertEqual(own.read_text(), 'DEVELOPMENT_TEAM = FORK000000\n')

    def test_a_folder_without_config_or_git_is_left_alone(self):
        bare = Path(self.tmp.name) / 'elsewhere'
        bare.mkdir()
        self.assertIsNone(self.wrapper.link_local_config(bare))
        (bare / 'Config').mkdir()
        self.assertIsNone(self.wrapper.link_local_config(bare))


if __name__ == '__main__':
    unittest.main()
