import importlib.util
import json
import subprocess
import os
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock

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

    def kind(self, path, added=None):
        """(category, tier) test-scope.py gives one path; `added` is a changed line of a SessionKit source."""
        diffs = {path: f'@@ -0,0 +1 @@\n+{added}\n'} if added is not None else None
        [found] = self.classify(path, diffs=diffs)['files']
        return found['category'], found['tier']

    # The tables below decide which diffs escalate to an app build or app-hosted tests and which are held for a
    # Codex audit, so each entry of each one is checked on its own. The sample paths match only the entry they
    # are named for (`Playback` alone, not `Speech` too), or a table could lose entries unnoticed.

    def test_persistence_fixtures_are_persistence_and_t2(self):
        self.assertEqual(self.kind('Contracts/fixtures/persistence/build-29-library.json'), ('persistence', 'T2'))
        self.assertEqual(self.kind('Contracts/fixtures/persistence/nested/prior-build.sqlite'), ('persistence', 'T2'))
        self.assertEqual(self.kind('Contracts/fixtures/other/build-29-library.json'), ('validated', 'T1'))

    def test_every_packet_schema_and_fixture_folder_is_a_packet_change(self):
        for name in ('spoken-margins-package.schema.json', 'shared-commentary-layer.schema.json',
                     'interjection-share-revision.schema.json', 'portable-listening-map-proposal.schema.json'):
            with self.subTest(schema=name):
                self.assertEqual(self.kind('Contracts/schemas/' + name), ('packet', 'T2'))
                self.assertEqual(self.kind('Contracts/other/' + name), ('validated', 'T1'))  # only schemas/ counts
        self.assertEqual(self.kind('Contracts/schemas/spoken-margins-other.schema.json'), ('validated', 'T1'))
        for folder in ('interjection-packages', 'sharing'):
            with self.subTest(fixtures=folder):
                self.assertEqual(self.kind(f'Contracts/fixtures/{folder}/basic.json'), ('packet', 'T2'))
        self.assertEqual(self.kind('Contracts/fixtures/shares/basic.json'), ('validated', 'T1'))

    def test_sessionkit_targets_and_files_that_carry_packets_audio_or_persistence_escalate(self):
        for path, category in ((KIT + 'SessionKitAudio/PlaybackStallDetector.swift', 'audio'),
                               (KIT + 'SessionKitPersistence/SQLiteSessionStore.swift', 'persistence'),
                               (KIT + 'SessionKitSharing/InterjectionPackageArchive.swift', 'packet'),
                               (KIT + 'SessionKit/SharingModels.swift', 'packet'),
                               (KIT + 'SessionKit/ShareableLinkPolicy.swift', 'packet')):
            with self.subTest(path=path):
                self.assertEqual(self.kind(path), (category, 'T2'))
        self.assertEqual(self.kind(KIT + 'SessionKit/SharingSummary.swift'), ('sessionkit', 'T1'))  # not on the list

    def test_each_audio_name_pattern_makes_an_app_file_an_audio_change(self):
        for name in ('AudioRouteWatcher', 'PlaybackScreen', 'SpeechVoiceCatalog', 'SupertonicVoicePack',
                     'RemoteControlCenter', 'MediaSessionBridge'):
            with self.subTest(name=name):
                self.assertEqual(self.kind(f'{APP}{name}.swift'), ('audio', 'T3'))
        self.assertEqual(self.kind(APP + 'ExperienceLibraryScreen.swift'), ('app-ui', 'T2'))

    def test_each_packet_name_pattern_and_the_share_extension_make_an_app_file_a_packet_change(self):
        for name in ('SharingExperience', 'ImportedMarginStore', 'PackageHandoffCoordinator', 'PacketBuilder'):
            with self.subTest(name=name):
                self.assertEqual(self.kind(f'{APP}{name}.swift'), ('packet', 'T3'))
        self.assertEqual(self.kind('App/SpokenMarginsShareExtension/ShareViewController.swift'), ('packet', 'T3'))
        self.assertEqual(self.kind('App/SpokenMarginsShareExtension/Info.plist'), ('packet', 'T3'))
        self.assertEqual(self.kind('App/SpokenMarginsWidgetExtension/Info.plist'), ('app-other', 'T2'))

    def test_each_persistence_name_pattern_makes_an_app_file_a_persistence_change(self):
        for name in ('ListeningEditionStore', 'ListeningLedger'):
            with self.subTest(name=name):
                self.assertEqual(self.kind(f'{APP}{name}.swift'), ('persistence', 'T3'))
        self.assertEqual(self.kind(APP + 'StoreKitHelper.swift'), ('app-ui', 'T2'))  # `Store.swift` ends the name

    def test_each_orchestration_name_pattern_makes_an_app_file_orchestration(self):
        for name in ('Gate1AppModel', 'LibraryCoordinator', 'PlayerController', 'SessionConductor', 'DeepLinkRouter',
                     'LibraryViewModel'):
            with self.subTest(name=name):
                self.assertEqual(self.kind(f'{APP}{name}.swift'), ('app-orchestration', 'T3'))

    def test_every_kind_of_public_declaration_in_a_sessionkit_source_needs_an_app_compile(self):
        source = KIT + 'SessionKit/ListeningEdition.swift'
        for keyword in ('func', 'var', 'let', 'class', 'struct', 'enum', 'protocol', 'init', 'typealias', 'actor',
                        'subscript', 'extension', 'case', 'associatedtype'):
            with self.subTest(keyword=keyword):
                self.assertEqual(self.kind(source, f'    public {keyword} edition'), ('public-api', 'T2'))
        for line in ('    open class Edition {', '    public static let current = 1', '    public final class Edition {',
                     '    @MainActor public final class Edition {', '    @available(iOS 26, *) public func edition() {}'):
            with self.subTest(line=line):
                self.assertEqual(self.kind(source, line), ('public-api', 'T2'))
        removed = '@@ -1 +0,0 @@\n-    public func edition() {}\n'  # removing public API breaks the app as much as adding it
        [found] = self.classify(source, diffs={source: removed})['files']
        self.assertEqual(found['category'], 'public-api')
        for line in ('    // public func edition() {}', '    func edition() {}', '    let publicEdition = 1',
                     '    internal struct Edition {}', '++ public func edition() {}'):
            with self.subTest(line=line):
                self.assertEqual(self.kind(source, line), ('sessionkit', 'T1'))

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
                    '.claude/skills/lane-request/SKILL.md', 'ops/claude/sm_claude_worker.py', APP + 'PlaybackScreen.swift']
        result = self.classify(*ordinary)
        self.assertEqual(result['lane_paths'], [])
        self.assertFalse(any(note.startswith('Lane change:') for note in result['notes']))

    def test_unknown_paths_default_to_a_compile(self):
        self.assertEqual(self.classify('NewTopLevel/thing.swift')['tier'], 'T2')

    def test_real_repository_diff_runs(self):
        # The command-line path (git merge base, untracked files) must work in this checkout.
        paths, diffs = scope.changed_paths('HEAD')
        self.assertIsInstance(scope.classify(paths, diffs)['tier'], str)


