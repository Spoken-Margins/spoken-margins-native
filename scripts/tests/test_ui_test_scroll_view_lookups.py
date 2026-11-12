"""A UI test's `app.scrollViews["id"]` must name a view the app exposes as a scroll view (#3923).

`testBuild23SenderStagesInvalidateStalePreviewAndUseSystemShare` swiped `app.scrollViews["build23.sender.experience"]`,
but the app sets that identifier on a modifier chain that also carries `.accessibilityElement(children: .contain)`,
which XCUITest reports as an "Other". The query matched nothing, so the swipe could never run. This check reads each
`scrollViews["id"]` in the UI tests, finds the `.accessibilityIdentifier("id")` in the app sources, and fails when the
identifier is missing or its modifier chain makes it a container.

The chain is read as the run of lines starting with `.` around the identifier line, which is how the app writes its
modifiers; a modifier split from its chain by a closing brace is outside the run and is not seen.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI_TESTS = ROOT / "App" / "SpokenMarginsAppUITests"
APP_SOURCES = [ROOT / "App" / "SpokenMarginsApp" / "Sources", ROOT / "App" / "SharedSources"]

LOOKUP = re.compile(r'\.scrollViews\["([^"]+)"\]')
CONTAINER = ".accessibilityElement(children: .contain)"


def scroll_view_lookups(text: str) -> list[tuple[int, str]]:
    """(line number, identifier) for each `scrollViews["id"]` lookup outside a comment line."""
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        if line.strip().startswith("//"):
            continue
        found.extend((number, identifier) for identifier in LOOKUP.findall(line))
    return found


def modifier_chain(lines: list[str], index: int) -> list[str]:
    """The run of `.modifier` lines around `lines[index]`, stripped."""
    start = index
    while start > 0 and lines[start - 1].strip().startswith("."):
        start -= 1
    end = index
    while end + 1 < len(lines) and lines[end + 1].strip().startswith("."):
        end += 1
    return [line.strip() for line in lines[start:end + 1]]


def identifier_chains(text: str, identifier: str) -> list[list[str]]:
    """The modifier chain of each line that sets `.accessibilityIdentifier("identifier")`."""
    needle = f'.accessibilityIdentifier("{identifier}")'
    lines = text.splitlines()
    return [modifier_chain(lines, index) for index, line in enumerate(lines) if needle in line]


def lookup_problem(identifier: str, chains: list[list[str]]) -> str | None:
    """Why `scrollViews[identifier]` cannot match, or None when it can."""
    if not chains:
        return "no app source sets this identifier"
    if all(CONTAINER in chain for chain in chains):
        return f"the app sets it with {CONTAINER}, which XCUITest reports as Other, not ScrollView"
    return None


class ScrollViewLookupTests(unittest.TestCase):
    def test_sender_sheet_container_is_flagged(self):
        """The #3923 shape: the identifier sits on a `.contain` chain after a closing brace."""
        source = "\n".join([
            "        }",
            "        .background(AppColors.bone.ignoresSafeArea())",
            "        .accessibilityElement(children: .contain)",
            '        .accessibilityIdentifier("build23.sender.experience")',
            "        .onAppear {",
        ])
        problem = lookup_problem("build23.sender.experience", identifier_chains(source, "build23.sender.experience"))
        self.assertIsNotNone(problem)
        self.assertIn("Other", problem)

    def test_container_after_the_identifier_is_flagged(self):
        source = '        .accessibilityIdentifier("x.list")\n        .accessibilityElement(children: .contain)\n'
        self.assertIsNotNone(lookup_problem("x.list", identifier_chains(source, "x.list")))

    def test_plain_scroll_view_passes(self):
        source = "        ScrollView {\n        }\n        .scrollIndicators(.hidden)\n        .accessibilityIdentifier(\"x.list\")\n"
        self.assertIsNone(lookup_problem("x.list", identifier_chains(source, "x.list")))

    def test_container_outside_the_chain_is_not_counted(self):
        """A `.contain` on an inner view, closed off by a brace, does not make the outer view a container."""
        source = "\n".join([
            "            .accessibilityElement(children: .contain)",
            "        }",
            '        .accessibilityIdentifier("x.list")',
        ])
        self.assertIsNone(lookup_problem("x.list", identifier_chains(source, "x.list")))

    def test_unknown_identifier_is_flagged(self):
        self.assertEqual(lookup_problem("x.missing", []), "no app source sets this identifier")

    def test_comment_lines_are_not_lookups(self):
        text = '        // app.scrollViews["a"].swipeUp()\n        app.scrollViews["b"].swipeUp()\n'
        self.assertEqual(scroll_view_lookups(text), [(2, "b")])

    def test_ui_tests_look_up_only_real_scroll_views(self):
        app_texts = [path.read_text() for root in APP_SOURCES for path in root.rglob("*.swift")]
        self.assertGreater(len(app_texts), 300, "app sources not found")
        problems = []
        for path in sorted(UI_TESTS.glob("*.swift")):
            for number, identifier in scroll_view_lookups(path.read_text()):
                chains = [chain for text in app_texts for chain in identifier_chains(text, identifier)]
                if problem := lookup_problem(identifier, chains):
                    problems.append(f"{path.relative_to(ROOT)}:{number} scrollViews[\"{identifier}\"]: {problem}")
        self.assertEqual(problems, [], "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
