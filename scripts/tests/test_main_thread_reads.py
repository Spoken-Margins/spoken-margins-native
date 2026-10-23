"""scripts/main_thread_reads.py: the main-thread store/file/audio scanner and its ratchet (#2257).

The table of neighbouring cases below is the scanner's honest blind-spot list: each case says whether the call is a
row and why. A case that starts failing means the heuristic moved, and the docstring of the script needs to follow.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import main_thread_reads as mtr  # noqa: E402

ROOT = SCRIPTS.parent
APIS = mtr.store_apis(ROOT)


def scan(**files):
    """Rows for in-memory Swift sources, keyed `name=source` (an underscore stands for a dot in the file name)."""
    rows, skipped = mtr.scan([(f'App/X/Sources/{name}.swift', src) for name, src in files.items()], APIS)
    return rows


def apis(rows, klass=None):
    return sorted(r['api'] for r in rows if klass is None or r['class'] == klass)


MODEL = '@MainActor\nfinal class Model {\n    var store: SQLiteSessionStore?\n%s\n}\n'


class WhatCountsAsMainThread(unittest.TestCase):
    def test_a_store_read_in_a_main_actor_class_is_a_row(self):
        rows = scan(Model=MODEL % '    func reload() { _ = try? store?.listItems() }')
        self.assertEqual(apis(rows), ['store.listItems'])
        self.assertEqual(rows[0]['class'], 'store-whole-table-read')
        self.assertEqual(rows[0]['function'], 'Model.reload')

    def test_cases_that_are_not_rows(self):
        cases = {
            'task detached': MODEL % '    func f() { Task.detached { _ = try? store?.listItems() } }',
            'detached with priority': MODEL % '    func f() { Task.detached(priority: .utility) { _ = try? store?.listItems() } }',
            'detached result assigned to a local': MODEL % '    func f() async throws {\n        let n = try await Task.detached(priority: .utility) { try store?.listItems().count }.value\n        _ = n\n    }',
            'nonisolated async func': MODEL % '    nonisolated func f() async { _ = try? store?.listItems() }',
            'global dispatch queue': MODEL % '    func f() { DispatchQueue.global().async { _ = try? store?.listItems() } }',
            'task group child': MODEL % '    func f() async { await withTaskGroup(of: Int.self) { g in g.addTask { _ = try? store?.listItems(); return 1 } } }',
            'actor': 'actor Reader {\n var store: SQLiteSessionStore?\n func f() { _ = try? store?.listItems() }\n}\n',
            'plain type, no caller': 'final class Plain {\n var store: SQLiteSessionStore?\n func f() { _ = try? store?.listItems() }\n}\n',
            'comment': MODEL % '    func f() {\n        // store.listItems() would be slow here\n    }',
            'string': MODEL % '    func f() { let s = "store.listItems()"; print(s) }',
            'multiline string': MODEL % '    func f() {\n        let s = """\n        store.listItems()\n        """\n    }',
            'block comment': MODEL % '    func f() {\n        /* store.listItems() */\n    }',
            'receiver that is not a store': MODEL % '    var cache: Cache?\n    func f() { _ = cache?.listItems() }',
            'a method the store does not have': MODEL % '    func f() { _ = try? store?.countEverything() }',
        }
        for name, source in cases.items():
            with self.subTest(name):
                self.assertEqual(scan(Model=source), [])

    def test_cases_that_are_rows(self):
        cases = {
            'plain task inherits the main actor': MODEL % '    func f() { Task { _ = try? store?.listItems() } }',
            'task marked main actor from a plain type': 'final class Plain {\n var store: SQLiteSessionStore?\n func f() { Task { @MainActor in _ = try? store?.listItems() } }\n}\n',
            'MainActor.run': 'final class Plain {\n var store: SQLiteSessionStore?\n func f() async { await MainActor.run { _ = try? store?.listItems() } }\n}\n',
            'dispatch main': 'final class Plain {\n var store: SQLiteSessionStore?\n func f() { DispatchQueue.main.async { _ = try? store?.listItems() } }\n}\n',
            'detached task hands back to main': MODEL % '    func f() { Task.detached { await MainActor.run { _ = try? self.store?.listItems() } } }',
            'a main-actor func in a plain type': 'final class Plain {\n var store: SQLiteSessionStore?\n @MainActor func f() { _ = try? store?.listItems() }\n}\n',
            'a SwiftUI view': 'struct Screen: View {\n var store: SQLiteSessionStore\n var body: some View { Text("\\(try! store.listItems().count)") }\n}\n',
            'closure handed to an unknown API keeps main': MODEL % '    func f() { observe { _ = try? self.store?.listItems() } }',
            'self.store and requireStore()': MODEL % '    func f() throws { _ = try self.store?.listItems(); _ = try requireStore().listItems() }',
            'nonisolated func inside a main type is not a row, its main caller is': MODEL % '    nonisolated static func read(_ store: SQLiteSessionStore) -> Int { (try? store.listItems().count) ?? 0 }\n    func f(_ s: SQLiteSessionStore) { _ = Self.read(s) }',
        }
        for name, source in cases.items():
            with self.subTest(name):
                self.assertTrue(scan(Model=source), 'expected a row')

    def test_an_extension_in_another_file_of_a_main_actor_type_is_main(self):
        rows = scan(Model=MODEL % '', Model_Library='extension Model {\n func reload() { _ = try? store?.listItems() }\n}\n')
        self.assertEqual(apis(rows), ['store.listItems'])
        self.assertEqual(rows[0]['file'], 'App/X/Sources/Model_Library.swift')

    def test_an_extension_of_a_type_that_is_not_main_actor_is_not(self):
        self.assertEqual(scan(Plain='final class Plain {}\n', Plain_Ext='extension Plain {\n var store: SQLiteSessionStore? { nil }\n func f() { _ = try? store?.listItems() }\n}\n'), [])

    def test_the_same_api_is_told_apart_by_its_arguments(self):
        rows = scan(Model=MODEL % '    func f() throws { _ = try store?.loadSessions(); _ = try store?.loadSessions(itemId: "a") }')
        self.assertEqual(sorted(r['class'] for r in rows), ['store-read', 'store-whole-table-read'])


class HelpersAndLoops(unittest.TestCase):
    HELPER = 'enum Loader {\n    static func load(store: SQLiteSessionStore) throws -> Int { try store.listItems().count }\n}\n'

    def test_a_sync_helper_called_from_main_is_a_row_at_the_call(self):
        rows = scan(Loader=self.HELPER, Model=MODEL % '    func f(_ s: SQLiteSessionStore) { _ = try? Loader.load(store: s) }')
        self.assertEqual([(r['api'], r['kind']) for r in rows], [('via Loader.load', 'helper')])
        self.assertEqual(rows[0]['detail'], ['store.listItems'])

    def test_the_helper_is_found_through_a_second_helper(self):
        outer = 'enum Outer {\n static func go(_ s: SQLiteSessionStore) { _ = try? Loader.load(store: s) }\n}\n'
        rows = scan(Loader=self.HELPER, Outer=outer, Model=MODEL % '    func f(_ s: SQLiteSessionStore) { Outer.go(s) }')
        self.assertEqual(apis(rows), ['via Outer.go'])
        self.assertEqual(rows[0]['detail'], ['store.listItems'])

    def test_an_async_nonisolated_helper_leaves_the_main_thread(self):
        helper = 'enum Loader {\n    static func load(store: SQLiteSessionStore) async throws -> Int { try store.listItems().count }\n}\n'
        self.assertEqual(scan(Loader=helper, Model=MODEL % '    func f(_ s: SQLiteSessionStore) async { _ = try? await Loader.load(store: s) }'), [])

    def test_a_helper_called_inside_detached_work_is_not_a_row(self):
        self.assertEqual(scan(Loader=self.HELPER, Model=MODEL % '    func f(_ s: SQLiteSessionStore) { Task.detached { _ = try? Loader.load(store: s) } }'), [])

    def test_a_variable_receiver_is_not_guessed(self):
        rows = scan(Loader=self.HELPER, Model=MODEL % '    func f(_ s: SQLiteSessionStore, thing: Other) { _ = thing.load(store: s) }')
        self.assertEqual(rows, [])

    def test_a_variable_receiver_picks_its_declared_type_not_the_first_file(self):
        # The audit on 6655e67: `engine.pause()` took the first type containing "engine", so an app file sorting
        # ahead of SessionEngine stole the call and hid SessionEngine's reads.
        kitten = 'final class KittenEngine {\n    func pause() { }\n}\n'
        session = 'final class SessionEngine {\n    var store: SQLiteSessionStore?\n    func pause() { _ = try? store?.listItems() }\n}\n'
        model = '@MainActor\nfinal class Model {\n    var engine: SessionEngine?\n    func f() { engine?.pause() }\n}\n'
        rows = scan(AKitten=kitten, Session=session, Model=model)
        self.assertEqual([r['api'] for r in rows if r['file'].endswith('Model.swift')], ['via SessionEngine.pause'])

    def test_an_ambiguous_variable_receiver_is_skipped_and_counted(self):
        kitten = 'final class KittenEngine {\n    var store: SQLiteSessionStore?\n    func pause() { _ = try? store?.listItems() }\n}\n'
        session = 'final class SessionEngine {\n    var store: SQLiteSessionStore?\n    func pause() { _ = try? store?.listItems() }\n}\n'
        model = '@MainActor\nfinal class Model {\n    func f(engine: AnyObject) { (engine as! SessionEngine).pause(); run(engine) }\n    func g() { let engine = make(); engine.pause() }\n}\n'
        files = [(f'App/X/Sources/{n}.swift', s) for n, s in (('AKitten', kitten), ('Session', session), ('Model', model))]
        rows, skipped = mtr.scan(files, APIS)
        self.assertEqual([r['api'] for r in rows if r['file'].endswith('Model.swift')], [])
        self.assertEqual(skipped['ambiguous-callee'], 1)

    def test_a_local_reused_for_two_types_takes_the_nearest_declaration(self):
        # Gate1AppModel+ImportInbox declares `let handoffStore = try resolved…HandoffStore()` twice, for two types.
        link = 'final class SourceLinkHandoffStore {\n    func pendingPayloadIDs() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: "a") }\n}\n'
        text = 'final class BrowserTextHandoffStore {\n    func pendingPayloadIDs() throws -> [String] { [] }\n}\n'
        model = ('@MainActor\nfinal class Model {\n    func f() throws {\n'
                 '        let handoffStore = try resolvedBrowserTextHandoffStore()\n        _ = try handoffStore.pendingPayloadIDs()\n'
                 '        let other = 1\n    }\n    func g() throws {\n'
                 '        let handoffStore = try resolvedSourceLinkHandoffStore()\n        _ = try handoffStore.pendingPayloadIDs()\n    }\n}\n')
        rows = scan(ABrowser=text, Link=link, Model=model)
        self.assertEqual([(r['function'], r['api']) for r in rows if r['file'].endswith('Model.swift')],
                         [('Model.g', 'via SourceLinkHandoffStore.pendingPayloadIDs')])

    def test_a_receiver_annotated_with_a_protocol_is_not_guessed(self):
        impl = 'final class SupertonicSpeechClient {\n    func play() { _ = try? Data(contentsOf: URL(fileURLWithPath: "a")) }\n}\n'
        model = '@MainActor\nfinal class Model {\n    let speech: SpeechClient\n    func f() { speech.play() }\n}\n'
        self.assertEqual([r for r in scan(Impl=impl, Model=model) if r['file'].endswith('Model.swift')], [])

    def test_a_variable_receiver_named_like_the_type_picks_that_type(self):
        kitten = 'final class KittenSessionEngine {\n    func pause() { }\n}\n'
        session = 'final class SessionEngine {\n    var store: SQLiteSessionStore?\n    func pause() { _ = try? store?.listItems() }\n}\n'
        model = '@MainActor\nfinal class Model {\n    func f() { let sessionEngine = make(); sessionEngine.pause() }\n}\n'
        rows = scan(AKitten=kitten, Session=session, Model=model)
        self.assertEqual([r['api'] for r in rows if r['file'].endswith('Model.swift')], ['via SessionEngine.pause'])

    def test_loops_are_marked(self):
        body = ('    func f(_ ids: [String]) {\n        for id in ids { _ = try? store?.loadItem(id: id) }\n'
                '        _ = ids.map { try? store?.loadItem(id: $0) }\n        _ = try? store?.loadItem(id: "x")\n    }')
        rows = scan(Model=MODEL % body)
        self.assertEqual([r['in_loop'] for r in rows], [True, True, False])

    def test_the_same_read_in_two_functions_is_two_rows(self):
        rows = scan(Model=MODEL % '    func a() { _ = try? store?.listItems() }\n    func b() { _ = try? store?.listItems() }')
        self.assertEqual(sorted(r['function'] for r in rows), ['Model.a', 'Model.b'])


class FileAndAudioWork(unittest.TestCase):
    def test_file_hashing_and_audio_property_reads_on_main(self):
        body = ('    func f(_ url: URL, _ asset: AVURLAsset) {\n        _ = try? Data(contentsOf: url)\n'
                '        _ = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)\n'
                '        _ = SHA256.hash(data: Data())\n        _ = asset.duration\n        _ = try? AVAudioFile(forReading: url)\n'
                '        try? AVAudioSession.sharedInstance().setActive(true)\n    }')
        rows = scan(Model=MODEL % body)
        self.assertEqual(sorted({r['class'] for r in rows}), ['av-sync', 'file-io'])
        self.assertEqual(len(rows), 6)

    def test_the_same_calls_off_the_main_thread_are_clean(self):
        body = '    func f(_ url: URL) async { _ = try? Data(contentsOf: url) }\n    nonisolated func g(_ url: URL) async { _ = SHA256.hash(data: Data()) }'
        self.assertEqual([r['function'] for r in scan(Model=MODEL % body)], ['Model.f'])

    def test_debug_only_code_is_marked_and_not_counted(self):
        body = '    func f() {\n#if DEBUG\n        _ = try? store?.listItems()\n#endif\n    }'
        rows = scan(Model=MODEL % body)
        self.assertEqual([r['debug'] for r in rows], [True])
        self.assertEqual(sum(mtr.counts(rows).values()), 0)


class UnlabelledTasks(unittest.TestCase):
    def test_a_main_task_with_reads_and_no_label_gets_one_extra_row(self):
        rows = scan(Model=MODEL % '    func f() { Task { _ = try? store?.listItems(); _ = try? store?.loadItem(id: "a") } }')
        self.assertEqual(sorted(r['class'] for r in rows), ['store-heavy-decode', 'store-whole-table-read', 'unlabelled-main-task'])

    def test_a_label_around_the_work_removes_the_task_row(self):
        body = '    func f() { Task { _ = try? labels.scoped("reload") { try store?.listItems() } } }'
        rows = scan(Model=MODEL % body)
        self.assertEqual([r['class'] for r in rows], ['store-whole-table-read'])
        self.assertTrue(rows[0]['labelled'])

    def test_reads_reached_through_a_main_actor_call_count_for_the_task(self):
        body = '    func f() { Task { reload() } }\n    func reload() { _ = try? store?.listItems() }'
        rows = scan(Model=MODEL % body)
        self.assertEqual(sorted((r['function'], r['class']) for r in rows),
                         [('Model.f', 'unlabelled-main-task'), ('Model.reload', 'store-whole-table-read')])

    def test_a_task_with_no_reads_has_no_row(self):
        self.assertEqual(scan(Model=MODEL % '    func f() { Task { await Task.yield() } }'), [])


class TheRatchet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        folder = self.root / 'App/X/Sources'
        folder.mkdir(parents=True)
        self.source = folder / 'Model.swift'
        self.write('    func reload() { _ = try? store?.loadItem(id: "a") }')
        self.baseline = self.root / 'baseline.json'

    def write(self, body):
        self.source.write_text(MODEL % body)

    def run_main(self, *args):
        out = subprocess.run([sys.executable, str(SCRIPTS / 'main_thread_reads.py'), '--root', str(self.root),
                              '--baseline', str(self.baseline), *args], capture_output=True, text=True)
        return out.returncode, out.stdout + out.stderr

    def test_a_clean_tree_passes_and_adding_a_main_thread_list_items_fails(self):
        self.assertEqual(self.run_main('--accept', 'existing')[0], 0)
        self.assertEqual(self.run_main()[0], 0)
        self.write('    func reload() { _ = try? store?.loadItem(id: "a") }\n    func more() { _ = try? store?.listItems() }')
        code, out = self.run_main()
        self.assertEqual(code, 1, out)
        self.assertIn('Model.more', out)
        self.assertIn('store.listItems', out)
        self.assertIn('Model.swift:', out)

    def test_the_real_issue_example_a_new_list_items_in_a_main_actor_file_fails(self):
        self.run_main('--accept', 'existing')
        other = self.root / 'App/X/Sources/Library.swift'
        other.write_text('@MainActor\nfinal class Library {\n    let store: SQLiteSessionStore\n    func rows() throws { _ = try store.listItems() }\n}\n')
        code, out = self.run_main()
        self.assertEqual(code, 1, out)
        self.assertIn('Library.rows', out)

    def test_moving_the_read_off_main_makes_it_pass_and_update_tightens_the_baseline(self):
        self.run_main('--accept', 'existing')
        self.write('    func reload() { Task.detached { _ = try? self.store?.loadItem(id: "a") } }')
        code, out = self.run_main()
        self.assertEqual(code, 0, out)
        self.assertIn('--update', out)  # the fix is noticed but does not fail
        self.assertEqual(self.run_main('--strict')[0], 1)
        self.run_main('--update')
        self.assertEqual(json.loads(self.baseline.read_text())['entries'], [])

    def test_edits_that_only_move_the_line_do_not_trip_the_ratchet(self):
        self.run_main('--accept', 'existing')
        self.write('    var unrelated = 1\n\n    // a comment\n    func reload() { _ = try? store?.loadItem(id: "a") }')
        self.assertEqual(self.run_main()[0], 0)

    def test_a_second_call_of_a_baselined_api_in_the_same_function_fails(self):
        self.run_main('--accept', 'existing')
        self.write('    func reload() { _ = try? store?.loadItem(id: "a"); _ = try? store?.loadItem(id: "b") }')
        self.assertEqual(self.run_main()[0], 1)

    def test_a_second_call_can_be_accepted_and_keeps_both_reasons(self):
        self.run_main('--accept', 'existing')
        self.write('    func reload() { _ = try? store?.loadItem(id: "a"); _ = try? store?.loadItem(id: "b") }')
        self.run_main('--accept', 'the second one too')
        self.assertEqual(self.run_main()[0], 0)
        [entry] = json.loads(self.baseline.read_text())['entries']
        self.assertEqual((entry['count'], entry['reason']), (2, 'existing; the second one too'))

    def test_update_never_adds_a_row(self):
        self.run_main('--accept', 'existing')
        self.write('    func reload() { _ = try? store?.loadItem(id: "a") }\n    func more() { _ = try? store?.listItems() }')
        self.run_main('--update')
        self.assertEqual(self.run_main()[0], 1)

    def test_accepting_keeps_each_reason(self):
        self.run_main('--accept', 'first reason')
        self.write('    func reload() { _ = try? store?.loadItem(id: "a") }\n    func more() { _ = try? store?.listItems() }')
        self.run_main('--accept', 'second reason')
        reasons = {e['function']: e['reason'] for e in json.loads(self.baseline.read_text())['entries']}
        self.assertEqual(reasons, {'Model.reload': 'first reason', 'Model.more': 'second reason'})


class TheRepository(unittest.TestCase):
    def test_the_committed_baseline_matches_the_code(self):
        """The check the fast plan runs. New main-thread store/file/audio work fails here: move the read off the main
        thread, or (a false positive, or a read that must stay) --accept it with a one-line reason."""
        files = mtr.read_sources(ROOT)
        rows, _ = mtr.scan(files, APIS)
        new, _ = mtr.compare(rows, mtr.load_baseline(ROOT / mtr.BASELINE))
        self.assertEqual([(k, extra) for k, extra, _ in new], [], 'run scripts/main_thread_reads.py for the lines')

    def test_every_baseline_entry_has_a_reason(self):
        for entry in mtr.load_baseline(ROOT / mtr.BASELINE).values():
            self.assertTrue(entry.get('reason'), entry)

    def test_the_scanner_still_flags_the_code_behind_the_audit_issues(self):
        """#2102, #2184 and #2255 are open or only partly fixed: the rows that describe them must stay in the
        baseline until their fixes delete them."""
        base = mtr.load_baseline(ROOT / mtr.BASELINE)
        functions = {(k[1], k[2]) for k in base}
        for name in (('Gate1AppModel.refreshMarginRows', 'store.listItems'),
                     # #2102 swapped the full items for summaries here; it is still a whole-table read on main
                     ('Gate1AppModel.refreshAudioPreparationPresentation', 'store.listItemSummaries'),
                     # #2184 cached Skim's reads once per item, but the cache fill is still a main-thread
                     # whole-table read (it moved from resolvedPlan into loadedResources)
                     ('SkimBridgeController.loadedResources', 'store.loadOwnedOfflineAssets')):
                # #2255 moved prepareImportedLocalAudioBridges' and prepareSummaryBridgeAsset's reads into a
                # Task.detached, so their rows left the baseline as fixed.
            with self.subTest(name):
                self.assertIn(name, functions)


if __name__ == '__main__':
    unittest.main()
