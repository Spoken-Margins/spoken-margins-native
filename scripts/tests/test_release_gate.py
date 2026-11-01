"""The release check that holds external builds with share-link creation on until the gate record is complete (#2236)."""
import copy
import datetime
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release_gate.py"
spec = importlib.util.spec_from_file_location("release_gate", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

TODAY = datetime.date(2026, 11, 15)
COMPLETE_WITH_INSURANCE = {
    "llc": {"formed": True},
    "dmca_agent": {"registered": True, "registration_number": "DMCA-1234567", "registered_on": "2026-11-01",
                   "page_url": "https://example.test/dmca", "page_live": True},
    "insurance": {"in_place": True},
    "waiver": {"granted_on": "2026-10-28", "no_revenue": True, "external_testers": 500},
}
COMPLETE_WITH_WAIVER = copy.deepcopy(COMPLETE_WITH_INSURANCE)
COMPLETE_WITH_WAIVER["insurance"]["in_place"] = False
COMPLETE_WITH_WAIVER["waiver"]["external_testers"] = 12
ON = {gate.PLIST_KEY: True}
OFF = {gate.PLIST_KEY: False}
OLD_BUILD = {"CFBundleVersion": "34"}


def record_with(base, section, **changes):
    record = copy.deepcopy(base)
    record.setdefault(section, {}).update(changes)
    return record


class DecideTests(unittest.TestCase):
    def allowed(self, destination, plist, record):
        return gate.decide(destination, plist, record, TODAY)[0]

    def test_creation_on_is_refused_for_external_while_the_record_is_incomplete(self):
        for record in ({}, gate_record_default(), record_with(COMPLETE_WITH_WAIVER, "llc", formed=False)):
            self.assertFalse(self.allowed("external", ON, record))

    def test_creation_on_is_allowed_for_external_once_complete(self):
        self.assertTrue(self.allowed("external", ON, COMPLETE_WITH_INSURANCE))
        self.assertTrue(self.allowed("external", ON, COMPLETE_WITH_WAIVER))

    def test_creation_off_is_always_allowed(self):
        for plist in (OFF, OLD_BUILD, {**OLD_BUILD, "CFBundleVersion": "9"}):
            for record in ({}, gate_record_default(), COMPLETE_WITH_INSURANCE):
                self.assertTrue(self.allowed("external", plist, record))

    def test_internal_group_is_always_allowed(self):
        self.assertTrue(self.allowed("internal", ON, {}))

    def test_a_key_that_is_not_a_boolean_counts_as_on_and_says_why(self):
        for value in ("NO", "YES", 0, 1, None):
            allowed, reasons = gate.decide("external", {gate.PLIST_KEY: value}, COMPLETE_WITH_INSURANCE, TODAY)
            self.assertFalse(allowed, value)
            self.assertIn("not a boolean", " ".join(reasons))

    def test_a_missing_key_is_off_only_for_builds_that_predate_it(self):
        for build in ("35", "100", "", "34a", "-1", None):
            plist = {} if build is None else {"CFBundleVersion": build}
            allowed, reasons = gate.decide("external", plist, COMPLETE_WITH_INSURANCE | {"llc": {}}, TODAY)
            self.assertFalse(allowed, build)
            self.assertIn("missing", " ".join(reasons))
        self.assertTrue(self.allowed("external", {"CFBundleVersion": "35", gate.PLIST_KEY: False}, {}))

    def test_future_dates_and_compact_dates_do_not_count(self):
        for value in ("2099-01-01", "2026-11-16", "20261101", "2026-1-1", "2026-11-01T00:00"):
            record = record_with(COMPLETE_WITH_INSURANCE, "dmca_agent", registered_on=value)
            self.assertFalse(self.allowed("external", ON, record), value)
        for value in ("2099-01-01", "20261028"):
            record = record_with(COMPLETE_WITH_WAIVER, "waiver", granted_on=value)
            self.assertFalse(self.allowed("external", ON, record), value)
        self.assertTrue(self.allowed("external", ON, record_with(COMPLETE_WITH_INSURANCE, "dmca_agent", registered_on="2026-11-15")))

    def test_each_agent_field_is_required(self):
        for field, value in (("registered", False), ("registration_number", ""), ("registration_number", "  "),
                             ("registered_on", None), ("registered_on", "11/01/2026"), ("page_url", None),
                             ("page_live", False), ("page_live", "true")):
            record = record_with(COMPLETE_WITH_INSURANCE, "dmca_agent", **{field: value})
            self.assertFalse(self.allowed("external", ON, record), (field, value))

    def test_lookalike_truthy_values_do_not_open_the_gate(self):
        for value in ("true", "yes", 1):
            record = record_with(COMPLETE_WITH_INSURANCE, "llc", formed=value)
            self.assertFalse(self.allowed("external", ON, record), value)
            record = record_with(COMPLETE_WITH_INSURANCE, "insurance", in_place=value)
            record["waiver"] = {}
            self.assertFalse(self.allowed("external", ON, record), value)

    def test_registration_lapses_after_three_years(self):
        record = record_with(COMPLETE_WITH_INSURANCE, "dmca_agent", registered_on="2023-11-15")
        self.assertFalse(gate.decide("external", ON, record, datetime.date(2026, 11, 15))[0])
        self.assertTrue(gate.decide("external", ON, record, datetime.date(2026, 11, 14))[0])
        leap = record_with(COMPLETE_WITH_INSURANCE, "dmca_agent", registered_on="2024-02-29")
        self.assertTrue(gate.decide("external", ON, leap, datetime.date(2027, 2, 28))[0])
        self.assertFalse(gate.decide("external", ON, leap, datetime.date(2027, 3, 1))[0])

    def test_waiver_without_insurance_closes_when_either_limit_is_crossed(self):
        self.assertTrue(self.allowed("external", ON, COMPLETE_WITH_WAIVER))
        for changes in ({"external_testers": 100}, {"external_testers": 101}, {"no_revenue": False},
                        {"external_testers": -1}, {"external_testers": "12"}, {"external_testers": True},
                        {"external_testers": None}, {"granted_on": None}, {"granted_on": "yesterday"}):
            record = record_with(COMPLETE_WITH_WAIVER, "waiver", **changes)
            self.assertFalse(self.allowed("external", ON, record), changes)
        self.assertTrue(self.allowed("external", ON, record_with(COMPLETE_WITH_WAIVER, "waiver", external_testers=99)))

    def test_insurance_ignores_the_waiver_limits(self):
        record = record_with(COMPLETE_WITH_INSURANCE, "waiver", no_revenue=False, external_testers=5000)
        self.assertTrue(self.allowed("external", ON, record))

    def test_malformed_sections_refuse_instead_of_raising(self):
        for record in ({"llc": "yes"}, {"dmca_agent": [], "llc": None}, {"insurance": 3}):
            self.assertFalse(self.allowed("external", ON, record))

    def test_the_shipped_record_is_closed_until_the_owner_fills_it_in(self):
        record = gate.read_record(gate.DEFAULT_RECORD)
        self.assertTrue(record["llc"]["formed"])
        self.assertFalse(self.allowed("external", ON, record))
        self.assertTrue(self.allowed("external", OFF, record))
        self.assertTrue(self.allowed("internal", ON, record))


def gate_record_default():
    return json.loads(gate.DEFAULT_RECORD.read_text(encoding="utf-8"))


def agent_record(**agent):
    record = copy.deepcopy(COMPLETE_WITH_WAIVER)
    record["dmca_agent"].update(agent)
    return record


class RenewalNoticeTests(unittest.TestCase):
    """The owner is reminded before the three-year designation lapses (#2236 step 5)."""

    def test_nothing_is_due_before_the_agent_is_registered(self):
        act, line = gate.renewal_notice({}, TODAY)
        self.assertFalse(act)
        self.assertIn("not registered", line)
        self.assertFalse(gate.renewal_notice(agent_record(registered=False, registered_on="2023-12-01"), TODAY)[0])

    def test_the_reminder_opens_90_days_before_the_lapse_and_stays_open_after_it(self):
        lapse = datetime.date(2029, 11, 20)  # registered 2026-11-20
        record = agent_record(registered_on="2026-11-20")
        before = lapse - datetime.timedelta(days=gate.RENEWAL_LEAD_DAYS + 1)
        self.assertFalse(gate.renewal_notice(record, before)[0])
        on_edge = gate.renewal_notice(record, lapse - datetime.timedelta(days=gate.RENEWAL_LEAD_DAYS))
        self.assertTrue(on_edge[0])
        self.assertIn("2029-11-20", on_edge[1])
        self.assertTrue(gate.renewal_notice(record, lapse - datetime.timedelta(days=1))[0])
        lapsed = gate.renewal_notice(record, lapse)
        self.assertTrue(lapsed[0])
        self.assertIn("lapsed", lapsed[1])
        self.assertTrue(gate.renewal_notice(record, lapse + datetime.timedelta(days=400))[0])

    def test_a_registered_agent_with_no_usable_date_asks_for_the_date(self):
        for date in (None, "", "11/20/2026", "20261120", "2999-01-01", 7):
            act, line = gate.renewal_notice(agent_record(registered_on=date), TODAY)
            self.assertTrue(act, date)
            self.assertIn("registration date", line)

    def test_a_leap_day_registration_is_dated_like_the_gate(self):
        record = agent_record(registered_on="2028-02-29")
        self.assertIn("2031-03-01", gate.renewal_notice(record, datetime.date(2031, 2, 1))[1])

    def test_the_shipped_record_has_nothing_due_yet(self):
        record = json.loads(gate.DEFAULT_RECORD.read_text(encoding="utf-8"))
        self.assertFalse(gate.renewal_notice(record, TODAY)[0])


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def archive(self, plist):
        app = self.dir / "Build.xcarchive" / "Products" / "Applications" / "SpokenMargins.app"
        app.mkdir(parents=True, exist_ok=True)
        (app / "Info.plist").write_bytes(plistlib.dumps(plist))
        return app.parents[2]

    def record(self, data):
        path = self.dir / "record.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def run_gate(self, build, record, destination="external"):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--destination", destination, "--record", str(record), str(build)],
            capture_output=True, text=True, env={**os.environ, "SM_RELEASE_GATE_TODAY": TODAY.isoformat()})

    def test_refused_then_allowed_for_an_archive_with_creation_on(self):
        build = self.archive({"CFBundleVersion": "35", gate.PLIST_KEY: True})
        refused = self.run_gate(build, self.record({"llc": {"formed": True}}))
        self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
        self.assertIn("REFUSED", refused.stderr)
        self.assertIn("DMCA designated agent", refused.stderr)
        allowed = self.run_gate(build, self.record(COMPLETE_WITH_INSURANCE))
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertIn("allowed", allowed.stdout)

    def test_creation_off_is_allowed_with_an_empty_record(self):
        for plist in ({"CFBundleVersion": "34"}, {"CFBundleVersion": "35", gate.PLIST_KEY: False}):
            self.assertEqual(self.run_gate(self.archive(plist), self.record({})).returncode, 0)

    def test_a_bare_plist_and_an_app_bundle_are_read_too(self):
        plist = self.dir / "Info.plist"
        plist.write_bytes(plistlib.dumps({gate.PLIST_KEY: True}))
        self.assertEqual(self.run_gate(plist, self.record({})).returncode, 1)
        app = self.archive({gate.PLIST_KEY: True}) / "Products" / "Applications" / "SpokenMargins.app"
        self.assertEqual(self.run_gate(app, self.record({})).returncode, 1)

    def test_unreadable_inputs_exit_2_never_allow(self):
        build = self.archive({gate.PLIST_KEY: True})
        self.assertEqual(self.run_gate(self.dir / "missing.xcarchive", self.record({})).returncode, 2)
        self.assertEqual(self.run_gate(build, self.dir / "no-such-record.json").returncode, 2)
        broken = self.dir / "broken.json"
        broken.write_text("{", encoding="utf-8")
        self.assertEqual(self.run_gate(build, broken).returncode, 2)
        truncated = self.dir / "Truncated.plist"
        truncated.write_text('<?xml version="1.0"?><plist><dict><key>a', encoding="utf-8")
        self.assertEqual(self.run_gate(truncated, self.record({})).returncode, 2)
        empty = self.dir / "Empty.xcarchive"
        (empty / "Products" / "Applications").mkdir(parents=True)
        self.assertEqual(self.run_gate(empty, self.record({})).returncode, 2)

    def run_renewal(self, record, *extra):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--renewal-notice", "--record", str(record), *extra],
            capture_output=True, text=True, env={**os.environ, "SM_RELEASE_GATE_TODAY": datetime.date(2029, 10, 1).isoformat()})

    def test_renewal_notice_exits_1_with_one_line_inside_the_window_and_0_outside(self):
        due = self.run_renewal(self.record(agent_record(registered_on="2026-11-20")))
        self.assertEqual(due.returncode, 1, due.stderr)
        self.assertEqual(len(due.stdout.strip().splitlines()), 1)
        self.assertIn("2029-11-20", due.stdout)
        quiet = self.run_renewal(self.record(agent_record(registered_on="2027-11-20")))
        self.assertEqual(quiet.returncode, 0, quiet.stderr)
        self.assertEqual(self.run_renewal(self.record({})).returncode, 0)

    def test_renewal_notice_with_an_unreadable_record_exits_2_and_takes_no_build(self):
        self.assertEqual(self.run_renewal(self.dir / "no-such-record.json").returncode, 2)
        self.assertEqual(self.run_renewal(self.record({}), str(self.dir)).returncode, 2)

    def test_the_destination_is_required(self):
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.dir)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
