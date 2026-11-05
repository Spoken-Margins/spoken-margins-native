"""Every path that carries a Listening Map off the phone goes through MapTextDisclosure (#3449).

Model-written scene titles and summaries leave the device only for a source marked public. The packet path
(`SharedMarginExport.mapProposals(_:for:)`) and the export path (`ListeningMapExportResolver`) apply the gate; this scan
fails when a new app path builds a packet or reads the resolver without it. The Mac tools under SessionKitTools build
packets from an edition the author wrote, not from a listener's Library, and are left out.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [*ROOT.glob("App/**/Sources/**/*.swift"), *ROOT.glob("Packages/SessionKit/Sources/**/*.swift")]

PACKET_BUILD = re.compile(r"SpokenMarginsPackageBuilder\.prepare\(")
GATED_PROPOSALS = re.compile(r"SharedMarginExport\.mapProposals\([^)]*\bfor:", re.S)
RESOLVER_CALL = re.compile(r"ListeningMapExportResolver\.resolve\(")


class MapTextGateTests(unittest.TestCase):
    def test_every_packet_build_takes_its_proposals_through_the_gate(self):
        builders = [p for p in SOURCES if PACKET_BUILD.search(p.read_text())]
        self.assertTrue(builders, "the scan found no packet builder; update the pattern")
        for path in builders:
            if path.name == "SharingFoundation.swift":  # the builder itself
                continue
            self.assertRegex(path.read_text(), GATED_PROPOSALS,
                             f"{path.relative_to(ROOT)} builds a packet without SharedMarginExport.mapProposals(_:for:) (#3449)")

    def test_the_gate_is_applied_inside_the_export_helpers(self):
        for rel in ("Packages/SessionKit/Sources/SessionKitSharing/SharedMarginExport.swift",
                    "Packages/SessionKit/Sources/SessionKit/ListeningMapExportResolver.swift"):
            self.assertIn("MapTextDisclosure.", (ROOT / rel).read_text(), rel)

    def test_the_resolver_is_only_called_from_the_engine_where_the_gate_sits_inside_it(self):
        callers = {p.name for p in SOURCES if RESOLVER_CALL.search(p.read_text())}
        self.assertEqual(callers, {"SessionEngine.swift"}, "a new caller of the export resolver: check it keeps the gate (#3449)")


if __name__ == "__main__":
    unittest.main()
