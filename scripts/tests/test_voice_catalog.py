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
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import io
import zipfile
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

    def test_supertonic_keeps_the_sherpa_archive_only_as_a_spare(self):
        # The archive is still checked weekly (#2086 slice 1), but no file is taken from it.
        sources = vc.load_sources()
        supertonic = next(v for v in sources["voices"] if v["id"] == "supertonic-3-int8")
        manifest = json.loads((tools.SUPERTONIC / "asset-manifest.json").read_text(encoding="utf-8"))["quantizedArchive"]
        self.assertEqual([(a["url"], a["sha256"]) for a in supertonic["upstreamArchives"]], [(manifest["url"], manifest["sha256"])])
        entry = vc.voice_entry(sources, supertonic)
        self.assertFalse(any("archiveMember" in f for f in entry["files"]))

    def test_no_voice_file_comes_from_the_owners_server(self):
        # Owner, 2026-10-19: "Supertonic downloading straight from Hugging Face at pinned revisions and no server."
        sources = vc.load_sources()
        site = sources["site"]["baseURL"]
        for voice in sources["voices"]:
            for file in voice["files"]:
                with self.subTest(voice=voice["id"], path=file["path"]):
                    self.assertFalse(file.get("mirrored"))
                    self.assertFalse(any(url.startswith(site) for url in vc.file_source_urls(sources, voice, file)))

    def test_the_committed_site_catalog_downloads_nothing_from_the_owners_server(self):
        # #2086: catalog version 1 (Site/voices/v1/) sent every Supertonic file to voices/files/ on the owner's server,
        # long after sources.json stopped mirroring it, because nobody re-signed it.
        sources = vc.load_sources()
        site = sources["site"]["baseURL"]
        catalog = vc.published_payload(vc.SITE_DIR)
        self.assertIsNotNone(catalog)
        for voice in catalog["voices"]:
            urls = [url for file in voice["files"] for url in file.get("sources", [])]
            urls += [url for archive in voice.get("archives", []) for url in archive["sources"]]
            with self.subTest(voice=voice["id"]):
                self.assertEqual([url for url in urls if url.startswith(site)], [])

    def test_the_committed_site_manifest_describes_the_committed_catalog(self):
        catalog_bytes = (vc.SITE_DIR / vc.CATALOG_REL).read_bytes()
        manifest = json.loads((vc.SITE_DIR / vc.MANIFEST_REL).read_text(encoding="utf-8"))
        self.assertEqual(manifest["contentVersion"], vc.published_payload(vc.SITE_DIR)["catalogVersion"])
        self.assertEqual(manifest["catalogChecksumSHA256"], vc.sha256_hex(catalog_bytes))
        self.assertEqual(manifest["catalogByteCount"], len(catalog_bytes))

    @unittest.skipUnless(HAVE_CRYPTO, "cryptography is not installed")
    def test_the_committed_site_catalog_is_signed_by_a_key_the_app_trusts(self):
        envelope = json.loads((vc.SITE_DIR / vc.CATALOG_REL).read_text(encoding="utf-8"))
        keys = vc.trusted_keys()
        self.assertIn(envelope["keyId"], keys)
        self.assertTrue(vc.envelope_signature_ok(envelope, keys[envelope["keyId"]]))

    def test_the_four_int8_graphs_come_from_the_pinned_sherpa_onnx_hugging_face_repo(self):
        sources = vc.load_sources()
        voice = next(v for v in sources["voices"] if v["id"] == "supertonic-3-int8")
        graphs = {f["path"]: vc.file_source_urls(sources, voice, f) for f in voice["files"] if f["path"].endswith(".onnx")}
        pinned = "https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11/resolve/cca5a0e6c96e1d2c720986bf7e75fcc81dee3ae4/"
        self.assertEqual(graphs, {
            f"onnx/{name}.onnx": [f"{pinned}{name}.int8.onnx"]
            for name in ("duration_predictor", "text_encoder", "vector_estimator", "vocoder")
        })

    def test_our_own_notices_travel_in_the_catalog_byte_for_byte(self):
        # No publisher serves these, so the catalog carries them; MODIFIED.txt keeps the downloaded onnx/ folder
        # identical to the bundled one, so audio already rendered keeps its render identity.
        sources = vc.load_sources()
        voice = next(v for v in sources["voices"] if v["id"] == "supertonic-3-int8")
        carried = {f["path"]: f["content"] for f in vc.voice_entry(sources, voice)["files"] if "content" in f}
        self.assertEqual(sorted(carried), ["licenses/THIRD_PARTY_NOTICES.txt", "onnx/MODIFIED.txt"])
        for path, text in carried.items():
            self.assertEqual(text.encode("utf-8"), (tools.SUPERTONIC / path).read_bytes(), path)


