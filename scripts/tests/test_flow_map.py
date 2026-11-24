"""The flow map's sharing loop (#5280): the PR-time anchor check, the changed-file lookup, two-person tap counts and
captures."""
import copy
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = load("flow_map_check", "scripts/flow-map-check.py")
captures = load("flow_map_captures", "scripts/flow-map-captures.py")
taps = load("compute_taps", "Design/proposals/compute-taps.py")
FLOW = json.loads((ROOT / "Design/flow-map/flow-map.json").read_text(encoding="utf-8"))
PLAYBACK = "App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackScreen.swift"


class SharingAnchorCheckTests(unittest.TestCase):
    def test_removing_the_players_share_fails_the_pr_check(self):
        # The Build 36 failure: a sharing control removed without the map changing. e120 is the player's Share.
        flow = copy.deepcopy(FLOW)
        missing, _, _, problems = check.check(flow, only_sharing=True)
        self.assertEqual((missing, problems), ([], []), "the sharing loop on the map no longer matches the code")
        share = next(e for e in flow["edges"] if e["id"] == "e120")
        share["anchor"] = "Button(action: model.openPlaybackShareThatWasRemoved)"
        missing, _, _, _ = check.check(flow, only_sharing=True)
        self.assertEqual([e["id"] for e, _ in missing], ["e120"])

    def test_the_pr_check_leaves_non_sharing_arrows_to_the_full_check(self):
        flow = copy.deepcopy(FLOW)
        settings = next(e for e in flow["edges"] if not e.get("sharing") and e["from"] == "SettingsScreen")
        settings["anchor"] = "not in any file"
        self.assertEqual(check.check(flow, only_sharing=True)[0], [])
        self.assertEqual([e["id"] for e, _ in check.check(flow)[0]], [settings["id"]])

    def test_a_sharing_screen_without_a_capture_status_or_a_ruling_quote_is_a_problem(self):
        flow = copy.deepcopy(FLOW)
        screen = next(s for s in flow["screens"] if s.get("sharing"))
        del screen["capture"]
        flow["rulings"][0]["anchor"] = "words the owner never said"
        problems = check.check(flow, only_sharing=True)[3]
        self.assertTrue(any(screen["id"] in p and "capture" in p for p in problems), problems)
        self.assertTrue(any(p.startswith("ruling r01") for p in problems), problems)

    def test_a_broken_capture_must_say_what_was_seen(self):
        flow = copy.deepcopy(FLOW)
        screen = next(s for s in flow["screens"] if s.get("capture", {}).get("status") == "pass")
        screen["capture"]["status"] = "broken"
        self.assertTrue(any("what was seen" in p for p in check.check(flow, only_sharing=True)[3]))


class ChangedPathsTests(unittest.TestCase):
    def git(self, cwd, *args):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], cwd=cwd, check=True,
                       capture_output=True)

    def test_a_depth_one_ci_checkout_of_a_merge_commit_still_finds_the_prs_files(self):
        # hosted-portable.yml checks out GitHub's merge commit at depth 1, where HEAD^1 does not exist (review of #5280).
        with tempfile.TemporaryDirectory() as tmp:
            origin, clone = pathlib.Path(tmp, "origin"), pathlib.Path(tmp, "clone")
            origin.mkdir()
            self.git(origin, "init", "-q", "-b", "main")
            self.git(origin, "config", "uploadpack.allowAnySHA1InWant", "true")
            (origin / "base.txt").write_text("base")
            self.git(origin, "add", ".")
            self.git(origin, "commit", "-q", "-m", "base")
            self.git(origin, "checkout", "-q", "-b", "pr")
            (origin / "Web").mkdir()
            (origin / "Web" / "arrival.tsx").write_text("pr")
            self.git(origin, "add", ".")
            self.git(origin, "commit", "-q", "-m", "pr")
            self.git(origin, "checkout", "-q", "main")
            (origin / "other.txt").write_text("main moved on")
            self.git(origin, "add", ".")
            self.git(origin, "commit", "-q", "-m", "main")
            self.git(origin, "merge", "-q", "--no-ff", "-m", "merge pr", "pr")
            self.git(tmp, "clone", "-q", "--depth=1", f"file://{origin}", str(clone))
            self.assertEqual(check.changed_paths(clone, {"GITHUB_ACTIONS": "true"}), ["Web/arrival.tsx"])


class TouchedLookupTests(unittest.TestCase):
    def test_a_change_to_the_player_names_the_share_sheet_its_neighbours_and_rulings(self):
        lines = "\n".join(check.touched(FLOW, [PLAYBACK]))
        self.assertIn("- Build23SenderSharingExperience (Share Margins", lines)
        self.assertIn("from PlaybackScreen: Share Margins (square.and.arrow.up) [e120]", lines)
        self.assertIn("ruling r14 (2026-11-03, docs/decisions.md:", lines)  # Share keeps its name
        self.assertIn("Jobs through them:", lines)

    def test_a_web_file_finds_the_browser_listener(self):
        lines = "\n".join(check.touched(FLOW, ["Web/src/app/screens/Arrival.tsx"]))
        self.assertIn("WebArrivalPreview", lines)
        self.assertIn("surface web; capture pass captures/WebArrivalPreview.jpg", lines)

    def test_a_file_with_no_sharing_arrow_touches_nothing(self):
        self.assertEqual(check.touched(FLOW, ["App/SpokenMarginsApp/Sources/SpokenMarginsApp/SettingsScreen.swift",
                                              "docs/journeys.md"]), [])


