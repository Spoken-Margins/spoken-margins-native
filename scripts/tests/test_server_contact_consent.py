"""Every way the app talks to our server has a named consent route (#2842, Apple agreement 3.3.3).

The app reaches Spoken Margins' server through three transports in `BridgePublicTransport.swift`
(`BridgePublicTransport`, `CommunityMapTransport`, `ShareLinkTransport`, `AttestedTransport`), through addresses built with
`ProductServer`, and, later, through App Attest. Each file that uses one is listed below with the way the listener agreed, and the guard checks that
the file still carries it. A file that is not listed fails, so a new server feature cannot ship
without someone saying how the listener consents to it (or why none is needed).

App Attest has two extra rules, because Apple's agreement bars unique device identifiers and the
issue asks for a fresh key per install:
- a file that touches `DCAppAttestService` (or DeviceCheck's `DCDevice`) must also check `ServerSendConsent.hasConsented`, so the
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

# A file that names a transport, or builds an address on our host (`ProductServer`), is a server contact.
TRANSPORTS = re.compile(r"\b(BridgePublicTransport|CommunityMapTransport|ShareLinkTransport|AttestedTransport|ProductServer)\b")
# DeviceCheck's per-device bits survive a reinstall, so they get the same rules as App Attest.
ATTEST = re.compile(r"\b(DCAppAttestService|DCDevice)\b")
KEYCHAIN = re.compile(r"\b(SecItem\w+|kSecClass\w*|Keychain\w*)\b")

# Where the transports are defined. They are plumbing, not a feature.
DEFINITIONS = {KIT + "SessionKit/BridgePublicTransport.swift", KIT + "SessionKit/ProductServer.swift"}

# file -> (how the listener agreed, text that must appear in the code, how many times). A `None` needle means no
# consent is needed, and the reason says why. Plain requests that every listener makes the same way (the server
# config, the tour, the starter list) need none because they carry no library data and no identifier (see the
# header of ServerSendConsent.swift). Caveat for the share-link entry: the "offer Share as link?" check asks the
# server for its config before the alert is shown; that is a plain request too.
CONTACTS = {
    APP + "ShareLinkSender.swift": (
        "a consent alert on the first Share as link; the upload code refuses without the record",
        "guard ServerSendConsent.hasConsented(to: .shareLinks)", 1,
    ),
    KIT + "SessionKit/ShareLinkUpload.swift": (
        "the upload refuses to seal or send without the consent record",
        "guard hasConsent()", 1,
    ),
    KIT + "SessionKit/AppAttestClient.swift": (
        "refuses before the key, the challenge or any request unless the share-link consent record is current (v2 names the install's code); read again after waiting for an earlier send (#4137)",
        "guard hasConsent()", 2,
    ),
    APP + "AppAttestDeviceProvider.swift": (
        "checks the same consent record before each of Apple's App Attest calls",
        "guard ServerSendConsent.hasConsented(to: .shareLinks)", 3,
    ),
    APP + "CommunityMapUploadService.swift": (
        "Settings > Help make listening maps, off until the listener turns it on",
        "guard Self.optedIn", 4,
    ),
    KIT + "SessionKit/CommunityMapUpload.swift": (
        "the same Settings switch, passed in as `optedIn`",
        "optedIn", 1,
    ),
    APP + "CommunityMapFetchService.swift": (
        "Settings > Look up community maps, off until the listener turns it on",
        "guard Self.optedIn", 1,
    ),
    KIT + "SessionKit/CommunityMapFetch.swift": (
        "the same Settings switch, passed in as `optedIn`",
        "optedIn", 1,
    ),
    APP + "BridgeService.swift": (
        "none needed: the server-config request is the same for every listener and sends no library data or identifier",
        None, 0,
    ),
    KIT + "SessionKit/BridgeManifestStore.swift": (
        "none needed: the config and bridge manifest are plain requests, the same for every listener",
        None, 0,
    ),
    KIT + "SessionKit/GuidedOnboardingCoordinator.swift": (
        "none needed: the tour manifest is a plain request, the same for every listener (it runs at launch)",
        None, 0,
    ),
    KIT + "SessionKit/SourceCatalogStore.swift": (
        "none needed: the starter list is a plain request, the same for every listener, made when the drawer opens",
        None, 0,
    ),
    KIT + "SessionKit/ClubSealing.swift": (
        "none needed here: it builds and reads an invite link and seals bytes, and makes no request. The club client takes its transport as a parameter, so the slice that wires one (club screens, #1799) must add its file here with the consent that gates creating or joining a club",
        None, 0,
    ),
    KIT + "SessionKit/ShareLinkOpening.swift": (
        "none needed: the listener tapped a link they were sent; the request names that link only",
        None, 0,
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
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?<!:)//[^\n]*", "", text)


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
    for rel, (_why, needle, least) in CONTACTS.items():
        if needle is not None and rel in files and strip_comments(files[rel]).count(needle) < least:
            problems.append(
                f"{rel} has `{needle}` fewer than {least} time(s) in its code: the listener's consent for this server contact"
            )
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
        self.assertTrue(any("fewer than" in p for p in problems))

    def test_a_consent_check_only_in_a_comment_fails(self):
        path = APP + "ShareLinkSender.swift"
        source = "// guard ServerSendConsent.hasConsented(to: .shareLinks)\n/* guard ServerSendConsent.hasConsented(to: .shareLinks) */\nlet p = ShareLinkTransport.post"
        self.assertTrue(any("fewer than" in p for p in check({path: source})))

    def test_losing_one_of_several_opt_in_guards_fails(self):
        path = APP + "CommunityMapUploadService.swift"
        source = "guard Self.optedIn else { return }\nlet t = CommunityMapTransport.post"
        self.assertTrue(any("fewer than" in p for p in check({path: source})))

    def test_a_new_file_building_an_address_on_our_host_fails(self):
        files = {APP + "NewThing.swift": "let u = ProductServer.url(path: \"/api/v1/new\")"}
        self.assertTrue(any("not in CONTACTS" in p for p in check(files)))

    def test_a_url_with_two_slashes_is_not_cut_as_a_comment(self):
        source = 'let u = "https://x"; guard ServerSendConsent.hasConsented(to: .shareLinks) else { return }; let s = DCAppAttestService.shared'
        self.assertEqual(check({APP + "Attest.swift": source}), [])

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
