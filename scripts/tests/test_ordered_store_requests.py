"""The guard for ordered store requests started from a separate Task (#3335)."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ordered_store_requests as guard  # noqa: E402


def scan_source(source: str) -> list[dict]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        directory = root / 'App' / 'Sources'
        directory.mkdir(parents=True)
        (directory / 'Model.swift').write_text(source, encoding='utf-8')
        return guard.scan(root)


class OrderedStoreRequestsTests(unittest.TestCase):
    def test_the_budget_shape_that_lost_its_order_is_flagged(self):
        # The shape of offlineStorageBudgetChanged before #3335: one Task per change, the place taken after the hop.
        rows = scan_source('''
            func changed() {
                Task { [weak self] in
                    try await StoreReader(store).readInOrder(key) { try $0.save(budget) }
                }
            }
        ''')
        self.assertEqual([row['reason'] for row in rows], [None])

    def test_every_task_spelling_is_flagged(self):
        for opener in ('Task {', 'Task { @MainActor [weak self] in', 'Task.detached {',
                       'Task.detached(priority: .utility) {', 'Task(priority: .userInitiated) {',
                       'Task<Void, Never> {', 'Task.detached(priority: pick(x)) {', '.task {', '.task(id: item) {',
                       'group.addTask {'):
            with self.subTest(opener=opener):
                rows = scan_source(f'func f() {{\n  {opener}\n    _ = try? await StoreReader(s).readInOrder(k) {{ _ in 1 }}\n  }}\n}}')
                self.assertEqual(len(rows), 1)

    def test_a_call_nested_deeper_inside_the_task_is_flagged(self):
        rows = scan_source('func f() { Task { if ok { for x in xs { _ = try? await StoreReader(s).readInOrder(k) { _ in x } } } } }')
        self.assertEqual(len(rows), 1)

    def test_taking_the_place_before_the_task_is_clean(self):
        rows = scan_source('''
            func changed() {
                let save = StoreReader(store).enqueueInOrder(key) { try $0.save(budget) }
                Task { try await save.value }
            }
        ''')
        self.assertEqual(rows, [])

    def test_an_async_function_that_awaits_in_sequence_is_clean(self):
        rows = scan_source('''
            func flow() async {
                let a = try await StoreReader(store).readInOrder(key) { _ in 1 }
                let b = try await StoreReader(store).readInOrder(key) { _ in 2 }
            }
        ''')
        self.assertEqual(rows, [])

    def test_a_marked_call_carries_its_reason_on_the_line_or_above(self):
        rows = scan_source('''
            func f() {
                Task {
                    // ordered-ok: awaited in sequence inside this one flow
                    _ = try? await StoreReader(s).readInOrder(k) { _ in 1 }
                    _ = try? await StoreReader(s).readInOrder(k) { _ in 2 } // ordered-ok: same flow
                    _ = try? await StoreReader(s).readInOrder(k) { _ in 3 }
                }
            }
        ''')
        self.assertEqual([row['reason'] for row in rows],
                         ['awaited in sequence inside this one flow', 'same flow', None])

    def test_a_comment_or_string_naming_the_call_is_not_a_call(self):
        rows = scan_source('''
            func f() {
                Task {
                    // readInOrder(k) is mentioned here
                    let note = "readInOrder(k) in a string"
                    /* readInOrder(k) */
                }
            }
        ''')
        self.assertEqual(rows, [])

    def test_a_brace_in_a_string_does_not_shift_the_enclosing_closures(self):
        rows = scan_source('''
            func f() {
                Task { let s = "}}}" }
                _ = try? await StoreReader(s).readInOrder(k) { _ in 1 }
            }
        ''')
        self.assertEqual(rows, [])

    def test_the_app_has_no_unmarked_call_inside_a_task(self):
        unmarked = [f"{row['file']}:{row['line']}" for row in guard.scan() if not row['reason']]
        self.assertEqual(unmarked, [], 'take the place with enqueueInOrder before the Task, or mark it `// ordered-ok: why`')


if __name__ == '__main__':
    unittest.main()
