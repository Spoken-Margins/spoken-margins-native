from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import split_move  # noqa: E402

SOURCE = 'App/Model/Gate1AppModel.swift'

MODEL = '''import Foundation
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

private struct Helper {
    let value: Int
}

@MainActor
final class Gate1AppModel: ObservableObject {
    static let limit = 3
    private static let key = "key"
    @Published private var counter = 0
    @Published private(set) var title = "{ not a brace"
    private var cache: [String: Int] = [:]
    var observed = 0 {
        didSet { counter += 1 }
    }
    var computed: Int {
        counter + 1
    }

    init() {
        counter = 0
    }

    // MARK: Margins

    /// Counts a thing.
    /// Two lines of docs.
    @discardableResult
    private func countThing(_ name: String) -> Int {
        let text = "brace } in \\(name.isEmpty ? "{" : "}") string"
        let raw = #"raw { "quoted" }"#
        /* a { block comment */
        cache[name] = text.count + raw.count
        return Self.limit + counter
    }

    func useCount() -> Int {
        let counter = 5
        return countThing("a") + counter + Helper(value: 1).value
    }

    func readTitle() -> String {
        title
    }

    #if canImport(UIKit)
    func uiOnly() -> String {
        """
        multi { line
        """
    }
    #endif

    func overloaded(_ value: Int) -> Int { value }
    func overloaded(_ value: String) -> String { value }

    override func caller() {
        _ = useCount()
    }
}
'''


def names(members):
    return [(m.kind, m.name) for m in members]


class ScanTests(unittest.TestCase):
    """Braces inside strings, interpolation, raw strings and comments don't move the depth."""

    def test_depth_ignores_braces_in_strings_and_comments(self):
        s = split_move.scan(MODEL)
        lines = MODEL.split('\n')
        for i, line in enumerate(lines):
            if line.strip() in ('func useCount() -> Int {', 'func readTitle() -> String {', 'init() {'):
                self.assertEqual(s.depth[i], 1, line)
        close = max(i for i, line in enumerate(lines) if line == '}')
        self.assertEqual(s.depth[close], 1)
        self.assertEqual(s.end_depth[close], 0)

    def test_multi_line_string_is_quiet(self):
        s = split_move.scan(MODEL)
        i = MODEL.split('\n').index('        multi { line')
        self.assertTrue(s.quiet[i])


class MemberTests(unittest.TestCase):
    def setUp(self):
        _, self.members, _, _ = split_move.model_members(MODEL)
        self.by_name = {m.name: m for m in self.members}

    def test_members_in_order(self):
        self.assertEqual(names(self.members), [
            ('let', 'limit'), ('let', 'key'), ('var', 'counter'), ('var', 'title'), ('var', 'cache'),
            ('var', 'observed'), ('var', 'computed'), ('init', 'init'), ('func', 'countThing'),
            ('func', 'useCount'), ('func', 'readTitle'), ('func', 'uiOnly'), ('func', 'overloaded'),
            ('func', 'overloaded'), ('func', 'caller')])

    def test_stored_or_computed(self):
        stored = {m.name for m in self.members if m.stored}
        self.assertEqual(stored, {'counter', 'title', 'cache', 'observed'})

    def test_doc_comments_and_attributes_belong_to_the_member(self):
        lines = MODEL.split('\n')
        m = self.by_name['countThing']
        self.assertEqual(lines[m.start].strip(), '/// Counts a thing.')
        self.assertEqual(lines[m.decl].strip(), 'private func countThing(_ name: String) -> Int {')
        self.assertEqual(lines[m.end].strip(), '}')

    def test_mark_comment_stays(self):
        lines = MODEL.split('\n')
        self.assertFalse(any(lines[m.start].strip().startswith('// MARK') for m in self.members))

    def test_conditions_recorded(self):
        self.assertEqual([c.strip() for c in self.by_name['uiOnly'].conditions], ['#if canImport(UIKit)'])


