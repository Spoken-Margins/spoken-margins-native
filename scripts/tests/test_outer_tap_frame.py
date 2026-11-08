"""A button's 44 pt target comes from its label, never from a frame put outside the Button (#3727).

A `.frame(minHeight: 44)` after a `Button` gives the layout 44 pt of room, but the tappable region stays the
size of the label (the repo's own note on #430). Switch Control and motor-impaired touch then get a target the
size of a word. The fix is the frame, plus `contentShape(Rectangle())`, inside the label, or `minimumTapTarget()`
inside the label. This scan reads every App/ Swift file and fails on a `Button` whose modifier chain has an
outer frame with a minimum of 44 pt or more, or an outer `minimumTapTarget()`.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App"

OUTER_TARGET = re.compile(
    r"\.frame\([^)]*\bmin(?:Height|Width)\s*:\s*(\d+)[^)]*\)|\.minimumTapTarget\(\)")


def _strip(text: str) -> str:
    # A `//` right after `:` is a URL in a string, not a comment.
    return re.sub(r"(?<!:)//[^\n]*", "", text)


def _close_of(text: str, start: int, open_c: str, close_c: str) -> int:
    depth = 0
    in_string = False
    for j in range(start, len(text)):
        c = text[j]
        if c == '"' and text[j - 1] != "\\":
            in_string = not in_string
        elif not in_string:
            if c == open_c:
                depth += 1
            elif c == close_c:
                depth -= 1
                if depth == 0:
                    return j
    return -1


def _button_chains(text: str):
    """Yields (offset, chain) for each Button: the modifiers that follow its arguments and closures."""
    for m in re.finditer(r"\bButton\s*[({]", text):
        i = m.end() - 1
        j = _close_of(text, i, text[i], ")" if text[i] == "(" else "}")
        if j < 0:
            continue
        k = j + 1
        while True:
            mm = re.match(r"\s*(?:label\s*:\s*)?\{", text[k:])
            if not mm:
                break
            end = _close_of(text, k + mm.end() - 1, "{", "}")
            if end < 0:
                break
            k = end + 1
        end = k
        while True:
            mm = re.match(r"\s*\.\w+", text[end:])
            if not mm:
                break
            s = end + mm.end()
            if s < len(text) and text[s] == "(":
                close = _close_of(text, s, "(", ")")
                if close < 0:
                    break
                s = close + 1
            mm2 = re.match(r"\s*\{", text[s:])
            if mm2:
                close = _close_of(text, s + mm2.end() - 1, "{", "}")
                if close > 0:
                    s = close + 1
            end = s
        yield m.start(), text[k:end]


def outer_targets(source: str):
    """Returns (line, modifier) for each outer 44 pt frame or minimumTapTarget after a Button."""
    text = _strip(source)
    found = []
    for pos, chain in _button_chains(text):
        for mm in OUTER_TARGET.finditer(chain):
            if mm.group(1) is not None and int(mm.group(1)) < 44:
                continue
            found.append((text[:pos].count("\n") + 1, mm.group(0)))
    return found


class OuterTapFrameScanTests(unittest.TestCase):
    """The scan itself: neighbouring spellings, so a rewrite of the Button can't slip past it."""

    def test_an_outer_frame_after_a_text_button_is_flagged(self):
        self.assertEqual(outer_targets('Button("Done") { go() }\n    .frame(minHeight: 44)\n'),
                         [(1, ".frame(minHeight: 44)")])

    def test_an_outer_frame_after_a_label_button_and_other_modifiers_is_flagged(self):
        source = '''Button(action: go) {
    Label("Go", systemImage: "play")
}
.buttonStyle(.bordered)
.font(.caption)
.frame(maxWidth: .infinity, minHeight: 44)
.accessibilityIdentifier("x")
'''
        self.assertEqual(outer_targets(source), [(1, ".frame(maxWidth: .infinity, minHeight: 44)")])

    def test_a_trailing_label_closure_is_followed_to_its_modifiers(self):
        source = 'Button { go() } label: { Text("Go") }\n.frame(minWidth: 96, minHeight: 44)\n'
        self.assertEqual(len(outer_targets(source)), 1)

    def test_larger_minimums_and_an_outer_minimum_tap_target_are_flagged(self):
        self.assertEqual(len(outer_targets('Button("A") { }\n.frame(minHeight: 46)\n')), 1)
        self.assertEqual(len(outer_targets('Button("A") { }\n.minimumTapTarget()\n')), 1)

    def test_the_frame_inside_the_label_is_fine(self):
        self.assertEqual(outer_targets('Button { go() } label: { Text("Go").frame(minHeight: 44).contentShape(Rectangle()) }\n.buttonStyle(.bordered)\n'), [])
        self.assertEqual(outer_targets('Button { go() } label: { Text("Go").minimumTapTarget() }\n'), [])

    def test_a_small_or_width_only_frame_is_not_a_tap_target_claim(self):
        self.assertEqual(outer_targets('Button("A") { }\n.frame(minHeight: 30)\n'), [])
        self.assertEqual(outer_targets('Button("A") { }\n.frame(maxWidth: .infinity)\n'), [])

    def test_a_frame_on_the_next_view_is_not_the_buttons(self):
        source = 'Button("A") { }\nText("B").frame(minHeight: 44)\n'
        self.assertEqual(outer_targets(source), [])

    def test_a_comment_or_a_url_string_does_not_hide_or_invent_a_button(self):
        self.assertEqual(outer_targets('// Button("A") { }.frame(minHeight: 44)\n'), [])
        source = 'Button("See https://example.com/a") { }\n.frame(minHeight: 44)\n'
        self.assertEqual(len(outer_targets(source)), 1)

    def test_a_string_with_a_brace_does_not_end_the_button_early(self):
        source = 'Button("Use {a}") { go("}") }\n.frame(minHeight: 44)\n'
        self.assertEqual(len(outer_targets(source)), 1)


class OuterTapFrameAppTests(unittest.TestCase):
    def test_no_button_in_the_app_keeps_its_44_pt_target_outside_the_label(self):
        offenders = []
        for path in sorted(APP.rglob("*.swift")):
            if any(part.endswith("Tests") for part in path.relative_to(APP).parts):
                continue
            for line, modifier in outer_targets(path.read_text()):
                offenders.append(f"{path.relative_to(ROOT)}:{line} {modifier}")
        self.assertEqual(
            offenders, [],
            "A frame outside a Button does not grow its tappable area (#3727, #430). Move the frame, with "
            "contentShape(Rectangle()), or minimumTapTarget(), inside the Button's label.")


if __name__ == "__main__":
    unittest.main()
