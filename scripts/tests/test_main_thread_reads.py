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


def scan(off_props=frozenset(), **files):
    """Rows for in-memory Swift sources, keyed `name=source` (an underscore stands for a dot in the file name).
    `off_props`: model properties whose project.yml flag is false."""
    rows, skipped = mtr.scan([(f'App/X/Sources/{name}.swift', src) for name, src in files.items()], APIS, off_props)
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


class WhatNeverRunsOnTheAppsMainThread(unittest.TestCase):
    """#2514: the baseline holds only real main-thread work. Each case below says what the scanner leaves out and
    pairs it with a lookalike that must still be a row, so the ratchet keeps catching a new real instance."""

    def test_a_closure_given_to_a_queue_the_file_made_runs_off_the_main_thread(self):
        queue = '    let writer = DispatchQueue(label: "w")\n'
        off = {
            'serial queue under another name': MODEL % (queue + '    func f() { writer.async { _ = try? self.store?.listItems() } }'),
            'serial queue with arguments': MODEL % (queue + '    func f() { writer.asyncAfter(deadline: .now()) { _ = try? self.store?.listItems() } }'),
        }
        for name, source in off.items():
            with self.subTest(name):
                self.assertEqual(scan(Model=source), [])
        on = {
            'an alias of the main queue': MODEL % '    let ui = DispatchQueue.main\n    func f() { ui.async { _ = try? self.store?.listItems() } }',
            'an alias of the main queue, synchronously': MODEL % '    let ui = DispatchQueue.main\n    func f() { ui.sync(flags: .barrier) { _ = try? self.store?.listItems() } }',
            'an object with an async method': MODEL % '    let scheduler = Scheduler()\n    func f() { scheduler.async { _ = try? self.store?.listItems() } }',
            'the main queue': MODEL % '    func f() { DispatchQueue.main.async { _ = try? self.store?.listItems() } }',
        }
        for name, source in on.items():
            with self.subTest(name):
                self.assertTrue(scan(Model=source), 'expected a row')

    def test_a_sendable_closure_is_not_taken_to_leave_the_main_thread(self):
        # not actor-isolated is not off the main thread: a synchronous closure runs on whoever calls it
        for name, source in {
            'literal attribute': MODEL % '    func f() { run { @Sendable in _ = try? store?.listItems() } }',
            'typed value': MODEL % '    func f() { let work: @Sendable () -> Void = { _ = try? self.store?.listItems() }; work() }',
            'a main hop out of it': MODEL % '    func f() { DispatchQueue.main.async { @Sendable in _ = try? self.store?.listItems() } }',
            'stored in a sendable typealias property': ('typealias CheckHandler = @Sendable (URL) throws -> Int\n@MainActor\nfinal class Model {\n'
                '    var store: SQLiteSessionStore?\n    let check: CheckHandler\n    init(check: CheckHandler? = nil) {\n'
                '        self.check = check ?? { url in try self.store?.loadItem(id: url.path).id.count ?? 0 }\n    }\n}\n'),
        }.items():
            with self.subTest(name):
                self.assertTrue(scan(Model=source), 'expected a row')

    def test_a_task_row_names_only_a_task_that_starts_on_the_main_thread(self):
        detached = MODEL % ('    func f() { Task.detached { let x = 1; _ = x\n'
                            '        await MainActor.run { _ = try? self.store?.listItems() } } }')
        self.assertEqual([r['class'] for r in scan(Model=detached)], ['store-whole-table-read'])
        plain = MODEL % '    func f() { Task { _ = try? store?.listItems() } }'
        self.assertIn('unlabelled-main-task', [r['class'] for r in scan(Model=plain)])
        # a Task in a type that is not main-actor is background work; the Task it starts on main is the one to name
        background = ('final class Client {\n    var store: SQLiteSessionStore?\n    func f() {\n'
                      '        Task { await work()\n            Task { @MainActor in _ = try? self.store?.listItems() } }\n    }\n}\n')
        rows = scan(Client=background)
        self.assertEqual(sorted(r['class'] for r in rows), ['store-whole-table-read', 'unlabelled-main-task'])
        self.assertEqual([r['line'] for r in rows if r['class'] == 'unlabelled-main-task'], [5])

    def test_code_after_a_guard_on_a_flag_that_is_off_never_runs(self):
        body = ('    var remoteProviderExperienceEnabled = false\n'
                '    func submit() {\n        guard remoteProviderExperienceEnabled else { _ = try? store?.loadSessions(); return }\n'
                '        _ = try? store?.listItems()\n    }\n'
                '    func chapters() async {\n        guard remoteProviderExperienceEnabled, store != nil else { return }\n        _ = try? store?.listItems()\n    }')
        off = {'remoteProviderExperienceEnabled'}
        rows = scan(off, Model=MODEL % body)
        # only the else branch of the guard (the flag is off) still runs
        self.assertEqual([(r['function'], r['api']) for r in rows], [('Model.submit', 'store.loadSessions')])
        # with the flag on, or not named in project.yml, both reads are rows again
        self.assertEqual(len(scan(Model=MODEL % body)), 3)
        self.assertEqual(len(scan({'someOtherFlag'}, Model=MODEL % body)), 3)

    def test_a_guard_does_not_hide_a_later_switch_case_or_an_else_after_a_closure_in_its_condition(self):
        flag = 'remoteProviderExperienceEnabled'
        body = (f'    var {flag} = false\n    func a(_ k: Int) {{\n        switch k {{\n        case 1:\n'
                f'            guard {flag} else {{ return }}\n            _ = try? store?.loadSessions()\n'
                f'        default:\n            _ = try? store?.listItems()\n        }}\n    }}\n'
                f'    func b(_ xs: [Int]) {{\n        guard {flag}, xs.contains(where: {{ $0 > 1 }}) else {{ _ = try? store?.listItems(); return }}\n'
                f'        _ = try? store?.loadSessions()\n    }}')
        rows = scan({flag}, Model=MODEL % body)
        self.assertEqual(sorted((r['function'], r['api']) for r in rows), [('Model.a', 'store.listItems'), ('Model.b', 'store.listItems')])

    def test_an_if_on_the_flag_and_other_conditions_on_it_are_not_dead_code(self):
        flag = 'remoteProviderExperienceEnabled'
        body = (f'    var {flag} = false\n    func a() {{\n        if {flag} {{ _ = try? store?.listItems() }}\n    }}\n'
                f'    func b() {{\n        if !{flag} {{ _ = try? store?.listItems() }}\n    }}\n'
                f'    func c(other: Bool) {{\n        guard other || {flag} else {{ return }}\n        _ = try? store?.listItems()\n    }}')
        rows = scan({flag}, Model=MODEL % body)
        self.assertEqual(sorted(r['function'] for r in rows), ['Model.b', 'Model.c'])

    def test_a_function_only_a_debug_block_calls_is_not_a_row_but_one_with_a_release_caller_is(self):
        reads = ('    func seed() { _ = try? store?.listItems() }\n    func both() { _ = try? store?.listItems() }\n'
                 '    func viaButton() { _ = try? store?.listItems() }\n')
        screen = ('struct Screen: View {\n    var model: Model\n    var body: some View {\n'
                  '#if DEBUG\n        Button("Seed", action: model.viaButton)\n        Button("Seed") { model.seed(); model.both() }\n#endif\n'
                  '        Button("Both") { model.both() }\n    }\n}\n')
        rows = scan(Model=MODEL % reads, Screen=screen)
        self.assertEqual(sorted(r['function'] for r in rows), ['Model.both'])

    def test_a_name_handed_to_live_code_keeps_the_function_live(self):
        reads = '    func seed() { _ = try? store?.listItems() }\n'
        for name, screen in {
            'a button action': 'struct Screen: View {\n var model: Model\n var body: some View {\n  Button("Seed", action: model.seed)\n }\n}\n',
            'a selector': 'struct Screen: View {\n var body: some View { Text("x").onAppear(perform: #selector(Model.seed)) }\n}\n',
            'a call in a live function': 'struct Screen: View {\n var model: Model\n var body: some View { Text("x").onAppear { model.seed() } }\n}\n',
        }.items():
            with self.subTest(name):
                rows = scan(Model=MODEL % reads, Screen=screen)
                self.assertEqual([r['function'] for r in rows], ['Model.seed'])

    def test_a_function_the_system_or_a_string_can_call_is_never_called_dead(self):
        screen = 'struct Screen: View {\n var model: Model\n var body: some View {\n#if DEBUG\n  Button("Seed") { model.seed() }\n#endif\n  Text("x")\n }\n}\n'
        cases = {
            'objc': ('    @objc func seed() { _ = try? store?.listItems() }\n', ''),
            'override': ('    override func seed() { _ = try? store?.listItems() }\n', ''),
            'a selector string in live code': ('    func seed() { _ = try? store?.listItems() }\n', '    func f() { perform(Selector("seed")) }\n'),
        }
        for name, (reads, extra) in cases.items():
            with self.subTest(name):
                rows = scan(Model=MODEL % (reads + extra), Screen=screen)
                self.assertIn('Model.seed', [r['function'] for r in rows])

    def test_a_function_with_two_definitions_is_never_called_dead(self):
        # the callee cannot be told apart without types, so a debug-only call of `seed` proves nothing
        reads = '    func seed() { _ = try? store?.listItems() }\n'
        other = 'final class Other {\n    func seed() { }\n}\n'
        screen = 'struct Screen: View {\n var model: Model\n var body: some View {\n#if DEBUG\n  Button("Seed") { model.seed() }\n#endif\n  Text("x")\n }\n}\n'
        self.assertEqual([r['function'] for r in scan(Model=MODEL % reads, Other=other, Screen=screen)], ['Model.seed'])

    def test_a_debug_only_chain_is_dead_down_to_its_last_helper(self):
        reads = '    func outer() { inner() }\n    func inner() { _ = try? store?.listItems() }\n'
        screen = 'struct Screen: View {\n var model: Model\n var body: some View {\n#if DEBUG\n  Button("Seed") { model.outer() }\n#endif\n  Text("x")\n }\n}\n'
        self.assertEqual(scan(Model=MODEL % reads, Screen=screen), [])
        live = screen.replace('#if DEBUG\n', '').replace('#endif\n', '')
        self.assertEqual([r['function'] for r in scan(Model=MODEL % reads, Screen=live)], ['Model.inner'])


