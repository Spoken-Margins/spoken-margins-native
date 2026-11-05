"""The public-source check runs only on a listener's action (#3449, AGENTS.md 2026-10-21, "Fetch a publisher's page only on a
listener's action, never in the background").

`PublicSourceChecks.ensureMark`, `startPublicSourceCheck` and `PublicSourceMarker.ensureMark` make an anonymous request to
a publisher's page. The scan names every function allowed to call them: the add confirmation, the Prepare Listening Map tap,
the share tap, the share review, and the export build. A call from anywhere else, above all a background import, a feed
refresh or a prewarm, fails here. The live transport and the verifier are built in one place only.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [*ROOT.glob("App/**/Sources/**/*.swift"), *ROOT.glob("Packages/SessionKit/Sources/**/*.swift")]
APP = "App/SpokenMarginsApp/Sources/SpokenMarginsApp/"
KIT = "Packages/SessionKit/Sources/SessionKit/"

# (file, enclosing function) pairs that start from a listener's tap or from opening a screen they chose.
ALLOWED_CALLS = {
    (APP + "Gate1AppModel+AddedToLibrary.swift", "reportAddedToLibrary"),  # the listener added the item
    (APP + "ExperienceItemDetailScreen.swift", ".button"),  # the Prepare Listening Map button's own action
    (APP + "Gate1AppModel+ShareExport.swift", "exportSharedInterjections"),  # the share tap
    (APP + "PublicSourceChecks.swift", "refreshWithheldMapNote"),  # the share review the listener opened
    (APP + "PublicSourceChecks.swift", "startPublicSourceCheck"),  # the helper the two taps above call
    (APP + "PublicSourceChecks.swift", "ensureMark"),  # the app's one entry point
    (APP + "SharingExperience.swift", ".task"),  # the Share Margins sheet asking for its note when it appears
    (KIT + "SessionEngine.swift", "buildExportReadingOffMain"),  # the export build, with the Listening Map on
}

CALL = re.compile(r"\bensureMark\(|\bstartPublicSourceCheck\(|\brefreshWithheldMapNote\(")
FUNC = re.compile(r"\bfunc\s+(\w+)")
BUILDS_LIVE = re.compile(r"PublicSourceTransport\.probe|PublicSourceVerifier\(probe")


def enclosing_function(text: str, offset: int) -> str | None:
    last = None
    for match in FUNC.finditer(text, 0, offset):
        last = match.group(1)
    return last


class PublicSourceCheckCallerTests(unittest.TestCase):
    def test_only_listener_actions_start_the_check(self):
        found = set()
        for path in SOURCES:
            rel = str(path.relative_to(ROOT))
            if rel.endswith(("PublicSourceMarker.swift", "PublicSourceVerifier.swift")):
                continue  # the type itself
            text = path.read_text()
            for match in CALL.finditer(text):
                # a declaration is not a call
                line_start = text.rfind("\n", 0, match.start()) + 1
                if re.search(r"\bfunc\s", text[line_start:match.end()]):
                    continue
                # A call in a SwiftUI body, not in a func: the closure it sits in is named by the line's modifier or the button.
                function = ".task" if ".task {" in text[line_start:match.end()] else (
                    ".button" if rel.endswith("Screen.swift") else enclosing_function(text, match.start()))
                found.add((rel, function))
                self.assertIn((rel, function), ALLOWED_CALLS,
                              f"{rel}: {function} starts the public-source check; only a listener's action may (#3449)")
        self.assertTrue(found, "the scan found no caller; update the pattern")
        missing = ALLOWED_CALLS - found
        self.assertFalse(missing, f"allowed callers that no longer call it: {sorted(missing)}")

    def test_no_background_or_feed_file_mentions_the_check(self):
        quiet = re.compile(r"Background|Feed|Follow|Prewarm|Refresh|Scheduler|Watch|Widget|Extension", re.I)
        for path in SOURCES:
            text = path.read_text()
            if path.name == "PublicSourceChecks.swift" or not (CALL.search(text) or BUILDS_LIVE.search(text)):
                continue
            self.assertIsNone(quiet.search(path.name), f"{path.name} is a background-style file that reaches the check (#3449)")

    def test_the_live_probe_is_built_in_one_place(self):
        builders = {str(p.relative_to(ROOT)) for p in SOURCES if BUILDS_LIVE.search(p.read_text())}
        self.assertEqual(builders, {APP + "PublicSourceChecks.swift"}, "a second place builds a live public-source probe (#3449)")

    def test_the_unit_test_and_ui_test_launch_never_reaches_the_network(self):
        text = (ROOT / APP / "PublicSourceChecks.swift").read_text()
        self.assertIn("isRunningUnitTests", text)
        self.assertIn("--ui-testing", text)


if __name__ == "__main__":
    unittest.main()
