"""Phone-build-only settings reach both phone builds and never an upload (#3086, #3354).

project.yml turns the conditions in SM_PHONE_BUILD_CONDITIONS_YES on when SM_PHONE_BUILD is YES: in Debug, and in
the two phone builds, which pass Config/PhoneBuild.xcconfig (it also turns SM_SHARE_LINK_CREATION on). An upload is
a Release archive without it. Gates are set at build time, never switched on remotely (owner, 2026-10-17), so these
checks keep the switch where it is. Until #3354 only the Mac build passed SM_PHONE_BUILD=YES and this file checked
only the Mac one, so the GitHub-hosted build the owner installs had neither setting.
"""
import importlib.util
import re
import shlex
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from sm_paths import owner_overlay  # noqa: E402

PHONE_BUILDS = {'scripts/phone-build', '.github/workflows/phone-build.yml'}
XCCONFIG = 'Config/PhoneBuild.xcconfig'
_spec = importlib.util.spec_from_file_location('phone_build_settings', ROOT / 'scripts/phone_build_settings.py')
phone_build_settings = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(phone_build_settings)


def hosted_archive_settings(workflow: str) -> tuple[list[str], set[str]]:
    """The hosted archive command's -xcconfig files and its SM_* settings, other than the commit stamp."""
    step = workflow[workflow.index('- name: Archive the Release app'):]
    step = step[:step.index('\n      - ', 1)]
    command = step[step.index('xcodebuild '):step.index(' archive 2>&1')].replace('\\\n', ' ')
    words = shlex.split(command)
    files = [words[i + 1] for i, word in enumerate(words) if word == '-xcconfig']
    return files, {w for w in words if re.match(r'SM_\w+=', w) and not w.startswith('SM_BUILD_COMMIT=')}


def mac_build_settings(script: str) -> tuple[list[str], set[str]]:
    """The same for the Mac's signed Release build in scripts/phone-build."""
    start = script.index("'-configuration', 'Release', '-destination', 'generic/platform=iOS'")
    call = script[start:script.index("'build'], src, log)", start)]
    files = ['Config/PhoneBuild.xcconfig'] if "'-xcconfig', str(xcconfig)" in call and \
        "own = src / 'Config' / 'PhoneBuild.xcconfig'" in script else []
    return files, set(re.findall(r"'(SM_(?!BUILD_COMMIT)\w+=[^']*)'", call))


