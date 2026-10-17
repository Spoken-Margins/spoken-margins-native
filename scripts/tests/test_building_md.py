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
        self.assertRegex(BUILDING, rf'\| iOS deployment target \| {re.escape(target)} \|')
        self.assertRegex(BUILDING, rf'`SWIFT_VERSION: "{re.escape(swift)}"`')
        self.assertIn(f'swift-tools-version: {tools}', BUILDING)

    def test_the_ci_xcode_it_cites_is_the_one_the_workflow_pins(self):
        workflow = (ROOT / '.github/workflows/hosted-app-macos.yml').read_text()
        pinned = re.search(r'/Applications/(Xcode_[\d.]+\.app)', workflow).group(1)
        self.assertIn(f'/Applications/{pinned}', BUILDING)

    def test_the_simulator_build_command_matches_the_hosted_job(self):
        self.assertIn("-scheme SpokenMarginsApp", BUILDING)
        self.assertIn("-destination 'generic/platform=iOS Simulator'", BUILDING)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', BUILDING)
        self.assertTrue((ROOT / 'SpokenMarginsNative.xcodeproj').is_dir())

    def test_the_lfs_files_it_warns_about_are_tracked_by_lfs(self):
        attributes = (ROOT / '.gitattributes').read_text()
        self.assertIn('git lfs pull', BUILDING)
        for folder in ('App/SpokenMarginsApp/Resources/Supertonic/onnx/', 'App/SpokenMarginsApp/Resources/Kitten/'):
            with self.subTest(folder=folder):
                self.assertIn(folder, BUILDING)
                self.assertIn(folder, attributes)

    def test_the_files_the_device_steps_name_exist(self):
        entitlements = list(ROOT.glob('App/*/*.entitlements'))
        self.assertEqual(len(entitlements), 4)
        self.assertIn('four `.entitlements` files', BUILDING)
        for name in re.findall(r'`(\w+\.swift)`', BUILDING):
            with self.subTest(name=name):
                self.assertTrue(list(ROOT.glob(f'App/**/{name}')), name)

    def test_the_readme_links_it(self):
        self.assertIn('(BUILDING.md)', (ROOT / 'README.md').read_text())


if __name__ == '__main__':
    unittest.main()
