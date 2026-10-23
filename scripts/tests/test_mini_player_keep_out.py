"""Every screen that can show under the floating mini player keeps its bottom clear of it (#1716).

The mini player floats over the content (`MiniPlayerDock`). A safe-area inset placed outside a NavigationStack
reaches only the stack's root, so each NavigationStack root and each pushed destination applies
`.miniPlayerKeepOut()` itself, which reads the pill's clearance from the environment. Before this, pushed screens
such as Following → Manage Feeds → Import from another app ran under the pill, and the owner couldn't reach
"Choose OPML file". A new NavigationLink or NavigationStack without the modifier would bring that back without any
other test noticing, so this scan guards it. The app-hosted MiniPlayerKeepOutLayoutTests check the modifier itself.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
KEEP_OUT = ".miniPlayerKeepOut()"

# Screens the mini player is never drawn over. The pill isn't drawn over sheets, the Now Playing screen hides it,
# and the Timeline places its own. Keyed by (file, the struct that holds the NavigationStack or link).
NO_PILL = {
    ("CatalogDrawer.swift", "CatalogDrawerView"): "the catalog drawer is a sheet",
    ("ExperienceAudioPreparationQueueScreen.swift", "*"): "a sheet from the Library",
    ("ExperienceMarginDetailView.swift", "*"): "a sheet from Margins",
    ("ExperienceAddSourceFlow.swift", "*"): "the add-source sheet",
    ("ExperienceReactionsScreen.swift", "*"): "a sheet from the item screen",
    ("ExperienceMarginsScreen.swift", "SharedMarginDetailView"): "a sheet from Margins",
    ("ExperienceTimelineRailScreen.swift", "*"): "the Timeline places its own mini player",
    ("HelpScreen.swift", "*"): "a sheet",
    ("Gate1RootView.swift", "Gate1RootView"): "the terms sheet",
    ("Gate1RootView.swift", "AIDataSharingConsentView"): "a sheet",
    ("Gate1RootView.swift", "InterjectionDetailView"): "pushed inside the Margin detail sheet",
    ("ItemCollectionSheet.swift", "*"): "a sheet",
    ("PlaybackNativeTextPeekView.swift", "*"): "inside Now Playing, which hides the mini player",
    ("PlaybackTimelineSourceView.swift", "*"): "inside Now Playing, which hides the mini player",
    ("PlaybackScreen.swift", "*"): "Now Playing hides the mini player",
    ("SharingExperience.swift", "*"): "sharing sheets",
    ("VoicesSettingsScreen.swift", "VoiceAgreementSheet"): "the licence agreement sheet before a voice download (#1819)",
}

STRUCT = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|public)\s+)?struct\s+(\w+)", re.M)
LINE_COMMENT = re.compile(r"//[^\n]*")


def _strip_comments(text: str) -> str:
    """Blank out line comments, keeping offsets, so a brace or name in a comment can't confuse the scan."""
    return LINE_COMMENT.sub(lambda m: " " * len(m.group(0)), text)


