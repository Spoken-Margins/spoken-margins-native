"""Every sheet and full-screen cover goes through the tracked wrapper (#4337).

A sheet or cover that is dismissed and presented again by itself builds a new screen: the listener sees it flash and
loses what was open on it. It reached the owner's phone as #2831, #4091 (twice) and #3891. `trackedSheet` and
`trackedFullScreenCover` (TrackedPresentation.swift) add a modifier to the content that reports it appearing and
disappearing, so `PresentationTracker` can see a screen built twice: the Diagnostics `screenRebuilds` line in a
release, a failed test in an app-hosted run, a stopped app in a scripted journey.

A raw `.sheet(` or `.fullScreenCover(` in the app's sources skips all of that, so this scan fails on one. It reads code,
not comments, so a note that names the call doesn't trip it. Test sources are out of scope: a test may present a raw
cover as its control. The extensions' sources under App/ are scanned like the app's own, so a presentation added there
has to use the wrapper (or its own tracker) too.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App"
HOME = "TrackedPresentation.swift"
# SwiftUI's two forms both open with a label, and an extension on View calls them with no receiver (`sheet(isPresented:`),
# so the dot is optional. The label keeps a closure that happens to be named `sheet()` from matching.
RAW = re.compile(r"(?<![A-Za-z0-9_])(?:sheet|fullScreenCover)\s*\(\s*(?:isPresented|item)\s*:")
WRAPPERS = ("trackedSheet", "trackedFullScreenCover")


def _code(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?<!:)//[^\n]*", "", text)


def raw_presentations(sources: dict) -> dict:
    """{path: count} of raw `.sheet(` and `.fullScreenCover(` calls in {path: source}, outside the wrapper's own file."""
    return {name: len(RAW.findall(_code(text))) for name, text in sources.items()
            if Path(name).name != HOME and RAW.search(_code(text))}


def app_sources() -> dict:
    found = {}
    for path in sorted(APP.rglob("*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        if any(part.endswith("Tests") for part in path.relative_to(APP).parts):
            continue
        found[rel] = path.read_text(encoding="utf-8", errors="replace")
    return found


class TrackedPresentationTests(unittest.TestCase):
    def test_no_screen_presents_a_raw_sheet_or_cover(self):
        found = raw_presentations(app_sources())
        self.assertEqual(found, {}, "use .trackedSheet(...) or .trackedFullScreenCover(...) so a screen built twice is seen (#4337)")

    def test_the_wrapper_file_still_wraps_all_four_forms_and_tracks_each(self):
        text = _code((next(APP.rglob(HOME))).read_text())
        for name in WRAPPERS:
            self.assertEqual(len(re.findall(rf"func {name}<", text)), 2, f"{name} has an isPresented form and an item form")
        raw = {"sheet(isPresented:": 1, "sheet(item:": 1, "fullScreenCover(isPresented:": 1, "fullScreenCover(item:": 1}
        for call, count in raw.items():
            self.assertEqual(text.count(f"return {call}"), count, call)
        self.assertEqual(len(re.findall(r"\.trackedPresentation\(place: place", text)), 4, "every form puts the tracking modifier on the content")
        self.assertIn("modifier(PresentationTracking(", text, "and it is the one modifier that reports")

    def test_the_app_actually_uses_the_wrapper(self):
        used = sum(len(re.findall(r"\.tracked(?:Sheet|FullScreenCover)\(", _code(text))) for text in app_sources().values())
        self.assertGreaterEqual(used, 40, "the app presents 43 sheets and covers (#4337); a scan that finds none has lost its way")

    def test_the_scan_catches_the_look_alikes(self):
        for source in (".sheet(isPresented: $x) { }", ".sheet (item: $x) { _ in }", "    .sheet(\nitem: $x)",
                       "content.fullScreenCover(item: $links.cover) { _ in }", ".fullScreenCover(isPresented: $a) { }",
                       # an extension on View presents with implicit self, so there is no dot (ExportScreen.swift, #4337 audit)
                       "sheet(isPresented: Binding(get: { a }, set: { _ in })) { }", "        fullScreenCover(item: $x) { _ in }",
                       "return sheet(\n isPresented: b) { }"):
            self.assertEqual(raw_presentations({"App/X/Screen.swift": source}), {"App/X/Screen.swift": 1}, source)

    def test_the_scan_leaves_the_wrapper_comments_and_tests_alone(self):
        for source in (".trackedSheet(isPresented: $x) { }", ".trackedFullScreenCover(item: $x) { _ in }",
                       "// .sheet(item: $x) is what this replaced", "/* .fullScreenCover(isPresented: $a) */",
                       "let sheetHeight = 3  // sheet(", "let x = model.sheetRoute",
                       ".trackedSheet(item: sheetReview) { _ in sheet() }", "func playQueueSheet(isPresented: b)",
                       "ShareFilePresenter.present(fileURL: url)"):
            self.assertEqual(raw_presentations({"App/X/Screen.swift": source}), {}, source)
        self.assertEqual(raw_presentations({f"App/X/{HOME}": ".sheet(isPresented: p) { }"}), {}, "the wrapper's own file is the one place")

    def test_test_sources_are_not_scanned(self):
        self.assertFalse(any("Tests/" in name for name in app_sources()))


if __name__ == "__main__":
    unittest.main()