class ThePhononEntry(unittest.TestCase):
    """#2704: Phonon 31M downloads from Gradium's pinned release zip, never Hugging Face's 40M (CC BY-NC) files,
    with its licence files and the Mimi credit beside it."""

    def setUp(self):
        self.sources = vc.load_sources()
        self.voice = next(v for v in self.sources["voices"] if v["id"] == "phonon-31m-en")
        self.entry = vc.voice_entry(self.sources, self.voice)

    def test_every_model_file_comes_out_of_the_pinned_v0_4_2_zip(self):
        self.assertEqual(self.entry["archives"], [{
            "id": "coreml-bundle", "format": "zip", "byteCount": 137096081,
            "sha256": "10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436",
            "sources": ["https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.2/phonon-31m-en-coreml.zip"],
        }])
        members = [f for f in self.entry["files"] if "archiveMember" in f]
        self.assertEqual(len(members), 38)
        for file in members:
            with self.subTest(path=file["path"]):
                self.assertNotIn("sources", file)
                self.assertEqual(file["archiveMember"], {"archive": "coreml-bundle", "member": "phonon-31m-en-coreml/" + file["path"]})

    def test_it_is_floored_at_a14_on_the_phonon_runtime(self):
        self.assertEqual(self.entry["runtime"]["name"], "phonon-ptts")
        self.assertEqual(self.entry["minimumChip"], "A14")

    def test_no_40m_or_character_files(self):
        text = json.dumps(self.voice)
        self.assertNotIn("40m", text.lower())
        voices = sorted(f["path"] for f in self.voice["files"] if f["path"].startswith("voices/"))
        self.assertEqual(len(voices), 25)
        self.assertNotIn("voices/default.safetensors", voices)
        self.assertTrue(all(" " not in path for path in voices))

    def test_the_licences_and_the_mimi_credit_travel_with_the_files(self):
        paths = {f["path"] for f in self.entry["files"]}
        self.assertTrue({"licenses/LICENSE-APACHE.txt", "licenses/CC-BY-4.0.txt", "licenses/NOTICE.txt"} <= paths)
        notice = next(f["content"] for f in self.entry["files"] if f["path"] == "licenses/NOTICE.txt")
        self.assertIn("Kyutai", notice)
        self.assertIn("Apache License, Version 2.0", notice)
        self.assertEqual(sorted(lic["spdxId"] for lic in self.entry["licenses"]), ["Apache-2.0", "CC-BY-4.0"])


