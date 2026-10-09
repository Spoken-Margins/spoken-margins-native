"""UI-test launch hooks must not compile into Release builds (#517).

`--ui-testing` and the `SPOKEN_MARGINS_UI_TEST_*` environment values let a UI test wipe the Library,
swap in fake services and skip prompts. Only Xcode or XCTest passes them, but a TestFlight or App
Store binary has no reason to carry the code. Every app source line that names one must sit inside
`#if DEBUG` (the hooks live in UITestingHooks.swift), and so must the SessionKit seed that parses them
(`UITestingLaunchSeed`), which Xcode builds without DEBUG for a Release app.
`scripts/check-release-test-hooks.sh` checks a built Release app for the literals.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    ROOT / "App" / "SpokenMarginsApp" / "Sources",
    ROOT / "Packages" / "SessionKit" / "Sources",
]
HOOK = re.compile(r'--ui-testing|SPOKEN_MARGINS_UI_TEST')


def hook_lines_outside_debug(text: str) -> list[int]:
    """Line numbers that name a hook literal while not inside a `#if DEBUG` branch.

    Comment lines don't compile, so they are skipped. A branch is Debug-only when it is the body of
    `#if DEBUG` or the `#else` of `#if !DEBUG`; any other condition is treated as Release code.
    """
    stack: list[tuple[str, bool]] = []  # (the #if condition, whether we are past its #else)
    found = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if line.startswith("#if "):
            stack.append((line[4:].strip(), False))
        elif line == "#else" and stack:
            stack[-1] = (stack[-1][0], True)
        elif line.startswith("#endif") and stack:
            stack.pop()
        elif HOOK.search(line) and not line.startswith("//"):
            in_debug = any(
                (condition == "DEBUG" and not past_else) or (condition == "!DEBUG" and past_else)
                for condition, past_else in stack
            )
            if not in_debug:
                found.append(number)
    return found


class UITestingHooksDebugOnlyTests(unittest.TestCase):
    def test_scan_flags_a_hook_outside_debug(self):
        bad = 'let hooked = CommandLine.arguments.contains("--ui-testing")\n'
        self.assertEqual(hook_lines_outside_debug(bad), [1])
        release_branch = '#if !DEBUG\nlet x = "SPOKEN_MARGINS_UI_TEST_X"\n#endif\n'
        self.assertEqual(hook_lines_outside_debug(release_branch), [2])
        else_branch = '#if DEBUG\nlet a = 1\n#else\nlet x = "--ui-testing"\n#endif\n'
        self.assertEqual(hook_lines_outside_debug(else_branch), [4])
        debug_else = '#if !DEBUG\nlet a = 1\n#else\nlet x = "--ui-testing"\n#endif\n'
        self.assertEqual(hook_lines_outside_debug(debug_else), [])

    def test_scan_accepts_hooks_inside_debug_and_comments(self):
        good = (
            '/// Needs `--ui-testing`.\n'
            '#if DEBUG\n'
            'let on = CommandLine.arguments.contains("--ui-testing")\n'
            '#endif\n'
        )
        self.assertEqual(hook_lines_outside_debug(good), [])

    def test_no_app_source_names_a_hook_outside_debug(self):
        offenders = []
        for folder in SOURCES:
            for path in sorted(folder.rglob("*.swift")):
                for number in hook_lines_outside_debug(path.read_text(encoding="utf-8")):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(offenders, [], "UI-test hook literals outside #if DEBUG")


if __name__ == "__main__":
    unittest.main()
