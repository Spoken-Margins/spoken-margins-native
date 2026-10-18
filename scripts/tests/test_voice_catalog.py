"""scripts/voice_catalog.py (#1818): the checks that keep the site's voice catalog honest.

`check` runs against a real HTTP server on this machine that serves files whose bytes the test then changes, so
the hashing, the ETag shortcut and the hold-back are exercised end to end, not through a stub. Signing uses a real
Ed25519 key; publishing runs against a stand-in for the network and for the deploy script, the only two things it
can't reach from a test.
"""
import copy
import hashlib
import http.server
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import datetime as dt  # noqa: E402

import voice_catalog as vc  # noqa: E402
import voice_catalog_tools as tools  # noqa: E402

try:
    import cryptography  # noqa: F401
    HAVE_CRYPTO = True
except ImportError:
    HAVE_CRYPTO = False

NOW = dt.datetime(2026, 10, 18, 12, 0, tzinfo=dt.timezone.utc)
BIG = b"model bytes " * 100
SMALL = b'{"style": 1}\n'
LICENCE = b"Example licence\nYou may use this.\nYou may not misuse it.\n"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Server:
    """Serves whatever `files` holds, counts requests, and can be told to change its answers."""

    def __init__(self):
        self.files: dict[str, tuple[int, bytes]] = {}
        self.hits: list[tuple[str, str]] = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def _serve(self, send_body: bool):
                outer.hits.append((self.command, self.path))
                status, body = outer.files.get(self.path, (404, b""))
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("ETag", '"%s"' % sha(body)[:16])
                self.end_headers()
                if send_body:
                    self.wfile.write(body)

            def do_HEAD(self):
                self._serve(False)

            def do_GET(self):
                self._serve(True)

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_port}/"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def gets(self, path: str) -> int:
        return sum(1 for method, p in self.hits if method == "GET" and p == path)


def make_sources(base: str, reviewed_dir: Path) -> dict:
    (reviewed_dir / "licenses").mkdir(parents=True, exist_ok=True)
    (reviewed_dir / "licenses" / "example.txt").write_bytes(LICENCE)
    return {
        "schemaVersion": vc.SOURCES_VERSION,
        "site": {"baseURL": base, "mirrorPath": "voices/files/"},
        "voices": [
            {
                "id": "alpha", "displayName": "Alpha", "publisher": "Example Co", "version": "1.0",
                "runtime": {"name": "onnxruntime", "version": "1.24.2"}, "minimumIOSVersion": "26.0",
                "minimumMemoryMegabytes": 4096, "status": "available", "bundled": False,
                "mirrorDir": "alpha/1.0/", "mirrorFrom": "stage-src/",
                "files": [
                    {"path": "model.onnx", "byteCount": len(BIG), "sha256": sha(BIG), "upstream": base + "up/model.onnx", "mirrored": True, "licenseId": "example"},
                    {"path": "styles/a.json", "byteCount": len(SMALL), "sha256": sha(SMALL), "mirrored": True},
                ],
                "licenses": [{"id": "example", "name": "Example Licence", "textURL": base + "pinned/LICENSE", "watchURL": base + "current/LICENSE",
                              "textSHA256": sha(LICENCE), "reviewedText": "licenses/example.txt", "requiresAcceptance": True,
                              "restrictionsSummary": "Do not misuse it."}],
            },
            {
                "id": "beta", "displayName": "Beta", "publisher": "Other Co", "version": "2",
                "runtime": {"name": "onnxruntime", "version": "1.24.2"}, "minimumIOSVersion": "26.0",
                "minimumMemoryMegabytes": 2048, "status": "available", "bundled": True, "files": [],
                "licenses": [{"id": "beta-licence", "name": "Beta Licence", "textURL": base + "beta/LICENSE", "textSHA256": sha(LICENCE),
                              "reviewedText": "licenses/example.txt", "requiresAcceptance": False}],
            },
        ],
    }


def serve_everything(server: Server, sources: dict) -> None:
    alpha = sources["voices"][0]
    server.files["/up/model.onnx"] = (200, BIG)
    server.files["/voices/files/alpha/1.0/model.onnx"] = (200, BIG)
    server.files["/voices/files/alpha/1.0/styles/a.json"] = (200, SMALL)
    server.files["/current/LICENSE"] = (200, LICENCE)
    server.files["/beta/LICENSE"] = (200, LICENCE)
    assert alpha["id"] == "alpha"