class LaneRunnerRoutingTests(unittest.TestCase):
    def setUp(self):
        # The Actions runner exports the repository's LANE_HOSTED_* rollout variables; these tests mean the defaults (#2525, #2526).
        env = {key: value for key, value in os.environ.items() if not key.startswith('LANE_HOSTED_')}
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def route(self, paths=(), labels=(), online=True, **overrides):
        pr = {'labels': [{'name': label} for label in labels], 'changed_files': len(paths)}
        files = [[{'filename': path} for path in paths]]
        runners = [{'runners': [{'status': 'online' if online else 'offline', 'busy': True,
                                'labels': [{'name': 'self-hosted'}, {'name': 'sm-lane-priority'}]}]}]
        return scope.runner_routing(overrides.get('pr', pr), overrides.get('files', files),
                                    overrides.get('runners', runners))

    def assert_normal(self, result):
        self.assertEqual(result, {'lane': ['self-hosted', 'macOS', 'sm-lane'],
                                  'automerge': ['self-hosted', 'macOS', 'sm-lane-build']})

    def assert_priority(self, result):
        for job in ('lane', 'automerge'):
            self.assertEqual(result[job], ['self-hosted', 'sm-lane-priority'])

    def test_priority_label_routes_even_app_changes_and_busy_runner(self):
        self.assert_priority(self.route([APP + 'Gate1AppModel.swift'], ['priority']))

    def test_ops_only_t1_with_lane_and_docs_routes_priority(self):
        self.assert_priority(self.route(['ops/claude/sm_claude_worker.py', 'scripts/lane-runner.py',
                                         '.github/workflows/lane.yml', 'docs/workstreams/test-lane.md']))

    def test_mixed_t1_diff_stays_normal(self):
        for path in ('Packages/SessionKit/Sources/SessionKit/ListeningEdition.swift',
                     'scripts/tests/test_lane_runner.py', 'scripts/validate-contracts.py'):
            with self.subTest(path=path):
                self.assert_normal(self.route(['ops/claude/sm_claude_worker.py', path]))

    def test_build_lane_script_and_app_diff_stay_normal(self):
        for path in (APP + 'ExperienceLibraryScreen.swift', 'project.yml'):
            with self.subTest(path=path):
                self.assert_normal(self.route(['ops/claude/sm_claude_worker.py', path]))

    def test_docs_and_workflow_only_t0_stay_normal(self):
        self.assert_normal(self.route(['docs/journeys.md', '.github/workflows/lane.yml']))
        self.assert_normal(self.route())

    def test_no_online_runner_falls_back_for_both_priority_reasons(self):
        self.assert_normal(self.route([APP + 'Gate1AppModel.swift'], ['priority'], online=False))
        self.assertEqual(self.route(['ops/claude/sm_claude_worker.py'], online=False)['automerge'], ['ubuntu-latest'])
        self.assert_normal(self.route(labels=['priority'], runners=[]))

    def test_runner_must_match_all_priority_labels(self):
        self.assert_normal(self.route(labels=['priority'], runners=[{'runners': [
            {'status': 'online', 'labels': [{'name': 'sm-lane-build'}]},
            {'status': 'online', 'labels': [{'name': 'sm-lane-priority'}]}]}]))

    def test_runner_on_later_page_counts(self):
        self.assert_priority(self.route(labels=['priority'], runners=[{'runners': []}, {'runners': [
            {'status': 'online', 'labels': [{'name': 'self-hosted'}, {'name': 'sm-lane-priority'}]}]}]))

    def test_files_on_later_page_prevent_ops_only_route(self):
        self.assert_normal(self.route(['ops/codex/a.py', APP + 'ExperienceLibraryScreen.swift'], files=[
            [{'filename': 'ops/codex/a.py'}], [{'filename': APP + 'ExperienceLibraryScreen.swift'}]]))

    def test_missing_files_or_api_failure_falls_back(self):
        self.assert_normal(self.route(['ops/codex/a.py', APP + 'ExperienceLibraryScreen.swift'],
                                      files=[[{'filename': 'ops/codex/a.py'}]]))
        self.assert_normal(self.route(['ops/codex/a.py'], files=[]))
        self.assert_normal(self.route(labels=['priority'], runners={}))

    def test_rename_out_of_app_is_not_ops_only(self):
        self.assert_normal(self.route(['ops/codex/a.py'], files=[[{
            'filename': 'ops/codex/a.py', 'previous_filename': APP + 'ExperienceLibraryScreen.swift'}]]))


    # #1327: sm-lane-mac-3 sat idle for hours while automerge jobs queued behind sm-lane-mac-2.
    def runner(self, name, busy, online=True):
        return {'status': 'online' if online else 'offline', 'busy': busy,
                'labels': [{'name': 'self-hosted'}, {'name': name}]}

    def spill(self, runners, paths=(APP + 'ExperienceLibraryScreen.swift',), labels=()):
        return self.route(list(paths), labels, runners=[{'runners': runners}])

    def test_idle_priority_runner_takes_automerge_when_every_build_runner_is_busy(self):
        result = self.spill([self.runner('sm-lane-build', True), self.runner('sm-lane-build', True),
                             self.runner('sm-lane-priority', False)])
        self.assertEqual(result, {'lane': ['self-hosted', 'macOS', 'sm-lane'],
                                  'automerge': ['self-hosted', 'sm-lane-priority']})

    def test_idle_priority_runner_takes_overflow_for_ops_mixed_and_incomplete_diffs_too(self):
        runners = [self.runner('sm-lane-build', True), self.runner('sm-lane-priority', False)]
        for paths, files in [(['ops/codex/a.py', 'project.yml'], None), (['ops/codex/a.py'], [])]:
            with self.subTest(paths=paths):
                pr = {'labels': [], 'changed_files': len(paths)}
                result = scope.runner_routing(pr, files if files is not None else [[{'filename': p} for p in paths]],
                                              [{'runners': runners}])
                self.assertEqual(result['automerge'], ['self-hosted', 'sm-lane-priority'])

    def test_automerge_stays_in_the_build_queue_while_a_build_runner_is_idle(self):
        self.assert_normal(self.spill([self.runner('sm-lane-build', True), self.runner('sm-lane-build', False),
                                       self.runner('sm-lane-priority', False)]))

    def test_automerge_stays_in_the_build_queue_while_the_priority_runner_is_busy(self):
        self.assert_normal(self.spill([self.runner('sm-lane-build', True), self.runner('sm-lane-priority', True)]))

    def test_unknown_busy_state_never_counts_as_idle(self):
        runner = self.runner('sm-lane-priority', False)
        del runner['busy']
        self.assert_normal(self.spill([self.runner('sm-lane-build', True), runner]))

    def test_offline_priority_runner_never_takes_overflow(self):
        self.assert_normal(self.spill([self.runner('sm-lane-build', True),
                                       self.runner('sm-lane-priority', False, online=False)]))

    def test_idle_priority_runner_takes_automerge_when_no_build_runner_is_online(self):
        result = self.spill([self.runner('sm-lane-build', False, online=False), self.runner('sm-lane-priority', False)])
        self.assertEqual(result['automerge'], ['self-hosted', 'sm-lane-priority'])
        self.assertEqual(result['lane'], ['self-hosted', 'macOS', 'sm-lane'])

    def test_priority_work_still_routes_priority_when_the_priority_runner_is_idle(self):
        runners = [self.runner('sm-lane-build', True), self.runner('sm-lane-priority', False)]
        self.assert_priority(self.spill(runners, labels=['priority']))
        self.assert_priority(self.spill(runners, paths=['scripts/lane_slots.py']))
        self.assertEqual(self.spill(runners, paths=['ops/codex/a.py'])['automerge'], ['ubuntu-latest'])

    def test_main_runner_counts_as_a_build_runner(self):
        main = self.runner('sm-lane', False)
        main['labels'].append({'name': 'sm-lane-build'})
        self.assert_normal(self.spill([main, self.runner('sm-lane-priority', False)]))

    # #2147: on 2026-10-19 a priority job waited 40 minutes for sm-lane-mac-3 while sm-lane-mac-2 freed up three times.
    def shared_runners(self, busy=True):
        shared = self.runner('sm-lane-build', busy)
        shared['labels'].append({'name': 'sm-lane-priority'})
        return [self.runner('sm-lane-build', busy), shared]

    def test_priority_work_uses_the_build_queue_when_the_priority_runner_also_builds(self):
        for busy in (True, False):
            for kwargs in ({'labels': ['priority']}, {'paths': ['scripts/lane_slots.py']}):
                with self.subTest(busy=busy, **kwargs):
                    result = self.spill(self.shared_runners(busy), **kwargs)
                    self.assertEqual(result, {'lane': ['self-hosted', 'sm-lane-priority'],
                                              'automerge': ['self-hosted', 'macOS', 'sm-lane-build']})

    def test_a_dedicated_priority_runner_beside_a_shared_one_keeps_the_priority_queue(self):
        self.assert_priority(self.spill(self.shared_runners() + [self.runner('sm-lane-priority', True)],
                                        labels=['priority']))
        offline = self.runner('sm-lane-priority', True, online=False)
        self.assertEqual(self.spill(self.shared_runners() + [offline], labels=['priority'])['automerge'],
                         ['self-hosted', 'macOS', 'sm-lane-build'])

    def test_ordinary_work_stays_normal_with_a_shared_priority_runner(self):
        for busy in (True, False):
            with self.subTest(busy=busy):
                self.assert_normal(self.spill(self.shared_runners(busy)))

    def test_t2_lane_path_stays_normal(self):
        self.assert_normal(self.route(['ops/codex/a.py', 'project.yml']))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project.yml').write_text('script: scripts/xcodebuild-lane\n')
            result = scope.runner_routing({'labels': [], 'changed_files': 1},
                                         [[{'filename': 'scripts/xcodebuild-lane'}]], [{'runners': [{
                                             'status': 'online', 'labels': [
                                                 {'name': 'self-hosted'}, {'name': 'sm-lane-priority'}]}]}], root=root)
            self.assert_normal(result)

    def test_ops_only_goes_hosted_and_lane_only_t1_routes_priority(self):
        self.assertEqual(self.route(['ops/claude/sm_claude_worker.py'])['automerge'], ['ubuntu-latest'])
        self.assert_priority(self.route(['scripts/lane_slots.py']))

    def test_cli_reads_real_json_files_and_falls_back_on_bad_json(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ('event.json', 'files.json', 'runners.json')]
            payloads = [{'pull_request': {'labels': [{'name': 'priority'}], 'changed_files': 0}}, [],
                        [{'runners': [{'status': 'online', 'labels': [
                            {'name': 'self-hosted'}, {'name': 'sm-lane-priority'}]}]}]]
            for path, payload in zip(paths, payloads):
                path.write_text(json.dumps(payload))
            command = [sys.executable, str(SCRIPTS / 'test-scope.py'), '--runner-routing', *map(str, paths)]
            self.assert_priority(json.loads(subprocess.check_output(command, text=True)))
            paths[-1].write_text('not JSON')
            self.assert_normal(json.loads(subprocess.check_output(command, text=True)))

    def test_workflow_routes_both_jobs_with_normal_defaults(self):
        workflow = (SCRIPTS.parent / '.github/workflows/lane.yml').read_text()
        route, mac_jobs = workflow.split('\n  lane:\n', 1)
        # Routing runs on a GitHub-hosted Linux runner, never a Mac runner, so it can't queue behind lane jobs.
        self.assertIn('runs-on: ubuntu-latest', route)
        self.assertNotIn('macOS', route)
        self.assertIn('--paginate --slurp', route)
        self.assertIn('actions/runners?per_page=100', route)
        self.assertIn('pulls/$PR_NUMBER/files?per_page=100', route)
        # The base branch's tip, not the PR's recorded base, which goes stale when the base moves (#2459).
        self.assertIn('ref: ${{ github.event.pull_request.base.ref }}', route)
        for job, text, normal in [('lane', mac_jobs.split('\n  automerge:\n')[0], 'sm-lane'),
                                  ('automerge', mac_jobs.split('\n  automerge:\n')[1], 'sm-lane-build')]:
            with self.subTest(job=job):
                self.assertIn('needs: route', text)
                # A failed or skipped route falls back to the normal queues; a cancelled run stays cancelled
                # (always() would start a queued Mac job even after the run was cancelled).
                self.assertIn('!cancelled() &&', text)
                self.assertNotIn('always()', text.split('    steps:', 1)[0])
                self.assertIn(f'fromJSON(needs.route.outputs.{job} ||', text)
                self.assertIn(f'"{normal}"', text)

    def test_lane_routes_still_require_codex_or_claude_audit(self):
        result = scope.classify(['scripts/lane-runner.py'])
        self.assertIn('scripts/lane-runner.py', result['lane_paths'])
        self.assertTrue(any('Codex or Claude audit' in note for note in result['notes']))


if __name__ == '__main__':
    unittest.main()
