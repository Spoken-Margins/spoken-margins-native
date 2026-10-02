import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('test_scope', SCRIPTS / 'test-scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)

APP = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/'
KIT = 'Packages/SessionKit/Sources/'


class TestScopeTests(unittest.TestCase):
    """Synthetic repository layout, so tier rules are checked independently of today's file list."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        files = {
            'Packages/SessionKit/Tests/SessionKitTests/ListeningEditionTests.swift':
                'import XCTest\n@testable import SessionKit\nfinal class ListeningEditionTests: XCTestCase {}\n',
            'Packages/SessionKit/Tests/SessionKitTests/SQLiteSessionStoreSafetyTests.swift':
                'import XCTest\n@testable import SessionKitPersistence\nfinal class SQLiteSessionStoreSafetyTests: XCTestCase {}\n',
            'Packages/SessionKit/Tests/SessionKitTests/SharingTests.swift':
                'import XCTest\nimport SessionKitSharing\nfinal class SharingTests: XCTestCase {}\n',
            'App/SpokenMarginsAppTests/MixedPlaybackAudioSessionTests.swift':
                'import XCTest\nfinal class MixedPlaybackAudioSessionTests: XCTestCase {}\n',
            'App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift':
                'import XCTest\nfinal class Gate1AppModelWorkflowTests: XCTestCase {}\n',
            'project.yml': 'script: "$SRCROOT/scripts/normalize-embedded-framework-minimum-os.sh"\n',
        }
        for path, text in files.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)

    def tearDown(self):
        self.temporary.cleanup()

    def classify(self, *paths, diffs=None):
        return scope.classify(paths, diffs, root=self.root)

    def test_docs_only_needs_nothing(self):
        result = self.classify('docs/journeys.md', 'research/C1/notes.txt', 'AGENTS.md', '.claude/skills/x/SKILL.md')
        self.assertEqual(result['tier'], 'T0')
        self.assertEqual(result['run'], [])
        self.assertIsNone(result['lane_request'])

    def test_no_changes_is_t0(self):
        self.assertEqual(self.classify()['tier'], 'T0')

    def test_sessionkit_only_runs_the_matching_suite(self):
        result = self.classify(KIT + 'SessionKit/ListeningEdition.swift')
        self.assertEqual(result['tier'], 'T1')
        self.assertIn("swift test --package-path Packages/SessionKit --filter 'ListeningEditionTests'", result['run'])
        self.assertFalse(any('xcodebuild' in command for command in result['run']))

    def test_sessionkit_public_api_change_needs_an_app_compile(self):
        diff = '@@ -1 +1 @@\n-    func edition() {}\n+    public func edition() {}\n'
        result = self.classify(KIT + 'SessionKit/ListeningEdition.swift',
                               diffs={KIT + 'SessionKit/ListeningEdition.swift': diff})
        self.assertEqual(result['tier'], 'T2')
        self.assertIn('SessionKit public API', result['why'])

    def test_comment_mentioning_public_is_not_an_api_change(self):
        diff = '@@ -1 +1 @@\n+    // public for now\n+    let open = true\n'
        result = self.classify(KIT + 'SessionKit/ListeningEdition.swift',
                               diffs={KIT + 'SessionKit/ListeningEdition.swift': diff})
        self.assertEqual(result['tier'], 'T1')

    def test_app_ui_needs_both_compiles(self):
        result = self.classify(APP + 'ExperienceLibraryScreen.swift')
        self.assertEqual(result['tier'], 'T2')
        self.assertEqual(result['why'], ['app UI'])
        self.assertEqual(sum('scripts/xcodebuild-lane' in c for c in result['run']), 2)
        self.assertTrue(any('T4 journey' in note for note in result['notes']))

    def test_app_audio_session_escalates_to_app_hosted_tests(self):
        result = self.classify(APP + 'MixedPlaybackAudioSession.swift')
        self.assertEqual(result['tier'], 'T3')
        self.assertIn('audio', result['why'][0])
        self.assertIn('SpokenMarginsAppTests/MixedPlaybackAudioSessionTests', result['lane_request'])

    def test_sessionkit_audio_escalates_one_tier(self):
        result = self.classify(KIT + 'SessionKitAudio/PlaybackStallDetector.swift')
        self.assertEqual(result['tier'], 'T2')

    def test_persistence_escalates_and_names_the_store_tests(self):
        result = self.classify(KIT + 'SessionKitPersistence/SQLiteSessionStore.swift')
        self.assertEqual(result['tier'], 'T2')
        self.assertIn('persistence', result['why'][0])
        self.assertTrue(any('SQLiteSessionStoreSafetyTests' in c for c in result['run']))
        self.assertTrue(any('previous build must still open' in n for n in result['notes']))

    def test_app_persistence_is_t3(self):
        self.assertEqual(self.classify(APP + 'ListeningEditionStore.swift')['tier'], 'T3')

    def test_packet_changes_escalate_and_carry_the_compatibility_note(self):
        for path in (KIT + 'SessionKitSharing/InterjectionPackageArchive.swift',
                     KIT + 'SessionKit/ShareableLinkPolicy.swift',
                     'Contracts/schemas/spoken-margins-package.schema.json',
                     'Contracts/fixtures/interjection-packages/basic.json'):
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertEqual(result['tier'], 'T2')
                self.assertTrue(any('Build 29' in n for n in result['notes']))
        self.assertEqual(self.classify(APP + 'SharingExperience.swift')['tier'], 'T3')

    def test_orchestration_is_t3_with_matching_tests(self):
        result = self.classify(APP + 'Gate1AppModel.swift')
        self.assertEqual(result['tier'], 'T3')
        self.assertIn('SpokenMarginsAppTests/Gate1AppModelWorkflowTests', result['lane_request'])
        self.assertEqual(result['app_tests'], ['Gate1AppModelWorkflowTests'])  # the lane runner adds these (#351)

    def test_ui_test_scripts_are_compile_only_and_add_nothing_to_t3(self):
        # #445: scripted journeys run in the integration run, never as a per-PR gate. Before, a UI test file
        # fell through to the app rules, so a name with "Playback" in it asked for a T3.
        ui = 'App/SpokenMarginsAppUITests/'
        for path in (ui + 'EmojiArticlePlaybackUITests.swift', ui + 'SharePacketJourneyUITests.swift',
                     ui + 'Gate1FlowUITests.swift', ui + 'Fixtures/emoji-article-crash-regression.txt'):
            with self.subTest(path=path):
                result = self.classify(path)
                self.assertEqual(result['tier'], 'T2')
                self.assertEqual(result['why'], ['UI test scripts (compile only)'])
                self.assertIsNone(result['lane_request'])
                self.assertEqual(result['app_tests'], [])
                self.assertEqual(sum('scripts/xcodebuild-lane' in c for c in result['run']), 2)
                self.assertTrue(any('integration run' in note for note in result['notes']))
        (self.root / ui).mkdir(parents=True)
        (self.root / ui / 'MixedPlaybackAudioSessionJourneyUITests.swift').write_text(
            'import XCTest\nfinal class MixedPlaybackAudioSessionJourneyUITests: XCTestCase {}\n')
        result = self.classify(APP + 'MixedPlaybackAudioSession.swift', ui + 'MixedPlaybackAudioSessionJourneyUITests.swift')
        self.assertEqual(result['tier'], 'T3')  # the app change still asks for its own app tests
        self.assertEqual(result['app_tests'], ['MixedPlaybackAudioSessionTests'])
        self.assertNotIn('UITests', result['lane_request'])

    def test_mixed_diff_takes_the_highest_tier_and_keeps_every_suggestion(self):
        result = self.classify('docs/testing.md', KIT + 'SessionKit/ListeningEdition.swift',
                               APP + 'ExperienceLibraryScreen.swift')
        self.assertEqual(result['tier'], 'T2')
        self.assertTrue(result['run'][0].startswith('swift test'))

    def test_scripts_run_runner_tests_unless_the_build_uses_them(self):
        self.assertEqual(self.classify('scripts/test-scope.py')['tier'], 'T1')
        self.assertEqual(self.classify('scripts/normalize-embedded-framework-minimum-os.sh')['tier'], 'T2')

    def test_ops_tools_get_their_own_host_tests_not_a_compile(self):
        # ops/ (the VPS Dial gate, the Mac's Codex audit) fell to "unclassified" and a simulator and device build.
        result = self.classify('ops/dial/dial_gate.py', 'ops/dial/deploy.sh', 'ops/codex/audit.py')
        self.assertEqual(result['tier'], 'T1')
        self.assertEqual(result['why'], ['VPS and Mac ops tools, with their own Python tests'])
        self.assertIn('.venv/bin/python -m unittest discover -s ops/dial', result['run'])
        self.assertIn('.venv/bin/python -m unittest discover -s ops/codex', result['run'])
        self.assertFalse(any('xcodebuild' in command for command in result['run']))
        self.assertEqual(self.classify('ops/README.md')['tier'], 'T0')

    def test_lane_paths_are_listed_so_the_runner_holds_them_for_an_audit(self):
        # Owner rule 2026-10-01: a lane PR merges on PASS plus a clean Codex audit, like a packet change.
        lane = ['.github/workflows/lane.yml', '.github/workflows/linux-t1.yml', 'scripts/lane-runner.py',
                'scripts/lane_sim.py', 'scripts/lane_slots.py', 'scripts/lane_guard.py', 'scripts/lane-sim-boot',
                'scripts/xcodebuild-lane', 'scripts/host-test-lane', 'scripts/install-lane-guard.py',
                'scripts/test-scope.py', 'scripts/hot_file_ratchet.py', 'scripts/merge_audit.py',
                'scripts/verify-tests.py', 'TestPlans/AppBehavior.xctestplan', 'TestPlans/AudioAdapters.xctestplan']
        result = self.classify(*lane)
        self.assertEqual(result['lane_paths'], sorted(lane))
        self.assertTrue(any(note.startswith('Lane change:') for note in result['notes']))
        # Ordinary PRs stay off it: the lane's tests, the Test Desk's journey list, other scripts, docs.
        ordinary = ['scripts/tests/test_lane_runner.py', 'TestPlans/scripted-journeys.json', 'scripts/phone-build',
                    'scripts/validate-contracts.py', 'docs/workstreams/test-lane.md', '.github/ISSUE_TEMPLATE/bug.md',
                    '.claude/skills/lane-request/SKILL.md', 'ops/codex/sm_codex_worker.py', APP + 'PlaybackScreen.swift']
        result = self.classify(*ordinary)
        self.assertEqual(result['lane_paths'], [])
        self.assertFalse(any(note.startswith('Lane change:') for note in result['notes']))

    def test_unknown_paths_default_to_a_compile(self):
        self.assertEqual(self.classify('NewTopLevel/thing.swift')['tier'], 'T2')

    def test_real_repository_diff_runs(self):
        # The command-line path (git merge base, untracked files) must work in this checkout.
        paths, diffs = scope.changed_paths('HEAD')
        self.assertIsInstance(scope.classify(paths, diffs)['tier'], str)


if __name__ == '__main__':
    unittest.main()
