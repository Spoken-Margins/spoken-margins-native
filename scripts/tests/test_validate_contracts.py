import contextlib
import importlib.util
import io
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("validate_contracts", SCRIPTS / "validate-contracts.py")
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


class SharingFixtureValidationTests(unittest.TestCase):
    def run_validation(self, invalid_fixture=None):
        # Use real fixtures and schemas; only the unrelated asset subprocess is stubbed.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sharing = root / "fixtures" / "sharing"
            sharing.mkdir(parents=True)
            fixtures = contracts.CONTRACTS / "fixtures" / "sharing"
            maps = sorted(fixtures.glob("listening-map-proposal*.json"))
            self.assertEqual(len(maps), 9)
            for fixture in [*maps, fixtures / "margin-conversation.json"]:
                shutil.copyfile(fixture, sharing / fixture.name)
            if invalid_fixture:
                (sharing / invalid_fixture).write_text("{}", encoding="utf-8")
            output = io.StringIO()
            with patch.object(contracts, "CONTRACTS", root), \
                    patch.object(contracts, "SOURCE_CATALOG_PAIRS", []), \
                    patch.object(contracts, "NEGATIVE_PATH_SCHEMA_RULES", []), \
                    patch.object(contracts.subprocess, "run", return_value=subprocess.CompletedProcess(
                        args=[], returncode=0, stdout="Assets checked separately.", stderr="")), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                status = contracts.main()
            return status, output.getvalue()

    def test_valid_map_matrix_and_margin_conversation_pass(self):
        status, output = self.run_validation()
        self.assertEqual(status, 0, output)

    def test_invalid_map_matrix_fixture_is_not_skipped(self):
        name = "listening-map-proposal-native-text.json"
        status, output = self.run_validation(name)
        self.assertEqual(status, 1, output)
        self.assertIn(name, output)

    def test_invalid_margin_conversation_fixture_is_not_skipped(self):
        name = "margin-conversation.json"
        status, output = self.run_validation(name)
        self.assertEqual(status, 1, output)
        self.assertIn(name, output)


class PubMedRSSFixtureTests(unittest.TestCase):
    """#5201: the recorded PubMed search reply is checked against its schema, and a broken copy is caught."""

    FIXTURE = contracts.CONTRACTS / "fixtures" / "feeds" / "pubmed-rss" / "search-crispr-base-editing.xml"
    SCHEMA = contracts.SCHEMAS / "pubmed-rss.schema.json"

    def test_the_rule_covers_the_recorded_reply(self):
        rules = [rule for rule in contracts.PATH_SCHEMA_RULES if rule[0] == "fixtures/feeds/pubmed-rss/*.xml"]
        self.assertEqual(rules, [("fixtures/feeds/pubmed-rss/*.xml", "pubmed-rss.schema.json", "pubmed-rss")])
        self.assertEqual(sorted(contracts.CONTRACTS.glob(rules[0][0])), [self.FIXTURE])

    def test_the_recorded_reply_passes(self):
        self.assertEqual(contracts.validate_file(self.FIXTURE, self.SCHEMA, "pubmed-rss"), [])
        summary = contracts.pubmed_rss_summary(self.FIXTURE)
        self.assertEqual(summary["title"], "crispr base editing")
        self.assertEqual(len(summary["items"]), 15)

    def broken(self, old, new):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "broken.xml"
            text = self.FIXTURE.read_text(encoding="utf-8")
            self.assertIn(old, text)
            path.write_text(text.replace(old, new, 1), encoding="utf-8")
            return contracts.validate_file(path, self.SCHEMA, "pubmed-rss")

    def test_an_item_without_its_pmid_fails(self):
        self.assertTrue(self.broken("<dc:identifier>pmid:43070506</dc:identifier>", ""))

    def test_another_generator_fails(self):
        self.assertTrue(self.broken("PubMed RSS feeds (2.20.1)", "Some other feed"))

    def test_an_html_page_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "page.xml"
            path.write_text("<!doctype html><html><title>403</title>", encoding="utf-8")
            self.assertTrue(contracts.validate_file(path, self.SCHEMA, "pubmed-rss"))


if __name__ == "__main__":
    unittest.main()
