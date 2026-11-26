"""The sender's recipient preview never draws a packet code (#5336).

On main 6288d39 each Margin card in the preview read `text_only`: `Build23VerifiedRecipientPreviewPanel` drew
`Text(margin.representation)`, a String filled from `kind.rawValue`, and the disclosure line printed a Listening Map
scene's `summaryProvenance.rawValue` with its underscores swapped for spaces. The words now come from SessionKit's
`SharePreviewWords`, whose host tests cover every value. This scan keeps the preview reading from it.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"


def _code(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class SharePreviewNoPacketCodes(unittest.TestCase):
    def test_the_preview_margin_holds_the_kind_not_its_code(self):
        seams = _code("Build23SharingSeams.swift")
        start = seams.index("struct Build23RecipientPreviewMargin")
        model = seams[start:seams.index("}", start)]
        self.assertRegex(model, r"let representation: SharedInterjectionRepresentationKind\?")
        self.assertNotIn("kind.rawValue", seams)

    def test_the_preview_card_draws_plain_words(self):
        panel = _code("Build23SenderSharingComponents.swift")
        panel = panel[panel.index("struct Build23VerifiedRecipientPreviewPanel"):]
        self.assertNotRegex(panel, r"Text\(margin\.representation\)")
        self.assertIn("SharePreviewWords.version(margin.representation)", panel)

    def test_the_disclosures_print_no_raw_provenance(self):
        rights = _code("SharingRightsPresentation.swift")
        self.assertNotRegex(rights, r"[Pp]rovenance\??\.rawValue")
        self.assertIn("SharePreviewWords.summarySource(", rights)


if __name__ == "__main__":
    unittest.main()