def _closure_end(text: str, open_brace: int) -> int:
    """Index just past the brace that closes the one at `open_brace`."""
    depth = 0
    for index in range(open_brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError(f"unbalanced braces from offset {open_brace}")


def _paren_end(text: str, open_paren: int) -> int:
    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError(f"unbalanced parentheses from offset {open_paren}")


def _next_nonspace(text: str, index: int) -> int:
    while index < len(text) and text[index].isspace():
        index += 1
    return index


def destinations(text: str) -> list[tuple[int, int, int]]:
    """(name offset, closure start, closure end) of each NavigationLink destination and navigationDestination."""
    found = []
    for match in re.finditer(r"\bNavigationLink\b|\.navigationDestination\b", text):
        at = _next_nonspace(text, match.end())
        if match.group(0) == "NavigationLink":
            if at < len(text) and text[at] == "(":
                arguments = text[at:_paren_end(text, at)]
                if "destination:" in arguments or "value:" in arguments:
                    # `value:` links are pushed by a navigationDestination, which is scanned on its own;
                    # `destination:` closures are scanned here.
                    if "destination:" not in arguments:
                        continue
                    start = text.index("destination:", at)
                    brace = text.index("{", start)
                    found.append((match.start(), brace, _closure_end(text, brace)))
                    continue
                at = _next_nonspace(text, _paren_end(text, at))
            if at < len(text) and text[at] == "{":
                found.append((match.start(), at, _closure_end(text, at)))
        else:
            if at < len(text) and text[at] == "(":
                at = _next_nonspace(text, _paren_end(text, at))
            if at < len(text) and text[at] == "{":
                found.append((match.start(), at, _closure_end(text, at)))
    return found


def stacks(text: str) -> list[tuple[int, int, int]]:
    """(name offset, closure start, closure end) of each NavigationStack's root closure."""
    found = []
    for match in re.finditer(r"\bNavigationStack\b", text):
        at = _next_nonspace(text, match.end())
        if at < len(text) and text[at] == "(":
            at = _next_nonspace(text, _paren_end(text, at))
        if at < len(text) and text[at] == "{":
            found.append((match.start(), at, _closure_end(text, at)))
    return found


def _enclosing_struct(text: str, offset: int) -> str:
    """The innermost struct whose body holds `offset`, so a nested helper struct declared earlier doesn't count."""
    best, best_size = "?", None
    for match in STRUCT.finditer(text, 0, offset):
        brace = text.find("{", match.end())
        if brace < 0 or brace > offset:
            continue
        end = _closure_end(text, brace)
        if offset < end and (best_size is None or end - brace < best_size):
            best, best_size = match.group(1), end - brace
    return best


def _without(text: str, start: int, end: int, holes: list[tuple[int, int, int]]) -> str:
    """The text of [start, end) with the nested destination closures cut out."""
    kept, cursor = [], start
    for _, hole_start, hole_end in sorted(holes):
        if start < hole_start and hole_end <= end and hole_start >= cursor:
            kept.append(text[cursor:hole_start])
            cursor = hole_end
    kept.append(text[cursor:end])
    return "".join(kept)


def missing_keep_out(name: str, source: str) -> list[str]:
    """`file:line kind` for each stack root or destination in `source` that doesn't apply the keep-out."""
    text = _strip_comments(source)
    links = destinations(text)
    offenders = []
    for kind, spans in (("NavigationStack root", stacks(text)), ("pushed destination", links)):
        for offset, start, end in spans:
            owner = _enclosing_struct(text, offset)
            if (name, owner) in NO_PILL or (name, "*") in NO_PILL:
                continue
            body = _without(text, start, end, [link for link in links if link[1] != start])
            if KEEP_OUT not in body:
                offenders.append(f"{name}:{text.count(chr(10), 0, offset) + 1} {kind} in {owner}")
    return offenders


class MiniPlayerKeepOutScanTests(unittest.TestCase):
    def test_scan_flags_a_pushed_screen_without_the_keep_out(self):
        bad = """
struct Screen: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Import") { OPMLImportScreen() }
                NavigationLink { ReadLaterScreen().miniPlayerKeepOut() } label: { Text("Read later") }
            }
            .navigationDestination(isPresented: $managing) {
                ManageFeedsScreen()
            }
            .miniPlayerKeepOut()
        }
    }
}
"""
        self.assertEqual(missing_keep_out("Screen.swift", bad), [
            "Screen.swift:6 pushed destination in Screen",
            "Screen.swift:9 pushed destination in Screen",
        ])

    def test_scan_does_not_count_a_destinations_keep_out_for_the_stack_root(self):
        bad = """
struct Screen: View {
    var body: some View {
        NavigationStack {
            List { NavigationLink("Import") { OPMLImportScreen().miniPlayerKeepOut() } }
            // .miniPlayerKeepOut() in a comment doesn't count either
        }
    }
}
"""
        self.assertEqual(missing_keep_out("Screen.swift", bad), ["Screen.swift:4 NavigationStack root in Screen"])

    def test_scan_names_the_outer_struct_not_a_nested_helper(self):
        source = """
struct Screen: View {
    private struct Row: Identifiable { let id: String }
    var body: some View { NavigationStack { Text("x") } }
}
"""
        self.assertEqual(missing_keep_out("Screen.swift", source), ["Screen.swift:4 NavigationStack root in Screen"])

    def test_scan_skips_screens_the_pill_is_never_drawn_over(self):
        sheet = "struct CatalogDrawerView: View { var body: some View { NavigationStack { Text(\"x\") } } }"
        self.assertEqual(missing_keep_out("CatalogDrawer.swift", sheet), [])

    def test_every_screen_under_the_mini_player_keeps_out_of_it(self):
        offenders = []
        for path in sorted(SOURCES.glob("*.swift")):
            offenders += missing_keep_out(path.name, path.read_text(encoding="utf-8"))
        self.assertEqual(offenders, [], f"apply {KEEP_OUT} to these, or list a screen the pill never covers in NO_PILL")

    def test_no_pill_entries_still_exist(self):
        for name, owner in NO_PILL:
            path = SOURCES / name
            self.assertTrue(path.exists(), f"{name} is listed in NO_PILL but doesn't exist")
            if owner != "*":
                self.assertRegex(path.read_text(encoding="utf-8"), rf"struct\s+{owner}\b",
                                 f"{name} has no struct {owner} any more; update NO_PILL")


if __name__ == "__main__":
    unittest.main()