class PhoneBuildGateTests(unittest.TestCase):
    def setUp(self):
        self.project = (ROOT / 'project.yml').read_text()

    def spike_conditions(self):
        match = re.search(r'^\s+SM_PHONE_BUILD_CONDITIONS_YES:\s*(.+)$', self.project, re.M)
        self.assertIsNotNone(match, 'project.yml lost SM_PHONE_BUILD_CONDITIONS_YES')
        return match.group(1).split()

    def test_release_keeps_the_switch_off_and_debug_turns_it_on(self):
        configs = re.search(r'^  configs:\n((?:    .*\n)+)', self.project, re.M)
        self.assertIsNotNone(configs, 'project.yml lost its project-level configs')
        block = configs.group(1)
        self.assertRegex(block, r'    Release:\n      SM_PHONE_BUILD: NO\n')
        self.assertRegex(block, r'    Debug:\n      SM_PHONE_BUILD: YES\n')

    def test_the_generated_project_keeps_release_off(self):
        """xcodebuild reads the committed pbxproj, not project.yml: a stale or hand-edited one must fail too."""
        pbxproj = (ROOT / 'SpokenMarginsNative.xcodeproj/project.pbxproj').read_text()
        switches = set()
        for block, name in re.findall(r'isa = XCBuildConfiguration;(.*?)\bname = (\w+);', pbxproj, re.S):
            value = re.search(r'\bSM_PHONE_BUILD = (\w+);', block)
            if value:
                switches.add((name, value.group(1)))
            for condition in self.spike_conditions():
                for line in block.splitlines():
                    if 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' in line:
                        self.assertNotIn(condition, line, f'{name} sets {condition} outside the switch')
        self.assertEqual(switches, {('Debug', 'YES'), ('Release', 'NO')})

    def test_spike_conditions_are_reached_only_through_the_switch(self):
        conditions = self.spike_conditions()
        self.assertIn('SM_LOCKED_MARGIN_SPIKE', conditions)
        for line in self.project.splitlines():
            if 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' in line:
                self.assertIn('$(SM_PHONE_BUILD_CONDITIONS_$(SM_PHONE_BUILD))', line)
                for condition in conditions:
                    self.assertNotIn(condition, line, 'a spike condition set outside the phone-build switch')

    def test_both_phone_builds_pass_the_same_settings_from_the_one_file(self):
        """#3354: the two builds' flag sets must match. Each passes the file and adds no SM_* setting of its own."""
        hosted = hosted_archive_settings((ROOT / '.github/workflows/phone-build.yml').read_text())
        mac = mac_build_settings((ROOT / 'scripts/phone-build').read_text())
        self.assertEqual(hosted, ([XCCONFIG], set()), 'the hosted archive must pass only -xcconfig ' + XCCONFIG)
        self.assertEqual(mac, hosted, 'the Mac and hosted phone builds pass different phone settings')

    def test_the_drift_this_guards_against_is_caught(self):
        """The hosted archive as it was at 26f30d4a2, without the file, and a Mac build with an extra setting."""
        workflow = (ROOT / '.github/workflows/phone-build.yml').read_text()
        self.assertNotEqual(hosted_archive_settings(workflow.replace(' -xcconfig ' + XCCONFIG, '')),
                            mac_build_settings((ROOT / 'scripts/phone-build').read_text()))
        script = (ROOT / 'scripts/phone-build').read_text().replace(
            "f'SM_BUILD_COMMIT={sha}', 'build']", "f'SM_BUILD_COMMIT={sha}', 'SM_PHONE_BUILD=YES', 'build']")
        self.assertNotEqual(mac_build_settings(script), hosted_archive_settings(workflow))

    def test_the_file_turns_on_every_phone_setting_and_each_one_reaches_the_info_plist(self):
        settings = phone_build_settings.read(ROOT / XCCONFIG)
        self.assertEqual(settings, {'SM_PHONE_BUILD': 'YES', 'SM_SHARE_LINK_CREATION': 'YES'})
        self.assertEqual(set(phone_build_settings.PLIST_KEYS), set(settings))
        plist = (ROOT / 'App/SpokenMarginsApp/Info.plist').read_text()
        for name, key in phone_build_settings.PLIST_KEYS.items():
            self.assertIn(f'<key>{key}</key>\n\t<string>$({name})</string>', plist)
            self.assertIn(f'        {key}: $({name})\n', self.project)

    def test_only_the_phone_builds_turn_the_settings_on(self):
        turned_on, uses_file = set(), set()
        for folder in ('scripts', '.github', 'ops', 'Config'):
            for path in (ROOT / folder).rglob('*'):
                relative = path.relative_to(ROOT).as_posix()
                if not path.is_file() or relative.startswith('scripts/tests/') or relative == XCCONFIG:
                    continue
                try:
                    text = path.read_text()
                except (UnicodeDecodeError, OSError):
                    continue
                if re.search(r'SM_PHONE_BUILD\s*=\s*YES', text):
                    turned_on.add(relative)
                if 'PhoneBuild.xcconfig' in text:
                    uses_file.add(relative)
        self.assertEqual(turned_on, set(), 'only Config/PhoneBuild.xcconfig turns SM_PHONE_BUILD on')
        # phone_build_settings.py reads the file to check a built app; it builds nothing.
        self.assertEqual(uses_file - {'scripts/phone_build_settings.py'}, PHONE_BUILDS)

    def test_the_upload_steps_never_pass_the_settings(self):
        """The upload steps are prose that agents follow by hand; this keeps the prose clean.

        The public guide carries the generic steps; the full ones are in the owner overlay (#1854), which is checked
        too where it is on the machine."""
        guides = [ROOT / 'AGENTS.md']
        overlay = owner_overlay(__file__)
        if overlay:
            guides.append(overlay)
        for path in guides:
            guide = path.read_text()
            upload = guide[guide.index('## Releasing a build'):]
            for word in ('SM_PHONE_BUILD', 'PhoneBuild.xcconfig', '-xcconfig'):
                self.assertNotIn(word, upload, f'{path.name}: {word}')
        if overlay:
            self.assertIn('-configuration Release', overlay.read_text())
        # The export plists can't change compiled settings, but none may name the file either.
        for plist in [*(ROOT / 'Config').glob('ExportOptions-*.plist'), ROOT / 'scripts/TestFlightUploadOptions.plist']:
            self.assertNotIn('PhoneBuild', plist.read_text(), plist.name)


if __name__ == '__main__':
    unittest.main()