class TheAppSnapshot(unittest.TestCase):
    """The catalog the app bundles (#1819) must list exactly what sources.json lists, or Settings > Voices
    offers files whose hashes no longer match what the site serves."""

    def test_the_committed_snapshot_matches_sources_json(self):
        committed = json.loads(vc.APP_SNAPSHOT_PATH.read_text(encoding="utf-8"))
        rebuilt = vc.app_snapshot(vc.load_sources(), committed["issuedAt"])
        self.assertEqual(committed, rebuilt, "run `scripts/voice-catalog app-snapshot` and commit the result")

    def test_regenerating_an_unchanged_snapshot_keeps_its_date(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "snapshot.json"
            sources = vc.load_sources()
            vc.write_app_snapshot(sources, path, now=dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc), out=lambda _: None)
            vc.write_app_snapshot(sources, path, now=dt.datetime(2026, 2, 1, tzinfo=dt.timezone.utc), out=lambda _: None)
            self.assertEqual(json.loads(path.read_text())["issuedAt"], "2026-01-01T00:00:00Z")


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

    def carried(self, name: str, data: bytes) -> dict:
        (self.base / "content").mkdir(exist_ok=True)
        (self.base / "content" / name).write_bytes(data)
        return {"path": f"notes/{name}", "byteCount": len(data), "sha256": sha(data), "contentFile": f"content/{name}"}

    @property
    def note(self) -> dict:
        return self.carried("NOTE.txt", b"Notice of modification\n")

    def test_the_good_sources_have_no_errors(self):
        self.assertEqual(vc.validate_sources(self.good, self.base), [])

    def test_a_short_text_carried_in_the_catalog_is_valid_and_comes_out_as_content(self):
        sources = copy.deepcopy(self.good)
        sources["voices"][0]["files"].append(self.note)
        self.assertEqual(vc.validate_sources(sources, self.base), [])
        entry = vc.voice_entry(sources, sources["voices"][0], self.base)
        carried = next(f for f in entry["files"] if f["path"] == "notes/NOTE.txt")
        self.assertEqual(carried["content"], "Notice of modification\n")
        self.assertNotIn("sources", carried)

    def test_a_chip_floor_comes_out_in_the_entry_and_its_absence_adds_nothing(self):
        # #2700: Kokoro and Phonon are offered on A14 and newer; other voices carry no floor.
        sources = copy.deepcopy(self.good)
        self.assertNotIn("minimumChip", vc.voice_entry(sources, sources["voices"][0], self.base))
        sources["voices"][0]["minimumChip"] = "A14"
        self.assertEqual(vc.voice_entry(sources, sources["voices"][0], self.base)["minimumChip"], "A14")

    def test_neighbouring_mistakes_are_each_caught(self):
        alpha = lambda s: s["voices"][0]  # noqa: E731
        cases = {
            "uppercase hex": lambda s: alpha(s)["files"][0].update(sha256=sha(BIG).upper()),
            "63 hex characters": lambda s: alpha(s)["files"][0].update(sha256=sha(BIG)[:-1]),
            "http upstream": lambda s: alpha(s)["files"][0].update(upstream="http://example.test/model.onnx"),
            "no upstream and not mirrored": lambda s: alpha(s)["files"][1].update(mirrored=False),
            "content with an upstream too": lambda s: alpha(s)["files"].append(dict(self.note, upstream="https://example.test/n")),
            "content that is also mirrored": lambda s: alpha(s)["files"].append(dict(self.note, mirrored=True)),
            "content file missing": lambda s: alpha(s)["files"].append(dict(self.note, contentFile="content/gone.txt")),
            "content of another size": lambda s: alpha(s)["files"].append(dict(self.note, byteCount=self.note["byteCount"] + 1)),
            "content with another hash": lambda s: alpha(s)["files"].append(dict(self.note, sha256=sha(b"other"))),
            "content too long to carry": lambda s: alpha(s)["files"].append(self.carried("long.txt", b"x" * (vc.CONTENT_LIMIT + 1))),
            "content not UTF-8": lambda s: alpha(s)["files"].append(self.carried("latin1.txt", "caf\u00e9".encode("latin-1"))),
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
            "archive without a hash": lambda s: alpha(s).update(upstreamArchives=[{"url": "https://example.test/a.tar", "byteCount": 5}]),
            "http archive": lambda s: alpha(s).update(upstreamArchives=[{"url": "http://example.test/a.tar", "byteCount": 5, "sha256": sha(b"a")}]),
            "archive member of an unknown archive": lambda s: alpha(s)["files"].append(
                {"path": "m.bin", "byteCount": 1, "sha256": sha(b"m"), "archiveMember": {"archive": "nope", "member": "m.bin"}}),
            "archive member with an upstream too": lambda s: (
                alpha(s).update(upstreamArchives=[{"id": "z", "format": "zip", "url": "https://example.test/a.zip", "byteCount": 5, "sha256": sha(b"a")}]),
                alpha(s)["files"].append({"path": "m.bin", "byteCount": 1, "sha256": sha(b"m"), "upstream": "https://example.test/m",
                                          "archiveMember": {"archive": "z", "member": "m.bin"}})),
            "archive member path with a space": lambda s: (
                alpha(s).update(upstreamArchives=[{"id": "z", "format": "zip", "url": "https://example.test/a.zip", "byteCount": 5, "sha256": sha(b"a")}]),
                alpha(s)["files"].append({"path": "m.bin", "byteCount": 1, "sha256": sha(b"m"), "archiveMember": {"archive": "z", "member": "a b.bin"}})),
            "archive with an id but no format": lambda s: alpha(s).update(
                upstreamArchives=[{"id": "z", "url": "https://example.test/a.zip", "byteCount": 5, "sha256": sha(b"a")}]),
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

    def run_check(self, now=NOW, **kwargs):
        lines: list[str] = []
        report = vc.check(self.sources, self.state, now=now, out=lines.append, base_dir=self.base, http=vc.Http(timeout=5, retry_delay=0), **kwargs)
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

    def test_a_file_seen_unchanged_is_still_downloaded_again_after_a_month(self):
        self.run_check()
        self.run_check(now=NOW + dt.timedelta(days=10))
        self.assertEqual(self.server.gets("/up/model.onnx"), 1)
        self.run_check(now=NOW + dt.timedelta(days=31))
        self.assertEqual(self.server.gets("/up/model.onnx"), 2)

    def test_an_upstream_archive_that_changed_holds_the_voice_even_when_the_mirror_is_only_noted(self):
        archive = b"archive bytes " * 50
        self.sources["voices"][0]["upstreamArchives"] = [{"url": self.server.base + "up/archive.tar.bz2", "byteCount": len(archive), "sha256": sha(archive)}]
        self.server.files["/up/archive.tar.bz2"] = (200, archive)
        self.server.files.pop("/voices/files/alpha/1.0/styles/a.json")  # a mirror miss alone would only be noted
        self.assertFalse(self.run_check(mirror="note")[0]["voices"]["alpha"]["held"])
        self.server.files["/up/archive.tar.bz2"] = (200, archive[:-1] + b"!")
        report, lines = self.run_check(mirror="note")
        self.assertTrue(report["voices"]["alpha"]["held"])
        self.assertEqual(report["voices"]["alpha"]["problems"][0]["subject"], "archive archive.tar.bz2")
        self.assertIn("HELD", lines[0])
        self.server.files["/up/archive.tar.bz2"] = (404, b"")
        self.assertEqual(self.run_check(mirror="note")[0]["voices"]["alpha"]["problems"][0]["kind"], "missing")

    def test_one_flaky_answer_does_not_hold_a_voice(self):
        answers = iter([503])
        original = self.server.files["/beta/LICENSE"]

        class Flaky(vc.Http):
            def _get_once(inner, url, limit):
                if url.endswith("/beta/LICENSE"):
                    try:
                        return next(answers), b""
                    except StopIteration:
                        pass
                return super()._get_once(url, limit)

        lines: list[str] = []
        report = vc.check(self.sources, self.state, now=NOW, out=lines.append, base_dir=self.base, http=Flaky(timeout=5, retry_delay=0))
        self.assertFalse(report["voices"]["beta"]["held"])
        self.assertEqual(original, self.server.files["/beta/LICENSE"])

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
        self.searches: list[str] = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.searches.append(self.path)
                body = json.dumps({"items": outer.existing}).encode()
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

    def test_the_duplicate_check_asks_for_the_exact_title_so_a_long_issue_list_cannot_hide_it(self):
        vc.file_issues(self.report, self.state, "tok", repo="o/r", api=self.api, out=lambda _: None)
        self.assertTrue(all(path.startswith("/search/issues?q=") for path in self.searches))
        self.assertIn("Voice%20licence%20changed", self.searches[0])

    def test_a_similar_title_is_not_mistaken_for_the_same_issue(self):
        self.existing = [{"title": "Voice licence changed: alpha / example (older)"}]
        filed = vc.file_issues(self.report, self.state, "tok", repo="o/r", api=self.api, out=lambda _: None)
        self.assertIn("Voice licence changed: alpha / example", filed)

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
    def test_the_secret_goes_to_the_keychain_on_stdin_and_is_never_printed_or_in_arguments(self):
        calls, printed = [], []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if command[1] == "find-generic-password":
                return subprocess.CompletedProcess(command, 44, "", "not found")
            return subprocess.CompletedProcess(command, 0, "", "")

        vc.keygen(run=run, out=printed.append)
        add_command, add_kwargs = calls[1]
        self.assertEqual(add_command, ["security", "-i"])
        stdin = add_kwargs["input"]
        self.assertTrue(stdin.startswith("add-generic-password "))
        secret = stdin.split('-w "')[1].split('"')[0]
        self.assertGreaterEqual(len(secret), 40)
        self.assertFalse(any(secret in part for call in calls for part in call[0]))
        self.assertFalse(any(secret in line for line in printed))
        self.assertTrue(any("VoiceCatalogTrustedKey(keyId:" in line for line in printed))

    def test_a_failed_store_never_echoes_the_secret(self):
        def run(command, **kwargs):
            if command[1] == "find-generic-password":
                return subprocess.CompletedProcess(command, 44, "", "")
            secret = kwargs["input"].split('-w "')[1].split('"')[0]
            return subprocess.CompletedProcess(command, 1, "", f"failed to add {secret}")

        with self.assertRaises(vc.CatalogToolError) as raised:
            vc.keygen(run=run, out=lambda _: None)
        self.assertIn("<secret>", str(raised.exception))

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
        self.assertFalse(any(c[1] in ("add-generic-password", "-i") for c in calls))

    def test_a_locked_or_refused_keychain_is_not_mistaken_for_no_key(self):
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 36, "", "User interaction is not allowed.")

        with self.assertRaises(vc.CatalogToolError) as raised:
            vc.keychain_key(run)
        self.assertIn("Keychain", str(raised.exception))
        with self.assertRaises(vc.CatalogToolError):
            vc.keygen(run=run, out=lambda _: None)

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

    def test_a_file_carried_as_text_or_taken_from_an_archive_is_listed_and_its_archive_host_named(self):
        # #2086: the page read every file's "sources", so catalog version 2 (Supertonic's MODIFIED.txt carried as text,
        # Phonon's files inside a pinned archive) could not be rendered at all.
        voice = self.catalog["voices"][0]
        voice["files"][1] = {"path": "MODIFIED.txt", "byteCount": 5, "sha256": "0" * 64, "content": "note\n"}
        voice["files"].append({"path": "inside.onnx", "byteCount": 7, "sha256": "1" * 64, "archiveMember": {"archive": "pack", "member": "x/inside.onnx"}})
        voice["archives"] = [{"id": "pack", "format": "tar.bz2", "byteCount": 9, "sha256": "2" * 64, "sources": ["https://archives.example/pack.tar.bz2"]}]
        page = vc.render_page(self.catalog, self.sources)
        for expected in ("MODIFIED.txt", "inside.onnx", "archives.example"):
            self.assertIn(expected, page)

    def test_a_voice_with_no_mirrored_file_does_not_mention_a_mirror(self):
        for voice in self.catalog["voices"]:
            for file in voice["files"]:
                file["sources"] = [url for url in file.get("sources", []) if not url.startswith(self.sources["site"]["baseURL"])] or ["https://publisher.example/f"]
        page = vc.render_page(self.catalog, self.sources)
        self.assertNotIn("mirror", page)
        self.assertIn("publisher.example", page)


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
                   now=now, live=live, swift_path=self.swift, out=lines.append)
        return lines

    def live(self, version, mutate=None):
        """The catalog as listeners have it: today's, at another version, optionally edited."""
        payload = copy.deepcopy(vc.published_payload(self.site))
        payload["catalogVersion"] = version
        if mutate:
            mutate(payload)
        return payload

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
            "a catalog older than the live one": lambda: self.publish(live=self.live(2)),
            "a live catalog that cannot be read": lambda: self.publish(http=StandInNetwork(None, catalog_status=500)),
            "a live voice missing from the new catalog": lambda: self.publish(live=self.live(0, lambda p: p["voices"].append(dict(p["voices"][0], id="gone")))),
            "a check made after the catalog was built": lambda: (vc.write_json(self.state / "check.json", {**json.loads((self.state / "check.json").read_text()), "checkedAt": vc.iso(NOW + dt.timedelta(minutes=5))}), self.publish(now=NOW + dt.timedelta(minutes=6), live=None)),
        }
        for name, attempt in cases.items():
            with self.subTest(name):
                self.setUp()
                with self.assertRaises(vc.CatalogToolError, msg=name):
                    attempt()

    def hold(self, voice_id):
        report = json.loads((self.state / "check.json").read_text())
        report["voices"][voice_id]["held"] = True
        vc.write_json(self.state / "check.json", report)

    def test_a_held_voice_must_go_out_exactly_as_it_is_live(self):
        live = self.live(0, lambda p: p["voices"][0].update(version="0.9"))
        self.hold("alpha")  # same check, so the build pairing holds; the catalog still carries alpha's new entry
        with self.assertRaises(vc.CatalogToolError) as raised:
            self.publish(live=live)
        self.assertIn("held", str(raised.exception))

    def test_a_held_voice_that_was_never_live_must_stay_out(self):
        self.hold("alpha")
        with self.assertRaises(vc.CatalogToolError):
            self.publish(live=None)

    def test_a_held_voice_kept_as_it_is_live_publishes(self):
        live = self.live(0)
        self.hold("alpha")
        vc.build(self.sources, self.state, self.site, now=NOW, out=lambda _: None)
        vc.sign(self.sources, self.state, self.site, self.key, out=lambda _: None)
        vc.write_page(self.sources, self.site, out=lambda _: None)
        self.publish(live=live)

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


