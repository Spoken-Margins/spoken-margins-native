"""Persona packs in the source catalog (#4285): the schema and `validate_source_catalog` reject what the app would
silently trim, and the valid fixture passes both."""
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
FIXTURE = ROOT / "Contracts/fixtures/source-catalog/packs-small.json"
INVALID = ROOT / "Contracts/fixtures/invalid/source-catalog/pack-with-three-entries.json"
SCHEMA = ROOT / "Contracts/schemas/source-catalog.schema.json"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


contracts = load("validate_contracts", SCRIPTS / "validate-contracts.py")


def fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


class PacksContractTests(unittest.TestCase):
    def semantic_errors(self, catalog):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "catalog.json"
            path.write_text(json.dumps(catalog), encoding="utf-8")
            return contracts.validate_source_catalog(path)

    def schema_errors(self, catalog):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "catalog.json"
            path.write_text(json.dumps(catalog), encoding="utf-8")
            return contracts.validate_file(path, SCHEMA)

    def test_the_valid_fixture_passes_the_schema_and_the_reference_rules(self):
        self.assertEqual(contracts.validate_file(FIXTURE, SCHEMA), [])
        self.assertEqual(self.semantic_errors(fixture()), [])
        catalog = fixture()
        self.assertEqual(len(catalog["packs"]), 2)
        self.assertTrue(any("recentPublishedAt" in entry for entry in catalog["entries"]))

    def test_a_pack_of_three_entries_fails_the_schema_for_that_reason(self):
        errors = contracts.validate_file(INVALID, SCHEMA)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("packs", errors[0])
        self.assertIn("too short", errors[0])

    def test_schema_bounds_on_a_pack(self):
        cases = {
            "thirteen entries": lambda p: p.update(entryIds=[f"pack-fixture-{i:02d}" for i in range(1, 14)]),
            "repeated entry": lambda p: p.update(entryIds=["pack-fixture-01"] * 4),
            "title over 40": lambda p: p.update(title="x" * 41),
            "empty title": lambda p: p.update(title=""),
            "summary over 90": lambda p: p.update(summary="x" * 91),
            "missing summary": lambda p: p.pop("summary"),
            "uppercase id": lambda p: p.update(id="Curious"),
            "unknown field": lambda p: p.update(color="red"),
        }
        for name, change in cases.items():
            with self.subTest(name):
                catalog = fixture()
                change(catalog["packs"][0])
                self.assertTrue(self.schema_errors(catalog), name)

    def test_schema_bounds_on_recent_published_dates(self):
        catalog = fixture()
        catalog["entries"][0]["recentPublishedAt"] = ["2026-11-01T00:00:00Z"] * 21
        self.assertTrue(self.schema_errors(catalog))
        catalog = fixture()
        catalog["entries"][0]["recentPublishedAt"] = ["yesterday"]
        self.assertTrue(self.schema_errors(catalog))

    def test_a_pack_naming_a_missing_entry_is_reported(self):
        catalog = fixture()
        catalog["packs"][0]["entryIds"][1] = "pack-fixture-99"
        errors = self.semantic_errors(catalog)
        self.assertEqual(len(errors), 1)
        self.assertIn("unknown entry 'pack-fixture-99'", errors[0])
        self.assertTrue(errors[0].startswith(str(Path(tempfile.gettempdir()))), "the message names the catalog file, not a feed path")

    def test_two_packs_with_one_id_are_reported(self):
        catalog = fixture()
        catalog["packs"][1]["id"] = catalog["packs"][0]["id"]
        self.assertTrue(any("duplicate pack ids" in error for error in self.semantic_errors(catalog)))

    def test_a_pack_naming_an_explicit_or_unfollowable_entry_is_reported(self):
        catalog = fixture()
        catalog["packs"][0]["entryIds"][0] = "pack-fixture-09"  # explicit
        self.assertTrue(any("does not offer" in error for error in self.semantic_errors(catalog)))
        catalog = fixture()
        for entry in catalog["entries"]:
            if entry["id"] == "pack-fixture-02":
                entry["kind"] = "bridged_site"  # this build can't follow it
        self.assertTrue(any("does not offer" in error for error in self.semantic_errors(catalog)))

    def test_a_catalog_without_packs_still_passes(self):
        catalog = fixture()
        del catalog["packs"]
        self.assertEqual(self.semantic_errors(catalog), [])
        self.assertEqual(self.schema_errors(catalog), [])


if __name__ == "__main__":
    unittest.main()
