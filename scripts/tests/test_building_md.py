"""BUILDING.md must stay true to the repository (#1840).

A contributor follows it with nothing but a clone. These tests fail when it names a script, npm script or
version that the repository no longer has, or when the README stops pointing at it.
scripts/check-fresh-clone.sh runs the steps themselves in an empty clone.
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDING = (ROOT / 'BUILDING.md').read_text()
SCRIPT_PATH = re.compile(r'(?<![\w/.-])((?:scripts|ops)/[\w./-]+\.(?:sh|py))')


def shell_blocks(text):
    return re.findall(r'```sh\n(.*?)```', text, re.S)


class BuildingMdTests(unittest.TestCase):
    def test_every_script_it_names_exists(self):
        named = set(SCRIPT_PATH.findall(BUILDING))
        self.assertIn('scripts/bootstrap-python-tools.sh', named)
        self.assertIn('scripts/check-fresh-clone.sh', named)
        for path in sorted(named):
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file(), f'BUILDING.md names {path}, which does not exist')

    def test_every_script_in_a_command_block_is_executable_or_run_by_an_interpreter(self):
        for block in shell_blocks(BUILDING):
            for line in block.splitlines():
                path = SCRIPT_PATH.search(line)
                if path and not re.search(r'python\S*\s+' + re.escape(path.group(1)), line):
                    with self.subTest(line=line):
                        self.assertTrue((ROOT / path.group(1)).stat().st_mode & 0o111,
                                        f'{path.group(1)} is run directly but is not executable')

    def test_the_npm_scripts_it_runs_exist(self):
        scripts = json.loads((ROOT / 'package.json').read_text())['scripts']
        named = re.findall(r'npm run ([\w:-]+)', BUILDING)
        self.assertTrue(named)
        for name in named:
            with self.subTest(name=name):
                self.assertIn(name, scripts)

    def test_the_versions_it_states_are_the_ones_the_project_declares(self):
        project = (ROOT / 'project.yml').read_text()
        target = re.search(r'deploymentTarget:\s*iOS:\s*"([\d.]+)"', project).group(1)
        swift = re.search(r'SWIFT_VERSION:\s*"?([\d.]+)"?', project).group(1)
        tools = re.search(r'swift-tools-version:\s*([\d.]+)',
                          (ROOT / 'Packages/SessionKit/Package.swift').read_text()).group(1)
        self.assertRegex(BUILDING, rf'iOS deployment target\s*\|\s*{re.escape(target)}\s*\|')
        self.assertRegex(BUILDING, rf'`SWIFT_VERSION: "{re.escape(swift)}"`')
        self.assertIn(f'swift-tools-version: {tools}', BUILDING)

    def test_the_ci_xcode_it_cites_is_the_one_the_workflow_pins(self):
        workflow = (ROOT / '.github/workflows/hosted-app-macos.yml').read_text()
        pinned = re.search(r'/Applications/(Xcode_[\d.]+\.app)', workflow).group(1)
        self.assertIn(f'/Applications/{pinned}', BUILDING)

    def test_the_unsigned_build_uses_the_scheme_and_flag_the_hosted_device_job_uses(self):
        workflow = (ROOT / '.github/workflows/hosted-app-macos.yml').read_text()
        self.assertIn('-scheme SpokenMarginsApp ', workflow)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', workflow)
        self.assertIn('-scheme SpokenMarginsApp ', BUILDING)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', BUILDING)
        self.assertIn("-destination 'generic/platform=iOS Simulator'", BUILDING)
        self.assertRegex((ROOT / 'project.yml').read_text(), r'(?m)^schemes:\n  SpokenMarginsApp:')

    def test_the_script_runs_the_same_simulator_build_the_page_documents(self):
        def words(text):
            return sorted(text.replace('\\', ' ').replace("'", ' ').replace('"', ' ').split())

        page = re.search(r'```sh\n(xcodebuild .*?)```', BUILDING, re.S).group(1)
        script = (ROOT / 'scripts/check-fresh-clone.sh').read_text()
        line = next(line for line in script.splitlines() if 'step "simulator build"' in line)
        command = line[line.index('xcodebuild -project'):]
        self.assertEqual(words(command), words(page))

    def test_the_lfs_files_it_warns_about_are_tracked_by_lfs(self):
        attributes = (ROOT / '.gitattributes').read_text()
        self.assertIn('git lfs pull', BUILDING)
        for folder in ('App/SpokenMarginsApp/Resources/Kitten/',):  # Supertonic's model is a download (#1820)
            with self.subTest(folder=folder):
                self.assertIn(folder, BUILDING)
                self.assertIn(folder, attributes)

    def test_the_device_steps_point_at_every_file_naming_the_app_group(self):
        group = 'group.com.spokenmargins.native'
        self.assertIn(f'grep -rl {group} App', BUILDING)
        named = [path for path in (ROOT / 'App').rglob('*')
                 if path.suffix in ('.swift', '.entitlements') and group in path.read_text(errors='ignore')]
        self.assertTrue(any(path.suffix == '.entitlements' for path in named))
        self.assertTrue(any(path.suffix == '.swift' for path in named))

    def test_the_readme_links_it(self):
        self.assertIn('(BUILDING.md)', (ROOT / 'README.md').read_text())


if __name__ == '__main__':
    unittest.main()