class TheShippedSources(unittest.TestCase):
    def test_sources_json_obeys_its_own_rules(self):
        self.assertEqual(vc.validate_sources(vc.load_sources()), [])

    def test_supertonic_comes_out_exactly_as_the_reviewed_draft_lists_it(self):
        sources = vc.load_sources()
        voice = next(v for v in sources["voices"] if v["id"] == "supertonic-3-int8")
        draft = json.loads(tools.DRAFT.read_text(encoding="utf-8"))
        self.assertEqual(vc.voice_entry(sources, voice), draft["voices"][0])

    def test_the_built_catalog_passes_the_schema(self):
        sources = vc.load_sources()
        payload = {"schemaVersion": "voice-model-catalog.v1", "catalogVersion": 1, "issuedAt": "2026-10-18T00:00:00Z",
                   "voices": [vc.voice_entry(sources, v) for v in sources["voices"]]}
        errors = vc.schema_errors(payload)
        if errors is None:
            self.skipTest("jsonschema is not installed")
        self.assertEqual(errors, [])

    def test_kitten_is_bundled_without_files_and_the_others_download(self):
        by_id = {v["id"]: v for v in vc.load_sources()["voices"]}
        self.assertTrue(by_id["kitten-nano-0-8"]["bundled"])
        self.assertEqual(by_id["kitten-nano-0-8"]["files"], [])
        self.assertFalse(by_id["supertonic-3-int8"]["bundled"])
        self.assertFalse(by_id["pocket-tts-alba"]["bundled"])

    def test_mirrored_files_are_only_those_the_licence_allows(self):
        by_id = {v["id"]: v for v in vc.load_sources()["voices"]}
        self.assertTrue(all(f["mirrored"] for f in by_id["supertonic-3-int8"]["files"]))
        self.assertFalse(any(f["mirrored"] for f in by_id["pocket-tts-alba"]["files"]))

    def test_the_sherpa_only_files_have_no_upstream_but_our_mirror(self):
        sources = vc.load_sources()
        voice = next(v for v in sources["voices"] if v["id"] == "supertonic-3-int8")
        entry = next(f for f in voice["files"] if f["path"] == "onnx/duration_predictor.onnx")
        self.assertNotIn("upstream", entry)
        self.assertEqual(vc.file_source_urls(sources, voice, entry),
                         ["https://spokenmargins.proximitytoprogress.com/voices/files/supertonic-3-int8/2026-05-11/onnx/duration_predictor.onnx"])