class WhatTheAppTargetBuilds(unittest.TestCase):
    PROJECT = """name: X
targets:
  App:
    type: application
    platform: iOS
    sources:
      - path: App/Main/Sources
        type: syncedFolder
        excludes:
          - Main/Bridge.swift
          - Legacy
      - path: App/Shared
      - path: Packages/Kit/Sources/Kit/One.swift
    settings:
      base:
        SMRemoteProviderExperienceEnabled: false
  ShareExt:
    type: app-extension
    sources:
      - path: App/ShareExt/Sources
      - path: App/Shared
  AppTests:
    type: bundle.unit-test
    sources:
      - path: App/AppTests
"""

    def test_project_yml_reads_into_targets_sources_and_excludes(self):
        targets = mtr.parse_project(self.PROJECT)
        self.assertEqual(sorted(targets), ['App', 'AppTests', 'ShareExt'])
        self.assertEqual(targets['App']['type'], 'application')
        self.assertEqual(targets['App']['sources'][0], ('App/Main/Sources', ['Main/Bridge.swift', 'Legacy']))
        self.assertEqual([p for p, _ in targets['ShareExt']['sources']], ['App/ShareExt/Sources', 'App/Shared'])

    def test_a_file_is_scanned_when_the_app_target_compiles_it(self):
        built = mtr.app_process_filter(self.PROJECT)
        for rel, expected in {
            'App/Main/Sources/Main/Model.swift': True,              # in the app target
            'App/Shared/Common.swift': True,                        # in the app and the extension: the app's main thread runs it
            'App/Main/Sources/Main/Bridge.swift': False,            # excluded by name
            'App/Main/Sources/Legacy/Old.swift': False,             # excluded folder
            'App/Main/Sources/Main/Bridge2.swift': True,            # a name that merely starts like an exclude
            'App/ShareExt/Sources/Controller.swift': False,         # the extension's own process
            'App/Watch/Sources/Watch.swift': False,                 # in no target
            'Packages/Kit/Sources/Kit/Two.swift': True,             # packages are not judged
        }.items():
            with self.subTest(rel):
                self.assertEqual(built(rel), expected)

    def test_a_source_entry_the_reader_does_not_know_means_every_file_is_scanned(self):
        for name, entry in {
            'a key before the path': '      - optional: true\n        path: App/Bar\n',
            'a name entry': '      - name: Bar\n',
            'inline excludes': '      - path: App/Bar\n        excludes: [a.swift]\n',
        }.items():
            with self.subTest(name):
                text = 'targets:\n  App:\n    type: application\n    sources:\n      - path: App/Foo\n' + entry
                self.assertIsNone(mtr.app_process_filter(text))
        quoted = mtr.app_process_filter('targets:\n  App:\n    type: "application"\n    sources:\n      - path: "App/Foo"\n      - \'App/Bar\'\n')
        self.assertTrue(quoted('App/Foo/a.swift') and quoted('App/Bar/b.swift') and not quoted('App/Baz/c.swift'))

    def test_the_flag_counts_only_in_the_application_target(self):
        text = ('targets:\n  App:\n    type: application\n    settings:\n      base:\n        SMRemoteProviderExperienceEnabled: true\n'
                '  Ext:\n    type: app-extension\n    settings:\n      base:\n        SMRemoteProviderExperienceEnabled: false\n')
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'project.yml').write_text(text)
            self.assertEqual(mtr.project_build(Path(tmp))[1], frozenset())

    def test_no_application_target_means_every_file_is_scanned(self):
        self.assertIsNone(mtr.app_process_filter('targets:\n  Ext:\n    type: app-extension\n'))

    def test_read_sources_leaves_out_what_the_app_does_not_build_and_says_so(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'project.yml').write_text(self.PROJECT)
            for rel in ('App/Main/Sources/Main/Model.swift', 'App/Main/Sources/Main/Bridge.swift',
                        'App/ShareExt/Sources/Controller.swift', 'App/Watch/Sources/Watch.swift'):
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text('final class C {}\n')
            left_out = []
            files = mtr.read_sources(root, left_out)
            self.assertEqual([rel for rel, _ in files], ['App/Main/Sources/Main/Model.swift'])
            self.assertEqual(sorted(left_out), ['App/Main/Sources/Main/Bridge.swift', 'App/ShareExt/Sources/Controller.swift',
                                                'App/Watch/Sources/Watch.swift'])
            self.assertEqual(mtr.project_build(root)[1], frozenset({'remoteProviderExperienceEnabled'}))

    def test_a_tree_with_no_project_yml_is_scanned_whole_and_no_flag_is_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'App/Watch').mkdir(parents=True)
            (root / 'App/Watch/W.swift').write_text('final class W {}\n')
            self.assertEqual([rel for rel, _ in mtr.read_sources(root)], ['App/Watch/W.swift'])
            self.assertEqual(mtr.project_build(root), (None, frozenset()))

    def test_a_flag_that_is_true_or_missing_is_not_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for text in (self.PROJECT.replace('Enabled: false', 'Enabled: true'), self.PROJECT.replace('SMRemoteProviderExperienceEnabled: false', '')):
                (root / 'project.yml').write_text(text)
                self.assertEqual(mtr.project_build(root)[1], frozenset())


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
        rows, _ = mtr.scan(files, APIS, mtr.project_build(ROOT)[1])
        new, _ = mtr.compare(rows, mtr.load_baseline(ROOT / mtr.BASELINE))
        self.assertEqual([(k, extra) for k, extra, _ in new], [], 'run scripts/main_thread_reads.py for the lines')

    def test_the_watch_app_and_the_extensions_are_not_scanned(self):
        left_out = []
        mtr.read_sources(ROOT, left_out)
        names = {Path(rel).name for rel in left_out}
        self.assertTrue({'WatchOfflineModels.swift', 'WatchPackageRenderCoordinator.swift',
                         'SourceLinkShareViewController.swift'} <= names, names)
        self.assertEqual([k for k in mtr.load_baseline(ROOT / mtr.BASELINE) if Path(k[0]).name in names], [])

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
