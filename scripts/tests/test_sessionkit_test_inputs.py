"""SessionKit tests read repository inputs so a standalone checkout skips them, never fails them (#1873).

`TestInputs` throws `XCTSkip` when the package is checked out alone. XCTest records a skip thrown inside an
`XCTAssert…` or `XCTUnwrap` expression as a failure, and `try?` turns it into a wrong value, so
`scripts/check-sessionkit-standalone.sh --test` failed on #2370's `PDFWordSpacingTests`. That script runs only on
demand; this scan runs in the fast plan and fails on a new call site of the same kind.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / 'Packages' / 'SessionKit' / 'Tests'
ASSERTION = re.compile(r'\b(XCTAssert\w*|XCTUnwrap)\(')
FUNC = re.compile(r'\bfunc (\w+)(?:<[^>]*>)?\(([^)]*)\)[^{]*?\bthrows\b[^{]*\{')


def balanced(text, start, opening, closing):
    """Text from `start` (just past an opening bracket) to its closing bracket, skipping string literals."""
    depth, i = 1, start
    while i < len(text) and depth:
        char = text[i]
        if char == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
        i += 1
    return text[start:i - 1]


def call_pattern(name, parameters):
    """A pattern for calls to one overload, told apart by its first argument label: `page()`, `page(editingPost:`."""
    parameter = parameters.split(',')[0]
    first = parameter.split(':')[0].split()
    if not first:
        return r'\b%s\(\s*\)' % re.escape(name)
    if first[0] == '_':
        return r'\b%s\((?!\s*\w+\s*:)' % re.escape(name)
    omitted = r'|\)' if '=' in parameter else ''  # a defaulted first argument may be left out
    return r'\b%s\(\s*(?:%s\s*:%s)' % (re.escape(name), re.escape(first[0]), omitted)


def skipping_calls(text):
    """Patterns for calls that can throw TestInputs' skip: TestInputs itself and this file's helpers that reach it."""
    calls = [r'\bTestInputs\.']
    bodies = {call_pattern(m.group(1), m.group(2)): balanced(text, m.end(), '{', '}') for m in FUNC.finditer(text)}
    changed = True
    while changed:
        changed = False
        for call, body in bodies.items():
            if call not in calls and any(re.search(c, body) for c in calls):
                calls.append(call)
                changed = True
    return calls


def misplaced_reads(text):
    """(line, snippet) for each assertion or `try?` that would swallow TestInputs' skip."""
    calls = skipping_calls(text)
    found = []
    # A class whose setUp reads the input skips before any test body runs (VoiceModelCatalogTests).
    for match in re.finditer(r'\bfunc setUpWithError\(\)[^{]*\{', text):
        if any(re.search(c, balanced(text, match.end(), '{', '}')) for c in calls):
            return found
    for match in ASSERTION.finditer(text):
        expression = balanced(text, match.end(), '(', ')')
        # `TestInputs.modelCheck` doesn't throw; a `try` inside, or before `XCTUnwrap(`, marks a throwing read.
        throws = re.search(r'\btry\b', expression) or re.search(r'\btry\s*$', text[max(0, match.start() - 8):match.start()])
        if throws and any(re.search(c, expression) for c in calls):
            found.append((text.count('\n', 0, match.start()) + 1, match.group(0) + expression[:60]))
    for number, line in enumerate(text.splitlines(), 1):
        rest = line.partition('//')[0].partition('try?')[2]
        if rest and any(re.search(c, rest) for c in calls):
            found.append((number, line.strip()[:80]))
    return sorted(found)


class TestInputsReadOutsideAssertionsTest(unittest.TestCase):
    def test_no_sessionkit_test_reads_an_input_inside_an_assertion_or_try_optional(self):
        problems = []
        for path in sorted(TESTS.rglob('*.swift')):
            if path.parent.name == 'TestInputs':
                continue
            for line, snippet in misplaced_reads(path.read_text(encoding='utf-8')):
                problems.append(f'{path.relative_to(ROOT)}:{line}: {snippet}')
        self.assertEqual(problems, [], 'read the input into a `let` first (see TestInputs.swift):\n' + '\n'.join(problems))

    def test_the_scan_catches_each_shape(self):
        text = '''
    private func spacer(context: [String] = []) throws -> Spacer {
        let list = try List(contentsOf: TestInputs.url(.voiceAssets, "lexicon.tsv"))
        return Spacer(list, context)
    }
    private func twice() throws -> Spacer { try spacer() }
    func testA() throws {
        XCTAssertEqual(try spacer(context: c).respaced("a(b"), "a b")
        XCTAssertEqual(
            try twice().respaced("x"), "x")
        let data = try? Data(contentsOf: TestInputs.url(.contracts, "x.json"))
        let good = try spacer()
        XCTAssertEqual(good.respaced("(\\"y"), "y")
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), t)
        XCTAssertEqual(try page(editing: good), "")
        XCTAssertNoThrow(try page())
        let url = try XCTUnwrap(TestInputs.url(.contracts, "y.json"))
        // A comment may name try? TestInputs.url(.contracts, "z.json").
    }
    private func page() throws -> String { try TestInputs.string(.contracts, "page.html") }
    private func page(editing spacer: Spacer) throws -> String { "" }
'''
        self.assertEqual([line for line, _ in misplaced_reads(text)], [8, 9, 11, 16, 17])
        gated = text + '''
    override func setUpWithError() throws {
        _ = try TestInputs.url(.contracts, "folder")
    }
'''
        self.assertEqual(misplaced_reads(gated), [])


if __name__ == '__main__':
    unittest.main()