class ValidatingSources(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = Path(self.dir.name)
        self.good = make_sources("https://example.test/", self.base)

    def errors(self, mutate) -> list[str]:
        sources = copy.deepcopy(self.good)
        mutate(sources)
        return vc.validate_sources(sources, self.base)

    def test_the_good_sources_have_no_errors(self):
        self.assertEqual(vc.validate_sources(self.good, self.base), [])

    def test_neighbouring_mistakes_are_each_caught(self):
        alpha = lambda s: s["voices"][0]  # noqa: E731
        cases = {
            "uppercase hex": lambda s: alpha(s)["files"][0].update(sha256=sha(BIG).upper()),
            "63 hex characters": lambda s: alpha(s)["files"][0].update(sha256=sha(BIG)[:-1]),
            "http upstream": lambda s: alpha(s)["files"][0].update(upstream="http://example.test/model.onnx"),
            "no upstream and not mirrored": lambda s: alpha(s)["files"][1].update(mirrored=False),
            "mirrored without mirrorDir": lambda s: alpha(s).pop("mirrorDir"),
            "mirrorDir without trailing slash": lambda s: alpha(s).update(mirrorDir="alpha/1.0"),
            "zero byteCount": lambda s: alpha(s)["files"][0].update(byteCount=0),
            "byteCount as text": lambda s: alpha(s)["files"][0].update(byteCount="12"),
            "licenseId not in the voice": lambda s: alpha(s)["files"][0].update(licenseId="other"),
            "duplicate path": lambda s: alpha(s)["files"].append(dict(alpha(s)["files"][0])),
            "bundled with files": lambda s: s["voices"][1].update(files=copy.deepcopy(alpha(s)["files"])),
            "downloadable without files": lambda s: alpha(s).update(files=[]),
            "duplicate voice id": lambda s: s["voices"][1].update(id="alpha"),
            "unknown status": lambda s: alpha(s).update(status="retired"),
            "superseded without a successor": lambda s: alpha(s).update(status="superseded"),
            "acceptance without a summary": lambda s: alpha(s)["licenses"][0].update(restrictionsSummary="  "),
            "reviewed text changed": lambda s: (self.base / "licenses" / "example.txt").write_bytes(LICENCE + b"x"),
            "reviewed text missing": lambda s: alpha(s)["licenses"][0].update(reviewedText="licenses/gone.txt"),
            "no reviewed text": lambda s: alpha(s)["licenses"][0].pop("reviewedText"),
            "http licence url": lambda s: alpha(s)["licenses"][0].update(textURL="http://example.test/L"),
            "http watch url": lambda s: alpha(s)["licenses"][0].update(watchURL="ftp://example.test/L"),
            "wrong schema version": lambda s: s.update(schemaVersion="voice-catalog-sources.v0"),
            "base url without slash": lambda s: s["site"].update(baseURL="https://example.test"),
        }
        for name, mutate in cases.items():
            with self.subTest(name):
                self.setUp()
                self.assertTrue(self.errors(mutate), f"{name} was not caught")


class CheckingTheSources(unittest.TestCase):
    def setUp(self):
        self.server = Server()
        self.addCleanup(self.server.close)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = Path(self.dir.name)
        self.state = self.base / "state"
        self.sources = make_sources(self.server.base, self.base)
        serve_everything(self.server, self.sources)

    def run_check(self, **kwargs):
        lines: list[str] = []
        report = vc.check(self.sources, self.state, now=NOW, out=lines.append, base_dir=self.base, **kwargs)
        return report, lines

    def test_a_clean_run_holds_nothing_and_prints_one_line_per_voice(self):
        report, lines = self.run_check(mirror="require")
        self.assertEqual(len(lines), 2)
        self.assertFalse(any(v["held"] for v in report["voices"].values()))
        self.assertTrue((self.state / "check.json").is_file())
        self.assertTrue((self.state / "check.txt").is_file())

    def test_a_file_that_is_unchanged_is_not_downloaded_again(self):
        self.run_check(mirror="require")
        first = self.server.gets("/up/model.onnx")
        self.assertEqual(first, 1)
        self.run_check(mirror="require")
        self.assertEqual(self.server.gets("/up/model.onnx"), first)
        self.run_check(mirror="require", full=True)
        self.assertEqual(self.server.gets("/up/model.onnx"), first + 1)

    def test_changed_bytes_at_the_same_size_are_caught_by_the_hash(self):
        self.run_check()
        changed = bytes([BIG[0] ^ 1]) + BIG[1:]
        self.server.files["/up/model.onnx"] = (200, changed)
        report, lines = self.run_check()
        alpha = report["voices"]["alpha"]
        self.assertTrue(alpha["held"])
        self.assertEqual([p["kind"] for p in alpha["problems"]], ["hash-differs"])
        self.assertIn("HELD", lines[0])
        self.assertEqual((self.state / "changed" / "alpha" / "model.onnx").read_bytes(), changed)
        self.assertFalse(report["voices"]["beta"]["held"])

    def test_a_change_that_is_reverted_is_clean_again_without_anyone_editing_sources(self):
        self.run_check()
        self.server.files["/up/model.onnx"] = (200, BIG + b"!")
        self.assertTrue(self.run_check()[0]["voices"]["alpha"]["held"])
        self.server.files["/up/model.onnx"] = (200, BIG)
        self.assertFalse(self.run_check()[0]["voices"]["alpha"]["held"])

    def test_a_different_size_is_caught_even_when_the_server_says_so_in_the_header(self):
        self.server.files["/up/model.onnx"] = (200, BIG[:-5])
        report, _ = self.run_check()
        self.assertEqual(report["voices"]["alpha"]["problems"][0]["kind"], "hash-differs")

    def test_a_removed_file_is_missing(self):
        self.server.files["/up/model.onnx"] = (404, b"")
        report, _ = self.run_check()
        self.assertEqual([p["kind"] for p in report["voices"]["alpha"]["problems"]], ["missing"])
        self.assertTrue(report["voices"]["alpha"]["held"])

    def test_a_licence_text_that_changed_is_held_with_a_diff_of_the_change(self):
        self.server.files["/current/LICENSE"] = (200, LICENCE.replace(b"You may use this.", b"You may use this for free only."))
        report, _ = self.run_check()
        alpha = report["voices"]["alpha"]
        self.assertTrue(alpha["held"])
        self.assertEqual(alpha["problems"][0]["kind"], "licence-changed")
        diff = (self.state / "licences" / "alpha-example.diff").read_text(encoding="utf-8")
        self.assertIn("-You may use this.", diff)
        self.assertIn("+You may use this for free only.", diff)
        self.assertEqual((self.state / "licences" / "alpha-example.new.txt").read_bytes(), self.server.files["/current/LICENSE"][1])

    def test_the_licence_is_watched_at_the_current_text_not_the_pinned_one(self):
        self.run_check()
        self.assertEqual(self.server.gets("/current/LICENSE"), 1)
        self.assertEqual(self.server.gets("/pinned/LICENSE"), 0)

    def test_an_unreachable_licence_holds_the_voice(self):
        self.server.files["/beta/LICENSE"] = (503, b"")
        report, _ = self.run_check()
        self.assertEqual(report["voices"]["beta"]["problems"][0]["kind"], "licence-unreachable")
        self.assertTrue(report["voices"]["beta"]["held"])

    def test_a_missing_mirror_only_holds_the_voice_when_it_is_required(self):
        self.server.files.pop("/voices/files/alpha/1.0/styles/a.json")
        noted, _ = self.run_check(mirror="note")
        self.assertFalse(noted["voices"]["alpha"]["held"])
        self.assertTrue(noted["voices"]["alpha"]["notes"])
        required, _ = self.run_check(mirror="require")
        self.assertTrue(required["voices"]["alpha"]["held"])
        skipped, _ = self.run_check(mirror="skip")
        self.assertFalse(skipped["voices"]["alpha"]["held"])

    def test_a_mirror_serving_the_wrong_bytes_is_caught_when_required(self):
        self.server.files["/voices/files/alpha/1.0/styles/a.json"] = (200, SMALL.replace(b"1", b"2"))
        self.assertFalse(self.run_check(mirror="note")[0]["voices"]["alpha"]["held"])
        self.assertEqual(self.run_check(mirror="require")[0]["voices"]["alpha"]["problems"][0]["kind"], "hash-differs")

    def test_a_server_that_cannot_be_reached_holds_the_voice(self):
        self.server.close()
        report, _ = self.run_check()
        self.assertTrue(all(v["held"] for v in report["voices"].values()))
        self.assertEqual(report["voices"]["alpha"]["problems"][0]["kind"], "unreachable")


class FilingIssues(unittest.TestCase):
    """A server that plays GitHub's two issue calls."""

    def setUp(self):
        self.created: list[dict] = []
        self.existing: list[dict] = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps(outer.existing).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                outer.created.append({"auth": self.headers["Authorization"], **json.loads(self.rfile.read(int(self.headers["Content-Length"])))})
                self.send_response(201)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.api = f"http://127.0.0.1:{self.httpd.server_port}"
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.state = Path(self.dir.name)
        (self.state / "licences").mkdir()
        (self.state / "licences" / "alpha-example.diff").write_text("-old\n+new\n", encoding="utf-8")
        self.report = {"voices": {
            "alpha": {"held": True, "notes": [], "problems": [
                {"kind": "licence-changed", "subject": "licence example", "url": "https://example.test/L", "detail": "now hashes to x", "mirror": False},
                {"kind": "missing", "subject": "model.onnx", "url": "https://example.test/m", "detail": "HTTP 404", "mirror": False}]},
            "beta": {"held": False, "notes": [], "problems": []}}}

    def test_one_issue_per_kind_of_change_with_the_diff_in_it(self):
        filed = vc.file_issues(self.report, self.state, "tok", repo="o/r", api=self.api, out=lambda _: None)
        self.assertEqual(filed, ["Voice licence changed: alpha / example", "Voice source problem: alpha"])
        licence = self.created[0]
        self.assertEqual(licence["auth"], "Bearer tok")
        self.assertIn("+new", licence["body"])
        self.assertIn("Done when", licence["body"])
        self.assertIn("Must not break", licence["body"])
        self.assertEqual(licence["labels"], ["ready"])

    def test_an_issue_that_is_already_open_is_not_filed_twice(self):
        self.existing = [{"title": "Voice licence changed: alpha / example"}]
        filed = vc.file_issues(self.report, self.state, "tok", repo="o/r", api=self.api, out=lambda _: None)
        self.assertEqual(filed, ["Voice source problem: alpha"])

    def test_nothing_held_files_nothing(self):
        self.report["voices"]["alpha"]["held"] = False
        self.assertEqual(vc.file_issues(self.report, self.state, "tok", repo="o/r", api=self.api, out=lambda _: None), [])
        self.assertEqual(self.created, [])


class BuildingTheCatalog(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = Path(self.dir.name)
        self.state, self.site = self.base / "state", self.base / "Site"
        self.sources = make_sources("https://example.test/", self.base)

    def held(self, *ids):
        vc.write_json(self.state / "check.json", {"checkedAt": vc.iso(NOW), "voices": {v["id"]: {"held": v["id"] in ids, "problems": [], "notes": []} for v in self.sources["voices"]}})

    def build(self, now=NOW):
        return vc.build(self.sources, self.state, self.site, now=now, out=lambda _: None)

    def publish_it(self, payload):
        """Pretend `sign` ran: put the payload where the published catalog lives."""
        import base64
        envelope = {"payload": base64.b64encode(tools.pretty(payload)).decode()}
        vc.write_json(self.site / vc.CATALOG_REL, envelope)

    def test_the_first_catalog_is_version_one_with_every_voice(self):
        payload = self.build()
        self.assertEqual(payload["catalogVersion"], 1)
        self.assertEqual([v["id"] for v in payload["voices"]], ["alpha", "beta"])
        self.assertEqual(payload["issuedAt"], "2026-10-18T12:00:00Z")

    def test_an_unchanged_catalog_keeps_its_version_and_date_so_a_refresh_is_not_a_new_release(self):
        first = self.build()
        self.publish_it(first)
        again = self.build(now=NOW + dt.timedelta(days=7))
        self.assertEqual((again["catalogVersion"], again["issuedAt"]), (1, first["issuedAt"]))

    def test_a_changed_voice_raises_the_version(self):
        first = self.build()
        self.publish_it(first)
        self.sources["voices"][0]["version"] = "1.1"
        later = self.build(now=NOW + dt.timedelta(days=1))
        self.assertEqual(later["catalogVersion"], 2)
        self.assertEqual(later["issuedAt"], "2026-10-19T12:00:00Z")

    def test_a_held_voice_keeps_the_entry_that_was_last_published(self):
        first = self.build()
        self.publish_it(first)
        self.sources["voices"][0]["version"] = "9.9"
        self.sources["voices"][0]["files"][0]["sha256"] = "0" * 64
        self.held("alpha")
        payload = self.build()
        alpha = next(v for v in payload["voices"] if v["id"] == "alpha")
        self.assertEqual(alpha["version"], "1.0")
        self.assertEqual(alpha["files"][0]["sha256"], sha(BIG))
        self.assertEqual(payload["catalogVersion"], 1)

    def test_a_held_voice_that_was_never_published_is_left_out(self):
        self.held("beta")
        self.assertEqual([v["id"] for v in self.build()["voices"]], ["alpha"])

    def test_holding_everything_refuses_to_build_an_empty_catalog(self):
        self.held("alpha", "beta")
        with self.assertRaises(vc.CatalogToolError):
            self.build()

    def test_a_catalog_that_breaks_the_schema_is_not_written(self):
        if vc.schema_errors({"schemaVersion": "x"}) is None:
            self.skipTest("jsonschema is not installed")
        self.sources["voices"][0]["files"][0]["upstream"] = "http://example.test/model.onnx"
        with self.assertRaises(vc.CatalogToolError):
            self.build()
        self.assertFalse((self.state / "catalog.payload.json").exists())


@unittest.skipUnless(HAVE_CRYPTO, "needs the cryptography package")
class SigningAndTheKey(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = Path(self.dir.name)
        self.state, self.site = self.base / "state", self.base / "Site"
        self.sources = make_sources("https://example.test/", self.base)
        self.key = tools._key(b"voice-catalog test key")
        self.payload = vc.build(self.sources, self.state, self.site, now=NOW, out=lambda _: None)

    def test_the_signed_catalog_verifies_and_carries_exactly_the_built_bytes(self):
        manifest = vc.sign(self.sources, self.state, self.site, self.key, out=lambda _: None)
        envelope = json.loads((self.site / vc.CATALOG_REL).read_text(encoding="utf-8"))
        self.assertTrue(vc.envelope_signature_ok(envelope, vc.public_b64(self.key)))
        import base64
        self.assertEqual(base64.b64decode(envelope["payload"]), (self.state / "catalog.payload.json").read_bytes())
        self.assertEqual(envelope["keyId"], vc.KEY_ID)
        self.assertEqual(manifest["contentVersion"], 1)
        self.assertEqual(manifest["entryCount"], 2)
        self.assertEqual(manifest["catalogChecksumSHA256"], sha((self.site / vc.CATALOG_REL).read_bytes()))
        self.assertEqual(manifest["catalogByteCount"], (self.site / vc.CATALOG_REL).stat().st_size)
        self.assertEqual(manifest["catalogURL"], "https://example.test/voices/v1/catalog.json")

    def test_signing_twice_gives_the_same_bytes(self):
        vc.sign(self.sources, self.state, self.site, self.key, out=lambda _: None)
        first = (self.site / vc.CATALOG_REL).read_bytes()
        vc.sign(self.sources, self.state, self.site, self.key, out=lambda _: None)
        self.assertEqual((self.site / vc.CATALOG_REL).read_bytes(), first)

    def test_an_edited_payload_or_another_key_fails_verification(self):
        vc.sign(self.sources, self.state, self.site, self.key, out=lambda _: None)
        envelope = json.loads((self.site / vc.CATALOG_REL).read_text(encoding="utf-8"))
        import base64
        edited = dict(envelope, payload=base64.b64encode(base64.b64decode(envelope["payload"]).replace(b"Alpha", b"Alphb")).decode())
        self.assertFalse(vc.envelope_signature_ok(edited, vc.public_b64(self.key)))
        self.assertFalse(vc.envelope_signature_ok(envelope, vc.public_b64(tools._key(b"another key"))))

    def test_signing_without_a_built_catalog_says_so(self):
        (self.state / "catalog.payload.json").unlink()
        with self.assertRaises(vc.CatalogToolError):
            vc.sign(self.sources, self.state, self.site, self.key, out=lambda _: None)

    def test_the_key_line_keygen_prints_is_the_form_the_publish_check_reads(self):
        swift = self.base / "Verifier.swift"
        swift.write_text("public enum VoiceCatalogTrust {\n    public static let production: [VoiceCatalogTrustedKey] = [\n        " + vc.swift_key_line(self.key) + ",\n    ]\n}\n\nfoo\n", encoding="utf-8")
        self.assertEqual(vc.trusted_keys(swift), {vc.KEY_ID: vc.public_b64(self.key)})

    def test_the_shipped_empty_trust_list_reads_as_no_keys(self):
        self.assertEqual(vc.trusted_keys(), {} if "publicKey: Data(base64Encoded" not in vc.TRUST_SWIFT.read_text(encoding="utf-8") else vc.trusted_keys())


@unittest.skipUnless(HAVE_CRYPTO, "needs the cryptography package")
class Keygen(unittest.TestCase):
    def test_the_secret_is_stored_in_the_keychain_and_never_printed(self):
        calls, printed = [], []

        def run(command, **kwargs):
            calls.append(command)
            if command[1] == "find-generic-password":
                return subprocess.CompletedProcess(command, 44, "", "not found")
            return subprocess.CompletedProcess(command, 0, "", "")

        vc.keygen(run=run, out=printed.append)
        secret = calls[1][calls[1].index("-w") + 1]
        self.assertEqual(calls[1][:2], ["security", "add-generic-password"])
        self.assertGreaterEqual(len(secret), 40)
        self.assertFalse(any(secret in line for line in printed))
        self.assertTrue(any("VoiceCatalogTrustedKey(keyId:" in line for line in printed))

    def test_an_existing_key_is_never_replaced(self):
        key = tools._key(b"existing")
        import base64
        from cryptography.hazmat.primitives import serialization

        stored = base64.b64encode(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())).decode()
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stored + "\n", "")

        with self.assertRaises(vc.CatalogToolError):
            vc.keygen(run=run, out=lambda _: None)
        self.assertFalse(any(c[1] == "add-generic-password" for c in calls))

    def test_without_the_mac_tool_it_says_where_to_run_it(self):
        def run(command, **kwargs):
            raise FileNotFoundError("security")

        with self.assertRaises(vc.CatalogToolError):
            vc.keygen(run=run, out=lambda _: None)


class TheSitePage(unittest.TestCase):
    def setUp(self):
        self.sources = make_sources("https://example.test/", Path(tempfile.mkdtemp()))
        self.catalog = {"schemaVersion": "voice-model-catalog.v1", "catalogVersion": 4, "issuedAt": "2026-10-18T12:00:00Z",
                        "voices": [vc.voice_entry(self.sources, v) for v in self.sources["voices"]]}

    def test_it_shows_each_voice_with_size_publisher_source_and_licence(self):
        page = vc.render_page(self.catalog, self.sources)
        for expected in ("Alpha", "Example Co", "Beta", "Other Co", "Catalog version 4", "Example Licence", "Beta Licence",
                         "example.test (our own mirror)", "Do not misuse it.", "You agree to this before the download starts.",
                         "Ships inside the app", "model.onnx", sha(BIG), "Included in the app", "/voices/v1/catalog.json"):
            self.assertIn(expected, page)

    def test_the_size_is_the_sum_of_the_files(self):
        self.catalog["voices"][0]["files"][0]["byteCount"] = 62_000_000
        self.catalog["voices"][0]["files"][1]["byteCount"] = 1_000
        self.assertIn("62 MB", vc.render_page(self.catalog, self.sources))

    def test_text_from_the_catalog_cannot_inject_markup(self):
        self.catalog["voices"][0]["displayName"] = "<script>alert(1)</script>"
        self.catalog["voices"][0]["licenses"][0]["restrictionsSummary"] = '"><img src=x onerror=alert(1)>'
        self.catalog["voices"][0]["licenses"][0]["textURL"] = 'https://example.test/L"onmouseover="x'
        page = vc.render_page(self.catalog, self.sources)
        self.assertNotIn("<script>alert", page)
        self.assertNotIn("<img src=x", page)
        self.assertNotIn('"onmouseover="x', page)

    def test_a_withdrawn_or_superseded_voice_says_so(self):
        self.catalog["voices"][0]["status"] = "withdrawn"
        self.catalog["voices"][1]["status"] = "superseded"
        self.catalog["voices"][1]["supersededBy"] = "alpha"
        page = vc.render_page(self.catalog, self.sources)
        self.assertIn("Withdrawn", page)
        self.assertIn("Superseded", page)

    def test_the_same_catalog_always_renders_the_same_page(self):
        self.assertEqual(vc.render_page(self.catalog, self.sources), vc.render_page(copy.deepcopy(self.catalog), self.sources))


@unittest.skipUnless(HAVE_CRYPTO, "needs the cryptography package")
class Publishing(unittest.TestCase):
    """Everything publish refuses before it touches the server, then the apply path against stand-ins."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = Path(self.dir.name)
        self.state, self.site = self.base / "state", self.base / "Site"
        self.sources = make_sources("https://example.test/", self.base)
        self.key = tools._key(b"publish test key")
        self.swift = self.base / "Verifier.swift"
        self.swift.write_text("public enum VoiceCatalogTrust {\n    public static let production: [VoiceCatalogTrustedKey] = [\n        " + vc.swift_key_line(self.key) + ",\n    ]\n}\n", encoding="utf-8")
        # The mirror's source bytes, where publish expects them (the repo root is moved for this test).
        self.real_root = vc.ROOT
        vc.ROOT = self.base
        self.addCleanup(setattr, vc, "ROOT", self.real_root)
        (self.base / "stage-src" / "styles").mkdir(parents=True)
        (self.base / "stage-src" / "model.onnx").write_bytes(BIG)
        (self.base / "stage-src" / "styles" / "a.json").write_bytes(SMALL)
        report = {"voices": {v["id"]: {"held": False, "problems": [], "notes": []} for v in self.sources["voices"]}}
        vc.write_json(self.state / "check.json", {"checkedAt": vc.iso(NOW), "sourcesSHA256": vc.sha256_hex(json.dumps(self.sources, sort_keys=True).encode()), **report})
        self.rebuild()

    def rebuild(self):
        vc.build(self.sources, self.state, self.site, now=NOW, out=lambda _: None)
        vc.sign(self.sources, self.state, self.site, self.key, out=lambda _: None)
        vc.write_page(self.sources, self.site, out=lambda _: None)

    def publish(self, apply=False, http=None, run=None, now=NOW, live="fetch"):
        lines: list[str] = []
        vc.publish(self.sources, self.state, self.site, apply=apply, http=http or StandInNetwork(None), run=run or (lambda *a, **k: subprocess.CompletedProcess(a, 0)),
                   now=now, live_version=live, swift_path=self.swift, out=lines.append)
        return lines

    def test_a_dry_run_stages_and_reports_but_runs_no_deploy(self):
        ran = []
        lines = self.publish(run=lambda *a, **k: ran.append(a), live=None)
        self.assertEqual(ran, [])
        self.assertTrue(any("dry run" in line for line in lines))
        self.assertTrue((self.state / "mirror" / "alpha/1.0/model.onnx").is_symlink())
        self.assertTrue(any("mirror: 2 files" in line for line in lines))

    def test_apply_runs_the_deploy_script_with_the_mirror_and_then_checks_the_live_site(self):
        ran = []

        def run(command, env=None, **kwargs):
            ran.append((command, env))
            return subprocess.CompletedProcess(command, 0)

        network = StandInNetwork(1)
        lines = self.publish(apply=True, http=network, run=run, live=None)
        self.assertEqual(ran[0][0], [str(vc.DEPLOY_SCRIPT)])
        self.assertEqual(ran[0][1]["SPOKEN_MARGINS_VOICE_MIRROR_DIR"], str(self.state / "mirror"))
        self.assertIn("published and verified", lines[-1])

    def test_a_failed_deploy_is_reported_not_swallowed(self):
        with self.assertRaises(vc.CatalogToolError):
            self.publish(apply=True, run=lambda *a, **k: subprocess.CompletedProcess(a, 1), live=None)

    def test_a_deploy_that_did_not_change_the_live_version_is_reported(self):
        with self.assertRaises(vc.CatalogToolError):
            self.publish(apply=True, http=StandInNetwork(0), live=None)

    def test_a_mirror_file_the_server_does_not_serve_as_reviewed_is_reported(self):
        network = StandInNetwork(1)
        network.mirror_size = 5
        with self.assertRaises(vc.CatalogToolError) as raised:
            self.publish(apply=True, http=network, live=None)
        self.assertIn("model.onnx", str(raised.exception))

    def test_refusals(self):
        later = NOW + dt.timedelta(hours=25)
        cases = {
            "a check more than a day old": lambda: self.publish(now=later, live=None),
            "sources edited since the check": lambda: (self.sources["voices"][0].update(publisher="Someone Else"), self.publish(live=None)),
            "a catalog older than the live one": lambda: self.publish(live=2),
            "a live manifest that cannot be read": lambda: self.publish(http=StandInNetwork(None, manifest_status=500)),
        }
        for name, attempt in cases.items():
            with self.subTest(name):
                self.setUp()
                with self.assertRaises(vc.CatalogToolError, msg=name):
                    attempt()

    def test_a_catalog_signed_by_a_key_the_app_does_not_trust_is_refused(self):
        self.swift.write_text("public enum VoiceCatalogTrust {\n    public static let production: [VoiceCatalogTrustedKey] = [\n        " + vc.swift_key_line(tools._key(b"someone else")) + ",\n    ]\n}\n", encoding="utf-8")
        with self.assertRaises(vc.CatalogToolError):
            self.publish(live=None)

    def test_an_app_that_trusts_no_key_yet_refuses_to_publish(self):
        self.swift.write_text("public enum VoiceCatalogTrust {\n    public static let production: [VoiceCatalogTrustedKey] = []\n}\n", encoding="utf-8")
        with self.assertRaises(vc.CatalogToolError) as raised:
            self.publish(live=None)
        self.assertIn("no signing key", str(raised.exception))

    def test_a_page_that_no_longer_matches_the_catalog_is_refused(self):
        (self.site / vc.PAGE_REL).write_text("old page", encoding="utf-8")
        with self.assertRaises(vc.CatalogToolError):
            self.publish(live=None)

    def test_a_catalog_that_no_longer_matches_sources_is_refused(self):
        self.sources["voices"][1]["version"] = "3"
        vc.write_json(self.state / "check.json", {**json.loads((self.state / "check.json").read_text()), "sourcesSHA256": vc.sha256_hex(json.dumps(self.sources, sort_keys=True).encode())})
        with self.assertRaises(vc.CatalogToolError):
            self.publish(live=None)

    def test_a_mirror_source_that_is_a_git_lfs_pointer_or_altered_is_refused(self):
        (self.base / "stage-src" / "model.onnx").write_bytes(b"version https://git-lfs.github.com/spec/v1\n")
        with self.assertRaises(vc.CatalogToolError) as raised:
            self.publish(live=None)
        self.assertIn("git lfs pull", str(raised.exception))
        (self.base / "stage-src" / "model.onnx").write_bytes(b"x" * len(BIG))
        with self.assertRaises(vc.CatalogToolError):
            self.publish(live=None)


class StandInNetwork:
    """What publish reads from the live site: the manifest's version and the mirror files' sizes."""

    def __init__(self, deployed_version, manifest_status=200):
        self.deployed_version = deployed_version
        self.manifest_status = manifest_status
        self.mirror_size = None

    def get(self, url, limit=0):
        if self.manifest_status != 200:
            return self.manifest_status, b""
        if self.deployed_version is None:
            return 404, b""
        return 200, json.dumps({"contentVersion": self.deployed_version}).encode()

    def head(self, url):
        size = self.mirror_size if self.mirror_size is not None else (len(BIG) if url.endswith("model.onnx") else len(SMALL))
        return {"status": 200, "size": size, "etag": None, "error": None}


if __name__ == "__main__":
    unittest.main()
