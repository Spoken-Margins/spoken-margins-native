"""A UI-test launch must not fetch the guided tour from the production server (#4071).

The startup fetch adds a `guided-onboarding` row, created "now", which sorts first under Recently added. Which row sat
on top of a UI test's Library then depended on the network (#3932 saw `library.row.item-pill` pushed onto page 2).
Unit tests are kept off the server by `isRunningUnitTests` (#2772); UI-test launches are kept off by
`UITestingHooks.fetchesGuidedTour`, which only a script that covers the tour turns back on (J10, against an
unreachable host).

Swift can't run here, so this reads the sources: every app call that asks the coordinator for the tour must sit
under that guard, so a second call site added later fails until it has one.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources"
UI_TESTS = ROOT / "App" / "SpokenMarginsAppUITests"
GUARD = "UITestingHooks.fetchesGuidedTour"
# The network call: a `refresh()` in a file that names the tour coordinator, whatever the local is called.
CALL = re.compile(r"\.refresh\(\)")
# The guard as a plain condition: not negated, and not in a comment.
GUARD_LINE = re.compile(r"(?<![!\w])" + re.escape(GUARD) + r"\b")
# The window of lines above a call that may hold its guard (the `guard` statement is a few lines long).
WINDOW = 12


def swift_files(folder: Path):
    return sorted(folder.rglob("*.swift"))


def mentions_tour_coordinator(text: str) -> bool:
    return "uidedOnboardingCoordinator" in text  # the type, or the model's `guidedOnboardingCoordinator` property


def unguarded_tour_calls(text: str) -> list[int]:
    lines = text.splitlines()
    bad = []
    for index, raw in enumerate(lines):
        if raw.strip().startswith("//") or not mentions_tour_coordinator(text) or not CALL.search(raw):
            continue
        window = lines[max(0, index - WINDOW):index]
        if not any(GUARD_LINE.search(earlier) and not earlier.strip().startswith("//") for earlier in window):
            bad.append(index + 1)
    return bad


class GuidedTourFetchTests(unittest.TestCase):
    def test_scan_flags_a_call_without_the_guard(self):
        guarded = "let c: GuidedOnboardingCoordinator\nguard !a,\n  UITestingHooks.fetchesGuidedTour,\n  let coordinator = c else { return }\ntry await coordinator.refresh()\n"
        self.assertEqual(unguarded_tour_calls(guarded), [])
        unguarded = "let c: GuidedOnboardingCoordinator\nguard !a, let coordinator = c else { return }\ntry await coordinator.refresh()\n"
        self.assertEqual(unguarded_tour_calls(unguarded), [3])
        commented = "// GuidedOnboardingCoordinator\n// try await coordinator.refresh()\n"
        self.assertEqual(unguarded_tour_calls(commented), [])
        # A guard named only in a comment, or negated, doesn't count; another local name is still a call.
        in_comment = "let c: GuidedOnboardingCoordinator\n// UITestingHooks.fetchesGuidedTour\ntry await c.refresh()\n"
        self.assertEqual(unguarded_tour_calls(in_comment), [3])
        negated = "let c: GuidedOnboardingCoordinator\nguard !UITestingHooks.fetchesGuidedTour else { return }\ntry await guidedOnboardingCoordinator?.refresh()\n"
        self.assertEqual(unguarded_tour_calls(negated), [3])

    def test_the_app_fetches_the_tour_in_one_place_and_guards_it(self):
        calls = []
        for path in swift_files(APP_SOURCES):
            text = path.read_text(encoding="utf-8")
            if not mentions_tour_coordinator(text):
                continue
            for number in unguarded_tour_calls(text):
                calls.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(calls, [], f"fetches the guided tour without {GUARD} above it")
        sites = [p for p in swift_files(APP_SOURCES)
                 if CALL.search(p.read_text(encoding="utf-8")) and mentions_tour_coordinator(p.read_text(encoding="utf-8"))]
        self.assertTrue(sites, "the scan found no tour fetch at all; the call moved, so update CALL")

    def test_a_script_that_opts_in_launches_against_an_unreachable_host(self):
        # An opt-in with the production host would bring the race back; J10 pairs it with `-SMServerHost offline.invalid`.
        opted_in = 0
        for path in swift_files(UI_TESTS):
            text = path.read_text(encoding="utf-8")
            if 'launchEnvironment["SPOKEN_MARGINS_UI_TEST_GUIDED_TOUR_FETCH"]' in text:
                opted_in += 1
                self.assertRegex(text, r'"-SMServerHost",\s*"offline\.invalid"',
                                 f"{path.name} opts in to the tour fetch without an unreachable server host")
        self.assertGreaterEqual(opted_in, 1, "no script opts in to the guided tour fetch; J10 should")


if __name__ == "__main__":
    unittest.main()