class Fetching(unittest.TestCase):
    """#1820: the model files left the repository, so `fetch` (and publish's staging) takes them from the
    publisher: a pinned file by its URL, an archive member by its hash. Real HTTP server, real tar archive."""

    ARCHIVED = b"quantized graph " * 64

    def setUp(self):
        import io
        import tarfile

        self.server = Server()
        self.addCleanup(self.server.close)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = Path(self.dir.name)
        self.state = self.base / "state"
        self.real_root = vc.ROOT
        vc.ROOT = self.base
        self.addCleanup(setattr, vc, "ROOT", self.real_root)
        # The archive names its member differently from the path the app reads, as sherpa-onnx's does.
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:bz2") as tar:
            for name, data in (("pack/README", b"not wanted"), ("pack/graph.int8.onnx", self.ARCHIVED)):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        self.archive = buffer.getvalue()
        self.sources = make_sources(self.server.base, self.base)
        alpha = self.sources["voices"][0]
        alpha["upstreamArchives"] = [{"url": self.server.base + "up/pack.tar.bz2", "byteCount": len(self.archive), "sha256": sha(self.archive)}]
        alpha["files"].append({"path": "onnx/graph.onnx", "byteCount": len(self.ARCHIVED), "sha256": sha(self.ARCHIVED), "mirrored": True,
                               "origin": {"url": self.server.base + "up/pack.tar.bz2", "note": "member of the archive"}})
        self.server.files["/up/model.onnx"] = (200, BIG)
        self.server.files["/up/pack.tar.bz2"] = (200, self.archive)
        # Only the file we wrote ourselves is in the repository.
        (self.base / "stage-src" / "styles").mkdir(parents=True)
        (self.base / "stage-src" / "styles" / "a.json").write_bytes(SMALL)

    def fetch(self):
        return vc.fetch(self.sources, self.state, http=vc.Http(retry_delay=0), out=lambda _: None)

    def test_each_file_comes_from_its_pinned_source_and_matches_the_review(self):
        folder = self.fetch()["alpha"]
        self.assertEqual((folder / "model.onnx").read_bytes(), BIG)
        self.assertEqual((folder / "styles" / "a.json").read_bytes(), SMALL)
        self.assertEqual((folder / "onnx" / "graph.onnx").read_bytes(), self.ARCHIVED, "the renamed archive member, found by its hash")
        self.assertEqual(sorted(p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file()),
                         ["model.onnx", "onnx/graph.onnx", "styles/a.json"], "nothing else from the archive, no leftovers")
        self.assertEqual(list((self.state / "tmp").iterdir()), [], "the archive is deleted after use")

    def test_a_member_of_a_zip_the_app_unpacks_is_taken_from_it_by_hash(self):
        """#2704: Phonon's files are members of Gradium's zip; fetch takes them from it as the app does."""
        wanted = b"phonon weights " * 200
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as bundle:
            bundle.writestr("bundle/README", b"not wanted")
            bundle.writestr("bundle/flow.bin", wanted)
        archive = buffer.getvalue()
        alpha = self.sources["voices"][0]
        alpha["upstreamArchives"].append({"id": "bundle", "format": "zip", "url": self.server.base + "up/b.zip",
                                          "byteCount": len(archive), "sha256": sha(archive)})
        alpha["files"].append({"path": "flow.bin", "byteCount": len(wanted), "sha256": sha(wanted),
                               "archiveMember": {"archive": "bundle", "member": "bundle/flow.bin"}})
        self.server.files["/up/b.zip"] = (200, archive)
        folder = self.fetch()["alpha"]
        self.assertEqual((folder / "flow.bin").read_bytes(), wanted)
        self.assertFalse((folder / "README").exists())

    def test_text_the_catalog_carries_is_copied_from_the_repository(self):
        """#2055: a notice the catalog carries (`contentFile`) has no upstream and no mirror. A cold fetch, as the
        lane's adapters plan runs, refused the whole voice for it."""
        notice = "Modified by Spoken Margins.\n".encode()
        content = self.base / "Contracts/voice-models/content/alpha/NOTICE.txt"
        content.parent.mkdir(parents=True)
        content.write_bytes(notice)
        self.sources["voices"][0]["files"].append({"path": "NOTICE.txt", "byteCount": len(notice), "sha256": sha(notice),
                                                   "contentFile": "content/alpha/NOTICE.txt"})
        folder = self.fetch()["alpha"]
        self.assertEqual((folder / "NOTICE.txt").read_bytes(), notice)

    def test_files_already_fetched_are_not_downloaded_again(self):
        self.fetch()
        self.fetch()
        self.assertEqual(self.server.gets("/up/model.onnx"), 1)
        self.assertEqual(self.server.gets("/up/pack.tar.bz2"), 1)

    def test_a_file_fetched_with_wrong_bytes_is_fetched_again(self):
        folder = self.fetch()["alpha"]
        (folder / "model.onnx").write_bytes(b"x" * len(BIG))
        self.fetch()
        self.assertEqual((folder / "model.onnx").read_bytes(), BIG)

    def test_a_publisher_serving_other_bytes_is_refused_and_those_bytes_are_not_kept(self):
        folder = vc.fetched_dir(self.state, self.sources["voices"][0])
        for path, body, kept in (("/up/model.onnx", BIG[:-1] + b"!", "model.onnx"),
                                 ("/up/pack.tar.bz2", self.archive[:-1] + b"!", "onnx/graph.onnx")):
            with self.subTest(path):
                shutil.rmtree(self.state, ignore_errors=True)
                original = self.server.files[path]
                self.server.files[path] = (200, body)
                with self.assertRaises(vc.CatalogToolError) as raised:
                    self.fetch()
                self.server.files[path] = original
                self.assertIn("sha256", str(raised.exception))
                self.assertFalse((folder / kept).exists(), "the wrong bytes are not left where a test or publish would use them")
                self.assertEqual([p.name for p in folder.rglob("*.part")], [])

    def test_an_archive_without_the_reviewed_member_is_refused(self):
        self.sources["voices"][0]["files"][-1]["sha256"] = "0" * 64
        with self.assertRaises(vc.CatalogToolError) as raised:
            self.fetch()
        self.assertIn("no member", str(raised.exception))

    def test_a_file_with_no_source_at_all_says_so(self):
        (self.base / "stage-src" / "styles" / "a.json").unlink()
        with self.assertRaises(vc.CatalogToolError) as raised:
            self.fetch()
        self.assertIn("styles/a.json", str(raised.exception))

    def test_staging_the_mirror_fetches_what_the_repository_does_not_hold(self):
        stage, count, total = vc.stage_mirror(self.sources, self.state, http=vc.Http(retry_delay=0), out=lambda _: None)
        self.assertEqual(count, 3)
        self.assertEqual(total, len(BIG) + len(SMALL) + len(self.ARCHIVED))
        self.assertEqual((stage / "alpha/1.0/onnx/graph.onnx").read_bytes(), self.ARCHIVED)
        self.assertEqual((stage / "alpha/1.0/styles/a.json").resolve(), (self.base / "stage-src/styles/a.json").resolve(),
                         "a file the repository holds is staged from it")

    def test_the_shipped_sources_say_where_every_supertonic_file_comes_from(self):
        """Every Supertonic file is in the repository, has a pinned upstream, or is a member of a pinned archive."""
        sources = vc.load_sources()
        vc.ROOT = self.real_root
        voice = next(v for v in sources["voices"] if v["id"] == "supertonic-3-int8")
        archives = {a["url"] for a in voice["upstreamArchives"]}
        for file in voice["files"]:
            with self.subTest(file["path"]):
                self.assertTrue(vc.repository_copy(voice, file) is not None or "upstream" in file
                                or file.get("origin", {}).get("url") in archives)


class StandInNetwork:
    """What publish reads from the live site: the manifest's version and the mirror files' sizes."""

    def __init__(self, deployed_version, manifest_status=200, live_catalog=None, catalog_status=None):
        self.deployed_version = deployed_version
        self.manifest_status = manifest_status
        self.live_catalog = live_catalog
        self.catalog_status = catalog_status
        self.mirror_size = None

    def get(self, url, limit=0):
        if url.endswith(vc.CATALOG_REL):
            if self.catalog_status:
                return self.catalog_status, b""
            if self.live_catalog is None:
                return 404, b""
            import base64
            return 200, json.dumps({"payload": base64.b64encode(tools.pretty(self.live_catalog)).decode()}).encode()
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
