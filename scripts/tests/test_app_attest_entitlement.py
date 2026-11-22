"""The App Attest entitlement and the phone-build capture button stay wired (#4818).

The app has an App Attest client (`AppAttestDeviceProvider`) behind `SM_SHARE_LINK_CREATION`. Apple refuses a key to an app
that does not carry `com.apple.developer.devicecheck.appattest-environment`, and the value must be `development` in a
phone build and `production` in an upload, so it is a build setting and never a value read at run time (the same rule as
the other gates, owner 2026-10-17). This guard reads `project.yml`, the entitlements file, the generated project and
`Info.plist`, because xcodebuild reads the committed ones, and fails if any of them loses the setting.

It also keeps the capture button out of uploads: the button's file is compiled only under `SM_APP_ATTEST_CAPTURE`, which
`SM_PHONE_BUILD_CONDITIONS_YES` turns on, and that list is on only where `SM_PHONE_BUILD` is YES
(`test_phone_build_gate.py` keeps that switch).
"""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENTITLEMENT = 'com.apple.developer.devicecheck.appattest-environment'
APP = ROOT / 'App/SpokenMarginsApp'
NESTED = '$(SM_APP_ATTEST_ENVIRONMENT_$(SM_PHONE_BUILD))'


def project_level_blocks(pbxproj: str) -> dict[str, str]:
    """The project-level Debug and Release build settings, by name (the two that set SM_PHONE_BUILD)."""
    blocks = {}
    for block, name in re.findall(r'isa = XCBuildConfiguration;(.*?)\bname = (\w+);', pbxproj, re.S):
        if re.search(r'\bSM_PHONE_BUILD = \w+;', block):
            blocks[name] = block
    return blocks