class TwoPersonJobTests(unittest.TestCase):
    EDGES = [
        {"id": "a", "from": "Now", "to": "Share", "control": "Share", "control_kind": "button"},
        {"id": "b", "from": "Share", "to": "Bubble", "control": "Messages", "control_kind": "button"},
        {"id": "c", "from": "Bubble", "to": "Page", "control": "Tap the link", "control_kind": "link"},
        {"id": "d", "from": "Page", "to": "Player", "control": "(no tap) opens", "control_kind": "auto"},
        {"id": "e", "from": "Player", "to": "Menu", "control": "More > Reply", "control_kind": "menu item"},
    ]

    def job(self, **friend):
        leg = {"person": "friend", "handoff": "A link in Messages", "start": "Bubble", "target": "Player", "final_cost": 1}
        leg.update(friend)
        return {"id": "s", "name": "Send", "legs": [
            {"person": "sender", "start": "Now", "target": "Bubble", "final_cost": 1}, leg]}

    def test_each_person_has_their_own_taps_and_an_automatic_page_costs_none(self):
        job = self.job()
        total, route = taps.compute_job(job, self.EDGES, "Now")
        self.assertEqual(total, 5)
        self.assertEqual(dict(taps.person_taps(job, self.EDGES, "Now")), {"sender": 3, "friend": 2})
        self.assertIn("hand-off: A link in Messages", route)
        self.assertEqual(taps.taps_label(job, (total, route), self.EDGES, "Now"), "5 (sender 3, friend 2)")

    def test_a_change_of_person_needs_a_hand_off_and_the_same_person_does_not(self):
        screens = {s: {"id": s} for s in ("Now", "Share", "Bubble", "Page", "Player", "Menu")}
        job = self.job(handoff="")
        problems = taps.check({"screens": list(screens.values())}, None, screens, self.EDGES, [job], "Now")
        self.assertEqual(problems, ["job s leg 2 names no hand-off"])
        job["legs"][1].update(person="sender")
        self.assertEqual(taps.check({"screens": list(screens.values())}, None, screens, self.EDGES, [job], "Now"), [])

    def test_every_job_on_the_map_has_a_route_and_the_sharing_jobs_count_both_people(self):
        result = taps.compute_all(FLOW["edges"], FLOW["jobs"], FLOW["start"])
        self.assertEqual([jid for jid, r in result.items() if r is None], [])
        for job in (j for j in FLOW["jobs"] if "legs" in j):
            self.assertEqual(set(taps.person_taps(job, FLOW["edges"], FLOW["start"])), {"sender", "friend"}, job["id"])


class CaptureTests(unittest.TestCase):
    def test_named_screenshots_land_on_their_screens_and_a_failed_step_is_marked_broken(self):
        flow = {"screens": [{"id": "PlaybackScreen"}, {"id": "WebArrivalPreview"}, {"id": "JOIN_PAGE"}]}
        with tempfile.TemporaryDirectory() as tmp:
            run = pathlib.Path(tmp)
            (run / "Class-test-1").mkdir()
            (run / "Class-test-1" / "flowmap-PlaybackScreen_1_0A1B2C3D-0000-4000-8000-00000000ABCD.png").write_bytes(b"x")
            (run / "Class-test-1" / "flowmap-PlaybackScreen--friend-margin_2_0A1B2C3D-0000-4000-8000-00000000ABCE.png").write_bytes(b"x")
            (run / "flowmap-WebArrivalPreview.png").write_bytes(b"x")
            (run / "flowmap-NotOnTheMap.png").write_bytes(b"x")
            found = captures.find(run)
            recorded, unknown = captures.apply(flow, found, "abc1234", "J12", {"JOIN_PAGE": "Blank page"}, "2026-11-24",
                                               lambda src, dst: dst)
        screens = {s["id"]: s["capture"] for s in flow["screens"]}
        self.assertEqual(unknown, ["NotOnTheMap"])
        self.assertEqual(screens["PlaybackScreen"]["status"], "pass")
        self.assertEqual(screens["PlaybackScreen"]["file"], "captures/PlaybackScreen.jpg")
        self.assertEqual(screens["PlaybackScreen"]["variants"][0]["name"], "friend-margin")
        self.assertEqual(screens["WebArrivalPreview"]["commit"], "abc1234")
        self.assertEqual((screens["JOIN_PAGE"]["status"], screens["JOIN_PAGE"]["seen"]), ("broken", "Blank page"))
        self.assertIn("JOIN_PAGE (broken)", recorded)


if __name__ == "__main__":
    unittest.main()