class MoveTests(unittest.TestCase):
    def move(self, names, dest=None, **kw):
        return split_move.move_texts(MODEL, dest, names, **kw)

    def test_refuses_what_an_extension_cannot_hold(self):
        for name in ('counter', 'observed', 'init', 'caller'):
            with self.subTest(name=name), self.assertRaises(split_move.SplitError):
                self.move([name])

    def test_moves_a_private_member_and_relaxes_only_what_the_split_needs(self):
        source, dest, plan = self.move(['countThing'])
        self.assertNotIn('func countThing', source)
        self.assertIn('    /// Counts a thing.\n    /// Two lines of docs.\n    @discardableResult\n'
                      '    func countThing(_ name: String) -> Int {', dest)
        # Read only by moved code: the setter stays private.
        self.assertIn('    @Published private(set) var counter = 0', source)
        # Written by moved code (a subscript assignment): fully internal.
        self.assertIn('    var cache: [String: Int] = [:]', source)
        # Not used by moved code: unchanged.
        self.assertIn('    private static let key = "key"', source)
        self.assertEqual(dest.splitlines()[:5], MODEL.splitlines()[:5])
        changed = {name for _, name, _ in plan['changes']}
        self.assertEqual(changed, {'countThing', 'counter', 'cache'})

    def test_a_local_with_the_same_name_is_not_a_write(self):
        # useCount binds `let counter = 5`; that is not an assignment to the model's counter, so the
        # name match leaves its setter private.
        source, _, _ = self.move(['useCount'])
        self.assertIn('    @Published private(set) var counter = 0', source)

    def test_a_private_moved_member_unused_by_the_model_stays_private(self):
        _, dest, _ = self.move(['countThing', 'useCount'])
        self.assertIn('    private func countThing', dest)

    def test_file_level_private_helper_used_by_moved_code_is_relaxed(self):
        source, _, _ = self.move(['useCount'])
        self.assertIn('\nstruct Helper {', source)

    def test_conditional_member_moves_with_its_condition_and_the_empty_block_goes(self):
        source, dest, _ = self.move(['uiOnly'])
        self.assertNotIn('#if canImport(UIKit)\n    #endif', source)
        self.assertEqual(source.count('    #if canImport(UIKit)'), 0)
        self.assertIn('    #if canImport(UIKit)\n    func uiOnly() -> String {', dest)
        self.assertIn('    }\n    #endif\n}', dest)

    def test_from_through_selects_a_range(self):
        _, dest, plan = self.move([], start='useCount', through='readTitle')
        self.assertEqual([m.name for m in plan['chosen']], ['useCount', 'readTitle'])

    def test_overloads_need_a_line_with_from(self):
        with self.assertRaises(split_move.SplitError):
            self.move([], start='overloaded', through='overloaded')
        _, _, plan = self.move(['overloaded'])
        self.assertEqual(len(plan['chosen']), 2)

    def test_appends_to_an_existing_extension(self):
        existing = 'import Foundation\n\nextension Gate1AppModel {\n    func old() {}\n}\n'
        _, dest, _ = self.move(['readTitle'], dest=existing)
        self.assertIn('    func old() {}\n\n    func readTitle() -> String {\n        title\n    }\n}\n', dest)
        self.assertIn('import SessionKit', dest)
        self.assertEqual(dest.count('extension Gate1AppModel {'), 1)

    def test_the_result_checks_as_moves_only(self):
        source, dest, _ = self.move(['countThing', 'uiOnly'])
        dest_path = 'App/Model/Gate1AppModel+Things.swift'
        ok, report = split_move.check_texts(SOURCE, {SOURCE: MODEL}, {SOURCE: source, dest_path: dest})
        self.assertTrue(ok, '\n'.join(report))
        self.assertIn('Access changes', '\n'.join(report))


class CheckTests(unittest.TestCase):
    """check fails on anything a move can't explain."""

    def setUp(self):
        source, dest, _ = split_move.move_texts(MODEL, None, ['countThing', 'readTitle'])
        self.source, self.dest = source, dest
        self.dest_path = 'App/Model/Gate1AppModel+Things.swift'

    def check(self, source=None, dest=None):
        return split_move.check_texts(SOURCE, {SOURCE: MODEL},
                                      {SOURCE: source or self.source, self.dest_path: dest or self.dest})

    def test_an_edited_line_fails(self):
        ok, report = self.check(dest=self.dest.replace('return Self.limit + counter', 'return Self.limit - counter'))
        self.assertFalse(ok)
        self.assertIn('Removed, not found elsewhere', '\n'.join(report))

    def test_reordered_statements_fail(self):
        a = '        /* a { block comment */\n'
        b = '        cache[name] = text.count + raw.count\n'
        self.assertIn(a + b, self.dest)
        ok, report = self.check(dest=self.dest.replace(a + b, b + a))
        self.assertFalse(ok, '\n'.join(report))

    def test_an_added_statement_fails(self):
        ok, report = self.check(dest=self.dest.replace('        title\n', '        title\n        print(title)\n'))
        self.assertFalse(ok)
        self.assertIn('Added, not a moved line', '\n'.join(report))

    def test_a_deleted_member_fails(self):
        start = self.dest.index('    func readTitle')
        end = self.dest.index('    }\n', start) + len('    }\n')
        ok, _ = self.check(dest=self.dest[:start] + self.dest[end:])
        self.assertFalse(ok)

    def test_a_changed_line_left_in_the_model_fails(self):
        ok, _ = self.check(source=self.source.replace('return countThing("a") + counter', 'return countThing("b") + counter'))
        self.assertFalse(ok)

    def test_comments_are_listed_not_failed(self):
        dest = self.dest.replace('extension Gate1AppModel {', '/// Things, moved unchanged.\nextension Gate1AppModel {')
        ok, report = self.check(dest=dest)
        self.assertTrue(ok, '\n'.join(report))
        self.assertIn('Comments added (1)', '\n'.join(report))


if __name__ == '__main__':
    unittest.main()
