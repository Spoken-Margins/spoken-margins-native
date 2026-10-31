"""Phone-build-only spikes never reach an upload (#3086).

project.yml turns the conditions in SM_PHONE_BUILD_CONDITIONS_YES on when SM_PHONE_BUILD is YES: in Debug, and in
the two phone builds, which pass it on the command line. An upload is a Release archive without it. Gates are set
at build time, never switched on remotely (owner, 2026-10-17), so these checks keep the switch where it is.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PHONE_BUILDS = {'scripts/phone-build', '.github/workflows/phone-build.yml'}


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

    def test_spike_conditions_are_reached_only_through_the_switch(self):
        conditions = self.spike_conditions()
        self.assertIn('SM_LOCKED_MARGIN_SPIKE', conditions)
        for line in self.project.splitlines():
            if 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' in line:
                self.assertIn('$(SM_PHONE_BUILD_CONDITIONS_$(SM_PHONE_BUILD))', line)
                for condition in conditions:
                    self.assertNotIn(condition, line, 'a spike condition set outside the phone-build switch')

    def test_only_the_phone_builds_turn_the_switch_on(self):
        turned_on = set()
        for folder in ('scripts', '.github'):
            for path in (ROOT / folder).rglob('*'):
                relative = path.relative_to(ROOT).as_posix()
                if not path.is_file() or relative.startswith('scripts/tests/'):
                    continue
                try:
                    text = path.read_text()
                except (UnicodeDecodeError, OSError):
                    continue
                if 'SM_PHONE_BUILD=YES' in text:
                    turned_on.add(relative)
        self.assertLessEqual(turned_on, PHONE_BUILDS)
        self.assertIn('scripts/phone-build', turned_on)

    def test_the_upload_steps_never_pass_the_switch(self):
        guide = (ROOT / 'AGENTS.md').read_text()
        upload = guide[guide.index('## Releasing a build'):]
        self.assertIn('-configuration Release', upload)
        self.assertNotIn('SM_PHONE_BUILD', upload)


if __name__ == '__main__':
    unittest.main()
