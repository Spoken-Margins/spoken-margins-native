"""Every way the app talks to our server has a named consent route (#2842, Apple agreement 3.3.3).

The app reaches Spoken Margins' server through three transports in `BridgePublicTransport.swift`
(`BridgePublicTransport`, `CommunityMapTransport`, `ShareLinkTransport`) and, later, through App Attest.
Each file that uses one is listed below with the way the listener agreed, and the guard checks that
the file still carries it. A file that is not listed fails, so a new server feature cannot ship
without someone saying how the listener consents to it (or why none is needed).

App Attest has two extra rules, because Apple's agreement bars unique device identifiers and the
issue asks for a fresh key per install:
- a file that touches `DCAppAttestService` must also check `ServerSendConsent.hasConsented`, so the
  key is created only after the listener agreed;
- it must not use the Keychain, because Keychain items survive deleting the app and the same key
  would link two installs. The key id belongs in UserDefaults, which a reinstall empties.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = "App/SpokenMarginsApp/Sources/SpokenMarginsApp/"
KIT = "Packages/SessionKit/Sources/"

TRANSPORTS = re.compile(r"\b(BridgePublicTransport|CommunityMapTransport|ShareLinkTransport)\b")
ATTEST = re.compile(r"\bDCAppAttestService\b")
KEYCHAIN = re.compile(r"\b(SecItem\w+|kSecClass\w*|Keychain\w*)\b")

# Where the transports are defined. They are plumbing, not a feature.
DEFINITIONS = {KIT + "SessionKit/BridgePublicTransport.swift"}

# file -> (how the listener agreed, text that must still be in the file). `None` means no consent is needed,
# and the reason is the first element. The plain requests need none because they carry no library data and
# no identifier (see the header of ServerSendConsent.swift).
CONTACTS = {
    APP + "ShareLinkSender.swift": (
        "a consent alert on the first Share as link; the upload code refuses without the record",
        "ServerSendConsent.hasConsented(to: .shareLinks)",
    ),
    APP + "CommunityMapUploadService.swift": (
        "Settings > Help make listening maps, off until the listener turns it on",
        "guard Self.optedIn",
    ),
    APP + "CommunityMapFetchService.swift": (
        "Settings > Look up community maps, off until the listener turns it on",
        "guard Self.optedIn",
    ),
    APP + "BridgeService.swift": (
        "none needed: the server-config request is the same for every listener and sends no library data or identifier",
        None,
    ),
    KIT + "SessionKit/ShareLinkOpening.swift": (
        "none needed: the listener tapped a link they were sent; the request names that link only",
        None,
    ),
}

# The settings switches that carry the opt-ins above must start off.
OPT_IN_DEFAULTS = {
    "helpsMakeListeningMaps": "CommunityMapUploadService.optInKey",
    "looksUpCommunityMaps": "CommunityMapFetchService.optInKey",
}


def swift_files():
    for base in (ROOT / "App", ROOT / "Packages/SessionKit/Sources"):
        for path in base.rglob("*.swift"):
            rel = path.relative_to(ROOT).as_posix()
            if any(part.endswith("Tests") for part in rel.split("/")):
                continue
            yield rel, path.read_text(encoding="utf-8", errors="replace")


def strip_comments(text):
    return re.sub(r"//[^\n]*", "", text)


def check(files):
    """Return the problems found in `files`, a {relative path: source} mapping."""
    problems = []
    for rel, source in files.items():
        code = strip_comments(source)
        if rel not in DEFINITIONS and TRANSPORTS.search(code) and rel not in CONTACTS:
            problems.append(
                f"{rel} reaches our server but is not in CONTACTS: add it with how the listener agrees "
                "(a consent record, a Settings switch that starts off, or why none is needed)"
            )
        if ATTEST.search(code):
            if "ServerSendConsent.hasConsented" not in code:
                problems.append(f"{rel} uses App Attest without checking ServerSendConsent.hasConsented first")
            if KEYCHAIN.search(code):
                problems.append(
                    f"{rel} uses App Attest and the Keychain: a Keychain item outlives a reinstall and would link two installs"
                )
    for rel, (_why, needle) in CONTACTS.items():
        if needle is not None and rel in files and needle not in files[rel]:
            problems.append(f"{rel} no longer contains `{needle}`, the listener's consent for this server contact")
    return problems


class ServerContactConsentTests(unittest.TestCase):
    def test_repository_has_no_unregistered_server_contact(self):
        self.assertEqual(check(dict(swift_files())), [])

    def test_every_listed_file_exists(self):
        for rel in list(CONTACTS) + list(DEFINITIONS):
            self.assertTrue((ROOT / rel).is_file(), f"{rel} moved or was deleted: update this guard")

    def test_community_map_switches_start_off(self):
        settings = (ROOT / APP / "SettingsScreen.swift").read_text()
        for name, key in OPT_IN_DEFAULTS.items():
            match = re.search(rf"@AppStorage\({re.escape(key)}\)\s+private var {name}\s*=\s*(\w+)", settings)
            self.assertIsNotNone(match, f"SettingsScreen no longer declares {name} from {key}")
            self.assertEqual(match.group(1), "false", f"{name} must start off")

    # The guard has to be able to fail. These feed it the cases it exists for.

    def test_a_new_file_using_a_transport_fails(self):
        files = {APP + "Brand New Feature.swift": "let p = ShareLinkTransport.post"}
        self.assertTrue(any("not in CONTACTS" in p for p in check(files)))

    def test_a_transport_named_only_in_a_comment_passes(self):
        files = {APP + "Note.swift": "// goes through BridgePublicTransport later\nlet x = 1"}
        self.assertEqual(check(files), [])

    def test_a_listed_file_that_lost_its_consent_check_fails(self):
        path = APP + "ShareLinkSender.swift"
        problems = check({path: "let client = ShareLinkClient(post: ShareLinkTransport.post)"})
        self.assertTrue(any("no longer contains" in p for p in problems))

    def test_app_attest_before_consent_fails(self):
        problems = check({APP + "Attest.swift": "let s = DCAppAttestService.shared; s.generateKey { _, _ in }"})
        self.assertTrue(any("without checking" in p for p in problems))

    def test_app_attest_after_consent_passes(self):
        source = "guard ServerSendConsent.hasConsented(to: .shareLinks) else { return }\nlet s = DCAppAttestService.shared"
        self.assertEqual(check({APP + "Attest.swift": source}), [])

    def test_app_attest_key_in_the_keychain_fails(self):
        source = (
            "guard ServerSendConsent.hasConsented(to: .shareLinks) else { return }\n"
            "let s = DCAppAttestService.shared\nSecItemAdd(query as CFDictionary, nil)"
        )
        self.assertTrue(any("Keychain" in p for p in check({APP + "Attest.swift": source})))


if __name__ == "__main__":
    unittest.main()
