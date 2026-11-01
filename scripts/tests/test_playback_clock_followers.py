"""Every view that draws the playhead follows the playback clock (#2074).

A progress tick that moves only the playback position no longer fires `Gate1AppModel.objectWillChange`; it goes to
`PlaybackClock`. A SwiftUI view that reads the position from the model (directly, or through a model property built
on it) must follow the clock with `followsPlaybackClock`, or it freezes between other snapshot changes. A parent that
follows the clock doesn't help a child `View` struct with equal inputs: SwiftUI skips the child's `body`. The Review
new Margins countdown froze this way during its lead-in (audit on PR #2104), and no model test can see which views
re-render, so this scan guards each `View` struct in the app's sources.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"

# The snapshot fields `SessionSnapshot.tickPosition` holds, read through the model (`model.snapshot.x`), through a
# local copy (`let snapshot = model.snapshot` ... `snapshot.x`), or from the clock itself (`playbackClock.position`).
# Mark complete read `snapshot.currentMediaTimeMs` through a local copy, which a `model.snapshot.` pattern missed, and
# stayed hidden past 75% on the owner's phone (#2968).
POSITION_FIELDS = (
    r"\bsnapshot\.(?:currentMediaTimeMs|currentTextStart|currentTextEnd|currentTranscriptSegmentId)\b"
    r"|\bplaybackClock\.position\b"
)
# Model properties and functions that read those fields, so a view reading them reads the position too.
POSITION_DERIVED = (
    "marginMomentPositionMs", "currentChapter", "playbackHeaderTitle", "playbackChapterHeaderTitle",
    "isCurrentTimelineChapter", "isCurrentTimelineListeningMapScene", "nextPlaybackMediaChapter",
    "nextPlaybackChapter", "canJumpToNextChapter", "chapterRowForwardControl", "canUseEndOfChapterSleepTimer",
    "playbackCompletionPresence",
)
POSITION_READ = re.compile(POSITION_FIELDS + r"|model\.(?:" + "|".join(POSITION_DERIVED) + r")\b")
VIEW_START = re.compile(r"^(?:(?:private|fileprivate|public|internal)\s+)?struct\s+(\w+)\s*:\s*[^{]*\bView\b[^{]*\{", re.M)
TOP_LEVEL = re.compile(r"^(?:(?:private|fileprivate|public|internal|final|@\w+)\s+)*(?:struct|class|enum|extension|protocol|func)\b", re.M)


def view_structs(text: str):
    """(name, source) for each top-level `View` struct, up to the next top-level declaration."""
    for match in VIEW_START.finditer(text):
        following = TOP_LEVEL.search(text, match.end())
        yield match.group(1), text[match.start():following.start() if following else len(text)]


def views_missing_the_clock(sources: dict):
    missing = []
    for name, text in sources.items():
        text = re.sub(r"//[^\n]*", "", text)
        for view, body in view_structs(text):
            if not POSITION_READ.search(body):
                continue
            if "followsPlaybackClock(model.playbackClock" not in body or "let _ = playbackTick" not in body:
                missing.append(f"{name}: {view}")
    return missing


class PlaybackClockFollowerTests(unittest.TestCase):
    def test_every_view_reading_the_playhead_follows_the_clock(self):
        sources = {path.name: path.read_text() for path in SOURCES.rglob("*.swift")}
        self.assertEqual([], views_missing_the_clock(sources))

    def test_the_scan_finds_a_child_view_that_reads_the_playhead_without_the_clock(self):
        parent = """
struct Parent: View {
    @State private var playbackTick = 0
    var body: some View {
        let _ = playbackTick
        Text("\\(model.snapshot.currentMediaTimeMs ?? 0)")
            .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }
}

private struct Child: View {
    var body: some View { Text(model.marginMomentPositionMs.description) }
}

private struct Unrelated: View {
    var body: some View { Text(model.snapshot.title) }
}
"""
        self.assertEqual(["Screen.swift: Child"], views_missing_the_clock({"Screen.swift": parent}))

    def test_the_scan_finds_a_view_that_reads_the_playhead_through_a_local_copy_of_the_snapshot(self):
        # Mark complete before #2968: a stateless child read the position through `let snapshot = model.snapshot`, so
        # it tested 75% only when something unrelated redrew it, and stayed hidden through the end of the episode.
        button = """
struct PlaybackMarkCompleteButton: View {
    @EnvironmentObject private var model: Gate1AppModel
    var body: some View {
        if let row = offeredRow { Button("Mark complete") {} }
    }
    private var offeredRow: LibraryItemRow? {
        let snapshot = model.snapshot
        guard PlaybackCompletionOffer.isOffered(mediaTimeMs: snapshot.currentMediaTimeMs ?? 0, durationMs: 1) else { return nil }
        return nil
    }
}

struct ClockReader: View {
    var body: some View { Text("\\(model.playbackClock.position.mediaTimeMs ?? 0)") }
}
"""
        self.assertEqual(
            ["Button.swift: PlaybackMarkCompleteButton", "Button.swift: ClockReader"],
            views_missing_the_clock({"Button.swift": button}))

    def test_the_scan_sees_the_known_playhead_views(self):
        sources = {path.name: re.sub(r"//[^\n]*", "", path.read_text()) for path in SOURCES.rglob("*.swift")}
        readers = {view for text in sources.values() for view, body in view_structs(text) if POSITION_READ.search(body)}
        for view in ("PlaybackScreen", "PlaybackNowView", "ReviewNewMarginsCard", "ExperienceTimelineRailScreen"):
            self.assertIn(view, readers)


if __name__ == "__main__":
    unittest.main()
