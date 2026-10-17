import contextlib
import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_public_tree", SCRIPTS / "check-public-tree.py")
tree = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tree)

# Built from pieces so this file doesn't itself look like a secret to the check or to other scanners.
PEM_HEADER = "-----BEGIN " + "EC PRIVATE KEY-----"
ANTHROPIC = "sk-ant-" + "test-0123456789-SECRET"
GITHUB = "ghp_" + "A" * 36
GITHUB_PAT = "github_pat_" + "B" * 30
AWS = "AKIA" + "ABCDEFGHIJKLMNOP"


class TempRepo:
    def __init__(self, test):
        self._dir = tempfile.TemporaryDirectory()
        test.addCleanup(self._dir.cleanup)
        self.root = Path(self._dir.name)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)

    def add(self, name, content=b""):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        subprocess.run(["git", "add", "-f", "--", name], cwd=self.root, check=True)
        return path

    def check(self, allowlist=""):
        return tree.check(self.root, allowlist)


class PublicTreeTests(unittest.TestCase):
    def test_clean_tree_passes(self):
        repo = TempRepo(self)
        repo.add("README.md", "hello\n")
        repo.add("App/Thing.swift", "let x = 1\n")
        self.assertEqual(repo.check(), [])

    def test_forbidden_paths_fail(self):
        cases = {
            "artifacts/results/log.txt": "build or test output under artifacts/",
            "Build/App.xcarchive/Info.plist": "Xcode archive",
            "x/embedded.mobileprovision": "provisioning profile",
            "keys/dev.p12": "signing identity",
            "keys/AuthKey_ABC.p8": "signing key",
            "keys/server.PEM": "key or certificate file",
            "server/.env": "environment file",
            "server/.env.production": "environment file",
        }
        for name, kind in cases.items():
            with self.subTest(name=name):
                repo = TempRepo(self)
                repo.add(name, "x")
                self.assertEqual(repo.check(), [f"{name}: {kind}"])

    def test_example_env_file_and_lookalike_paths_pass(self):
        for name in (".env.example", "docs/artifacts/notes.md", "my.pem.md", "Sources/envfile", "pem"):
            with self.subTest(name=name):
                repo = TempRepo(self)
                repo.add(name, "x")
                self.assertEqual(repo.check(), [])

    def test_secret_shapes_fail_with_line_and_kind_but_not_the_text(self):
        cases = {
            PEM_HEADER: "private key block",
            ANTHROPIC: "Anthropic key",
            GITHUB: "GitHub token",
            GITHUB_PAT: "GitHub token",
            AWS: "AWS access key",
        }
        for secret, kind in cases.items():
            with self.subTest(kind=kind):
                repo = TempRepo(self)
                repo.add("docs/notes.md", f"fine\nkey = {secret}\nfine\n")
                problems = repo.check()
                self.assertEqual(problems, [f"docs/notes.md:2: {kind}"])
                self.assertNotIn(secret, " ".join(problems))

    def test_lookalikes_do_not_fail(self):
        lines = [
            "the .pem file is described in a comment",
            'pem.Block{Type: "EC PRIVATE KEY"}',   # a Go type name, not a PEM block
            "sk-ant is a prefix; sk-ant-x too short",
            "ghp_short",
            "AKIA lowercase akiaabcdefghijklmnop",
            "github_pat_ alone",
        ]
        repo = TempRepo(self)
        repo.add("docs/notes.md", "\n".join(lines))
        self.assertEqual(repo.check(), [])

    def test_empty_binary_and_long_line_files(self):
        repo = TempRepo(self)
        repo.add("empty.txt", b"")
        repo.add("model.bin", b"\0" * 100 + ANTHROPIC.encode())   # binary: not scanned
        repo.add("long.txt", ("x" * 2_000_000 + " ").encode())
        self.assertEqual(repo.check(), [])
        repo.add("long2.txt", ("x" * 2_000_000 + " " + AWS).encode())
        self.assertEqual(repo.check(), ["long2.txt:1: AWS access key"])

    def test_non_utf8_text_is_scanned(self):
        repo = TempRepo(self)
        repo.add("latin.txt", b"caf\xe9\n" + GITHUB.encode() + b"\n")
        self.assertEqual(repo.check(), ["latin.txt:2: GitHub token"])

    def test_symlink_is_not_followed(self):
        repo = TempRepo(self)
        outside = repo.root / "outside.txt"
        outside.write_text(ANTHROPIC)   # untracked
        link = repo.root / "link.txt"
        os.symlink(outside, link)
        subprocess.run(["git", "add", "--", "link.txt"], cwd=repo.root, check=True)
        self.assertEqual(repo.check(), [])

    def test_allowlist_covers_a_listed_file_only(self):
        repo = TempRepo(self)
        repo.add("testdata/key.pem", "x")
        repo.add("tests/dummy.go", f'const k = "{ANTHROPIC}"\n')
        repo.add("tests/other.go", f'const k = "{ANTHROPIC}"\n')
        allow = "# comment\n\ntestdata/key.pem: public test certificate\ntests/dummy.go: dummy key\n"
        self.assertEqual(repo.check(allow), ["tests/other.go:1: Anthropic key"])

    def test_allowlist_entry_without_reason_or_for_untracked_file_fails(self):
        repo = TempRepo(self)
        repo.add("tests/dummy.go", f'const k = "{ANTHROPIC}"\n')
        problems = repo.check("tests/dummy.go\ngone/file.pem: was a vector\n: no path\n")
        self.assertIn("scripts/public-tree-allowlist.txt:1: tests/dummy.go has no reason", problems)
        self.assertIn("scripts/public-tree-allowlist.txt: gone/file.pem is listed but not tracked; remove the entry",
                      problems)
        self.assertIn("scripts/public-tree-allowlist.txt:3: empty path", problems)
        self.assertIn("tests/dummy.go:1: Anthropic key", problems)   # no reason, so not allowed

    def test_fast_plan_runs_the_check(self):
        source = (SCRIPTS / "verify-tests.py").read_text(encoding="utf-8")
        self.assertIn("self.command('public-tree', [sys.executable, 'scripts/check-public-tree.py'])", source)

    def test_main_exit_codes_and_message(self):
        repo = TempRepo(self)
        repo.add("README.md", "hello\n")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(tree.main(["--root", str(repo.root)]), 0)
        self.assertIn("1 tracked files scanned", out.getvalue())
        repo.add("artifacts/x.txt", "x")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(tree.main(["--root", str(repo.root)]), 1)
        self.assertIn("artifacts/x.txt: build or test output under artifacts/", err.getvalue())


if __name__ == "__main__":
    unittest.main()
