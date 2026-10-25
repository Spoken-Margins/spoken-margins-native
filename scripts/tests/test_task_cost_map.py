"""The listener's most frequent actions have a tap budget, and a route that grows fails here (#2396).

docs/task-cost-map.json lists, per action, the routes a listener takes and the control each step uses. A source
scan checks that every control still exists where the map says it does, and that a route's tap count (a swipe
counts as one) stays within its budget. A control that was renamed or removed means the route changed: update
the map in the same change, so the new cost is in the diff for review.
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
MAP = json.loads((ROOT / "docs" / "task-cost-map.json").read_text())
COUNTED = set(MAP["countedKinds"])
FREE = set(MAP["freeKinds"])
ACTIONS = ("mark-complete", "add-margin", "find-item", "resume-listening", "share-margin",
           "check-item-margins", "follow-show", "collect-episodes")


def cost(route: dict) -> int:
    return sum(1 for step in route["steps"] if step["do"] in COUNTED)


def source(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class TaskCostMapTests(unittest.TestCase):
    def test_the_map_covers_the_actions_the_issue_names(self):
        self.assertEqual([a["id"] for a in MAP["actions"]], list(ACTIONS))

    def test_every_step_names_a_control_that_still_exists(self):
        for action in MAP["actions"]:
            for route in action["routes"]:
                for step in route["steps"]:
                    with self.subTest(action=action["id"], route=route["route"], step=step["label"]):
                        self.assertIn(step["do"], COUNTED | FREE)
                        if step["do"] in ("tap", "swipe"):
                            self.assertIn("marker", step, "a tap or swipe needs the control it uses")
                        if "marker" in step:
                            self.assertTrue(step["marker"] in source(step["file"]),
                                            f"{step['file']} no longer has {step['marker']}: the route changed, update docs/task-cost-map.json")

    def test_no_route_costs_more_than_its_budget(self):
        for action in MAP["actions"]:
            for route in action["routes"]:
                with self.subTest(action=action["id"], route=route["route"]):
                    self.assertLessEqual(cost(route), route["budget"],
                                         "this route takes more taps than its budget: make it cheaper, or raise the budget on purpose in the same diff")


if __name__ == "__main__":
    unittest.main()
