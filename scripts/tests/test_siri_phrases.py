"""The Siri phrases for Add Margin stay registrable and match what Help teaches (#4814).

An `AppShortcut` keeps its phrases opaque at run time, so an app test can only count shortcuts. This scan reads the
source instead and guards the things that make Siri answer "there's not an app for that" or send the phrase elsewhere:

- exactly one `AppShortcutsProvider` in the app (iOS registers one per app; a second one drops the registration);
- the provider is compiled into every build (nothing defines `SPOKEN_MARGINS_LEGACY`, which compiles it out);
- every phrase holds the application-name token once, so Siri can route it to this app;
- no phrase is the "Add a Margin to/with/for <app>" shape that Siri gave to Reminders (#3893);
- no phrase is listed twice;
- the phrases Help teaches are registered, and the name Siri hears is the app's display name.

It cannot say whether Siri has indexed the app on a phone. That part is checked on the phone (#4814).
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App"
PROVIDER = APP / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp" / "SpokenMarginsAppShortcuts.swift"
HELP = APP / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp" / "HelpScreen.swift"
TOKEN = r"\(.applicationName)"
# Phrases Siri gave to Reminders or another built-in (#3893): "<verb> a Margin to/with/for/on <app>".
HANDED_ELSEWHERE = re.compile(r"\b(?:a )?margin (to|with|for|on)\b", re.I)


def _phrases() -> list[str]:
    text = PROVIDER.read_text()
    assert text.count("AppShortcut(") == 1, "a second AppShortcut needs its phrases checked too"
    block = re.search(r"phrases:\s*\[(.*?)\]\s*,\s*shortTitle", text, re.S)
    assert block, "no phrases: [...] list in SpokenMarginsAppShortcuts.swift"
    phrases = re.findall(r'"((?:[^"\\]|\\.)*)"', re.sub(r"//[^\n]*", "", block.group(1)))
    assert phrases, "the phrases list has no string literals"
    return phrases


def _swift_sources():
    return [p for p in APP.rglob("*.swift") if not any(part.endswith("Tests") for part in p.parts)]


class SiriPhraseTests(unittest.TestCase):
    def test_there_is_exactly_one_app_shortcuts_provider(self):
        providers = [p for p in _swift_sources()
                     if re.search(r"^\s*(?:public\s+)?struct\s+\w+\s*:\s*AppShortcutsProvider\b", p.read_text(), re.M)]
        self.assertEqual(providers, [PROVIDER], "iOS registers one AppShortcutsProvider per app")

    def test_no_build_compiles_the_provider_out(self):
        defined = []
        for path in [ROOT / "project.yml", *(ROOT / "Config").glob("*.xcconfig")]:
            code = re.sub(r"(?m)(//|#).*$", "", path.read_text())
            if "SPOKEN_MARGINS_LEGACY" in code:
                defined.append(path.name)
        self.assertEqual(defined, [], "a build that defines SPOKEN_MARGINS_LEGACY drops the Siri phrases")

    def test_every_phrase_names_the_app_exactly_once(self):
        for phrase in _phrases():
            self.assertEqual(phrase.count(TOKEN), 1, f"{phrase!r} must hold the application-name token once")

    def test_no_phrase_is_the_shape_siri_gave_to_reminders(self):
        for phrase in _phrases():
            self.assertIsNone(HANDED_ELSEWHERE.search(phrase.replace(TOKEN, "App")), phrase)

    def test_no_phrase_is_listed_twice(self):
        folded = [" ".join(p.lower().split()) for p in _phrases()]
        self.assertEqual(len(folded), len(set(folded)))

    def test_the_phrases_help_teaches_are_registered(self):
        line = next((l for l in HELP.read_text().splitlines() if "Hands-free: say" in l), None)
        self.assertIsNotNone(line, "Help must keep a 'Hands-free: say ...' line that teaches the phrases")
        taught = re.findall(r'\\"(.*?)\\"', line)
        self.assertGreaterEqual(len(taught), 2, "Help lists more than one phrase that works")
        registered = {p.replace(TOKEN, "Spoken Margins").lower() for p in _phrases()}
        for phrase in taught:
            self.assertIn(phrase.lower(), registered, f"Help teaches {phrase!r}, which no AppShortcut phrase says")

    def test_help_says_siri_stays_open_after_the_margin_is_added(self):
        """The owner's phone showed Siri stays open after "Margin added" and nothing playing comes back by itself
        (#3894). Help must say so, and must not promise that Siri leaves or that listening comes back on its own: nobody
        has measured what happens after Siri closes."""
        line = next((l for l in HELP.read_text().splitlines() if "After Siri says the Margin was added" in l), None)
        self.assertIsNotNone(line, "Help must say what to expect after Siri adds a Margin (#3894)")
        self.assertIn("until you dismiss it", line)
        self.assertNotRegex(line, r"(?i)closes (on its own|by itself)|leaves (on its own|by itself)|wait a moment|comes? back|resumes?")

    def test_the_intent_asks_siri_nothing_after_the_text(self):
        """Siri asks only for a missing parameter or a confirmation; a second question would keep it listening (#3894)."""
        code = re.sub(r"//[^\n]*", "", (APP / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
                                       / "AddMarginShortcutIntent.swift").read_text())
        self.assertNotIn("requestConfirmation", code)
        self.assertNotIn("requestDisambiguation", code)
        self.assertEqual(code.count("requestValueDialog"), 1, "only the text is asked for")

    def test_the_name_siri_hears_is_the_display_name_help_uses(self):
        text = (ROOT / "project.yml").read_text()
        self.assertIn("INFOPLIST_KEY_CFBundleDisplayName: Spoken Margins\n", text)
        plist = (APP / "SpokenMarginsApp" / "Info.plist").read_text()
        self.assertRegex(plist, r"<key>CFBundleDisplayName</key>\s*<string>Spoken Margins</string>")


if __name__ == "__main__":
    unittest.main()
