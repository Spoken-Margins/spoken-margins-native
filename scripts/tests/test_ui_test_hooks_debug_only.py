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
# The two source folders held about 600 Swift files when this floor was set (2026-10-17).
MIN_SOURCE_FILES = 300
# `ui-test-share-link` is the host J10 hands its share link over on (#1842).
HOOK = re.compile(r'--ui-testing|SPOKEN_MARGINS_UI_TEST|ui-test-share-link')


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
        scanned = []
        for folder in SOURCES:
            for path in sorted(folder.rglob("*.swift")):
                scanned.append(path)
                for number in hook_lines_outside_debug(path.read_text(encoding="utf-8")):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}")
        # A scan that visited nothing finds nothing (#1905): prove it read the sources it guards.
        self.assertGreaterEqual(len(scanned), MIN_SOURCE_FILES, f"scanned only {len(scanned)} Swift files; are {SOURCES} still the app's sources?")
        self.assertTrue(any(path.name == "UITestingHooks.swift" for path in scanned), "the file that holds the hooks was not scanned")
        self.assertEqual(offenders, [], "UI-test hook literals outside #if DEBUG")


class ShareLinkHandoffTests(unittest.TestCase):
    """J10 hands its share link to the app as `spokenmargins://ui-test-share-link?url=` (#1842).

    Hosted simulators never route the universal link, so J10's share link step skipped on every hosted run and
    the class never counted as a pass. The UI test target doesn't link SessionKit, so it builds the hand-off by
    hand; these keep its copy, SessionKit's reader and the app's registered scheme saying the same thing.
    """

    HANDOFF = ROOT / "Packages" / "SessionKit" / "Sources" / "SessionKit" / "ShareLinkUITestHandoff.swift"
    J10 = ROOT / "App" / "SpokenMarginsAppUITests" / "J10OfflineJourneyUITests.swift"

    def handoff_prefix(self) -> str:
        source = self.HANDOFF.read_text(encoding="utf-8")
        scheme = re.search(r'static let scheme = "([^"]+)"', source)
        host = re.search(r'static let host = "([^"]+)"', source)
        self.assertIsNotNone(scheme, "ShareLinkUITestHandoff no longer names its scheme")
        self.assertIsNotNone(host, "ShareLinkUITestHandoff no longer names its host")
        return f"{scheme.group(1)}://{host.group(1)}?url="

    def test_j10_opens_the_handoff_sessionkit_reads(self):
        self.assertIn(self.handoff_prefix(), self.J10.read_text(encoding="utf-8"))

    def test_j10_never_skips_its_share_link_step(self):
        self.assertNotIn("XCTSkip", self.J10.read_text(encoding="utf-8"),
                         "a skipped step never counts as a pass; the hand-off always reaches the app")

    def test_the_app_registers_the_handoff_scheme(self):
        scheme = self.handoff_prefix().split("://")[0]
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertRegex(project, rf"CFBundleURLSchemes:\s*\n\s*- {scheme}\s*\n")


class LiveSessionsClearedAtUITestLaunchTests(unittest.TestCase):
    """A UI-test launch that resets the store also clears Live sessions (#3967).

    Live sessions are files kept outside the SQLite store, so `store.reset()` leaves one that an earlier test
    started. It then sits at the top of every later test's Library and, at the largest text size, pushes every
    library row off the first screen. SessionKit's tests prove what the clearing does; these prove the app still
    calls it, before the model or the Live session worker reads a file, and only under `--ui-testing`.
    """

    APP = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"

    def test_the_app_model_clears_live_sessions_before_it_is_built(self):
        source = (self.APP / "UITestingLaunchSeedWriter.swift").read_text(encoding="utf-8")
        make = source.index("static func makeApplicationModel()")
        call = source.find("UITestingHooks.clearLiveSessionsIfRequested()", make)
        build = source.find("Gate1AppModel(", make)
        self.assertNotEqual(call, -1, "makeApplicationModel no longer clears the Live sessions a UI-test launch leaves")
        self.assertLess(call, build, "the Live sessions must be cleared before any Gate1AppModel is built")

    def test_the_hook_clears_only_for_a_ui_test_launch_that_resets_the_library(self):
        source = (self.APP / "UITestingHooks.swift").read_text(encoding="utf-8")
        body = source[source.index("static func clearLiveSessionsIfRequested() {"):]
        body = body[: body.index("\n    }\n")]
        self.assertIn("guard isActive, seed.clearsLiveSessions", body)
        self.assertIn("removeAllLiveSessionFiles", body)
        # The Release stub does nothing, so a TestFlight build never clears a listener's sessions.
        self.assertIn("static func clearLiveSessionsIfRequested() {}", source)


if __name__ == "__main__":
    unittest.main()