class AppAttestEntitlementTests(unittest.TestCase):
    def setUp(self):
        self.project = (ROOT / 'project.yml').read_text()
        self.pbxproj = (ROOT / 'SpokenMarginsNative.xcodeproj/project.pbxproj').read_text()

    def test_the_app_is_entitled_to_an_app_attest_environment_from_a_build_setting(self):
        entitlements = plistlib.loads((APP / 'SpokenMarginsApp.entitlements').read_bytes())
        self.assertIn(ENTITLEMENT, entitlements, 'the app lost its App Attest entitlement')
        self.assertEqual(entitlements[ENTITLEMENT], '$(SM_APP_ATTEST_ENVIRONMENT)',
                         'the environment must come from the build setting, never a fixed value')

    def test_the_app_target_uses_that_entitlements_file(self):
        self.assertIn('CODE_SIGN_ENTITLEMENTS: App/SpokenMarginsApp/SpokenMarginsApp.entitlements', self.project)
        self.assertIn('CODE_SIGN_ENTITLEMENTS = App/SpokenMarginsApp/SpokenMarginsApp.entitlements;', self.pbxproj)

    def test_project_yml_picks_development_for_phone_builds_and_production_for_uploads(self):
        self.assertIn(f'    SM_APP_ATTEST_ENVIRONMENT: {NESTED}\n', self.project)
        self.assertIn('    SM_APP_ATTEST_ENVIRONMENT_YES: development\n', self.project)
        self.assertIn('    SM_APP_ATTEST_ENVIRONMENT_NO: production\n', self.project)

    def test_the_generated_project_resolves_to_production_in_release_and_development_in_debug(self):
        blocks = project_level_blocks(self.pbxproj)
        self.assertEqual(set(blocks), {'Debug', 'Release'})
        for name, block in blocks.items():
            self.assertIn(f'SM_APP_ATTEST_ENVIRONMENT = "{NESTED}";', block, name)
            self.assertIn('SM_APP_ATTEST_ENVIRONMENT_YES = development;', block, name)
            self.assertIn('SM_APP_ATTEST_ENVIRONMENT_NO = production;', block, name)
        # An upload is a Release archive with SM_PHONE_BUILD NO, so it takes `production`; Debug and both phone builds
        # (which pass SM_PHONE_BUILD=YES) take `development`.
        self.assertIn('SM_PHONE_BUILD = NO;', blocks['Release'])
        self.assertIn('SM_PHONE_BUILD = YES;', blocks['Debug'])

    def test_no_target_or_script_fixes_the_environment_by_hand(self):
        """Only project.yml and the generated project name the setting; a phone xcconfig or script that passes a value
        would make an upload and a phone build disagree with the switch."""
        for path in [*(ROOT / 'Config').glob('*.xcconfig'), *(ROOT / 'scripts').glob('phone-build'),
                     *(ROOT / '.github/workflows').glob('*.yml')]:
            self.assertNotIn('SM_APP_ATTEST_ENVIRONMENT', path.read_text(), path.name)

    def test_the_build_describes_itself_to_the_capture_button(self):
        plist = (APP / 'Info.plist').read_text()
        self.assertIn('<key>SMAppAttestEnvironment</key>\n\t<string>$(SM_APP_ATTEST_ENVIRONMENT)</string>', plist)
        self.assertIn('<key>SMAppAttestAppID</key>\n\t<string>$(DEVELOPMENT_TEAM).$(PRODUCT_BUNDLE_IDENTIFIER)</string>', plist)
        self.assertIn('        SMAppAttestEnvironment: $(SM_APP_ATTEST_ENVIRONMENT)\n', self.project)
        self.assertIn('        SMAppAttestAppID: $(DEVELOPMENT_TEAM).$(PRODUCT_BUNDLE_IDENTIFIER)\n', self.project)

    def test_the_capture_condition_rides_the_phone_build_switch_only(self):
        conditions = re.search(r'^\s+SM_PHONE_BUILD_CONDITIONS_YES:\s*(.+)$', self.project, re.M).group(1).split()
        self.assertIn('SM_APP_ATTEST_CAPTURE', conditions)
        for line in re.findall(r'SM_PHONE_BUILD_CONDITIONS_YES = "([^"]*)";', self.pbxproj):
            self.assertIn('SM_APP_ATTEST_CAPTURE', line.split())
        for line in self.project.splitlines() + self.pbxproj.splitlines():
            if 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' in line:
                self.assertNotIn('SM_APP_ATTEST_CAPTURE', line, 'the condition must come only through the phone-build switch')

    def test_the_capture_button_is_compiled_only_in_phone_builds(self):
        source = (APP / 'Sources/SpokenMarginsApp/AppAttestCaptureRow.swift').read_text()
        code = re.sub(r'(?m)^\s*//.*$', '', source)
        start = code.index('#if SM_APP_ATTEST_CAPTURE && SM_SHARE_LINK_CREATION')
        self.assertTrue(code[:start].strip().splitlines() == ['import SessionKit', 'import SwiftUI'],
                        'nothing but the imports may sit outside the phone-build #if')
        self.assertEqual(code.count('#if '), 1)
        self.assertTrue(code.rstrip().endswith('#endif'))
        # Its only caller is inside the same condition, so an upload has no reference to it either.
        settings = (APP / 'Sources/SpokenMarginsApp/SettingsScreen.swift').read_text()
        use = settings.index('AppAttestCaptureRow()')
        self.assertIn('#if SM_APP_ATTEST_CAPTURE && SM_SHARE_LINK_CREATION', settings[max(0, use - 200):use])
        callers = [p.name for p in (APP / 'Sources').rglob('*.swift')
                   if 'AppAttestCaptureRow()' in p.read_text() and p.name != 'AppAttestCaptureRow.swift']
        self.assertEqual(callers, ['SettingsScreen.swift'])

    def test_the_capture_sends_nothing_and_keeps_no_key(self):
        source = (APP / 'Sources/SpokenMarginsApp/AppAttestCaptureRow.swift').read_text()
        code = re.sub(r'(?m)^\s*//.*$', '', source)
        for word in ('Transport', 'ProductServer', 'URLSession', 'AppAttestKeyStore', 'UserDefaults', 'Keychain', 'SecItem'):
            self.assertNotIn(word, code, f'the capture button must send and keep nothing: {word}')
        self.assertIn('ServerSendConsent.hasConsented(to: .shareLinks)', code)

    # The guard has to be able to fail.

    def test_a_blocks_reader_that_finds_a_missing_setting_fails(self):
        stripped = self.pbxproj.replace('SM_APP_ATTEST_ENVIRONMENT_NO = production;', '')
        blocks = project_level_blocks(stripped)
        self.assertNotIn('SM_APP_ATTEST_ENVIRONMENT_NO = production;', blocks['Release'])

    def test_an_entitlements_file_without_the_key_is_caught(self):
        bare = plistlib.loads(plistlib.dumps({'com.apple.security.application-groups': []}))
        self.assertNotIn(ENTITLEMENT, bare)


if __name__ == '__main__':
    unittest.main()
