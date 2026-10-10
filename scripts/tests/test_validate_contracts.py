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


if __name__ == "__main__":
    unittest.main()
