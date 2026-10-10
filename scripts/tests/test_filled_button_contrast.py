"""Filled evergreen and plum button labels are readable in light and dark mode (#537).

Runs the app's own Foundation-only contrast audit (`ExperienceColorContrast.swift`) on the host,
so a colour change that makes `onEvergreen` unreadable on evergreen or plum fails here too, not only
in the app-hosted `ExperienceColorContrastTests`. Also checks `filledActionButton` still sets that
label colour, which the source scan in test_filled_button_labels.py relies on.
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App/SpokenMarginsApp/Sources/SpokenMarginsApp"
AUDIT = APP / "ExperienceColorContrast.swift"
DESIGN_SYSTEM = APP / "ExperienceDesignSystem.swift"

PROBE = """
import Foundation

func ratios(_ name: String) -> String {
    guard let pair = AppColorContrastAudit.textBackgroundPairs.first(where: { $0.name == name }) else {
        return "\\(name): missing"
    }
    let light = AppColorContrastAudit.contrastRatio(foreground: pair.foreground.light, background: pair.background.light)
    let dark = AppColorContrastAudit.contrastRatio(foreground: pair.foreground.dark, background: pair.background.dark)
    return "\\(name): light \\(String(format: "%.2f", light)) dark \\(String(format: "%.2f", dark))"
}

print(ratios("label on evergreen"))
print(ratios("response import label"))
for failure in AppColorContrastAudit.failures() {
    print("FAIL \\(failure)")
}
"""


def run_audit() -> list[str]:
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise unittest.SkipTest("swiftc is not installed")
    with tempfile.TemporaryDirectory() as tmp:
        main = Path(tmp) / "main.swift"
        main.write_text(PROBE, encoding="utf-8")
        binary = Path(tmp) / "contrast-audit"
        subprocess.run([swiftc, str(AUDIT), str(main), "-o", str(binary)], check=True,
                       capture_output=True, text=True, timeout=300)
        out = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=60)
    return out.stdout.splitlines()


class FilledButtonContrastTests(unittest.TestCase):
    def test_button_labels_meet_contrast_in_both_appearances(self):
        lines = run_audit()
        for name in ("label on evergreen", "response import label"):
            line = next((l for l in lines if l.startswith(f"{name}:")), f"{name}: not printed")
            self.assertRegex(line, r"light \d+\.\d+ dark \d+\.\d+", f"the audit must register {name!r}")
        self.assertEqual([l for l in lines if l.startswith("FAIL ")], [], "\n".join(lines))

    def test_filled_action_button_sets_the_on_evergreen_label(self):
        text = DESIGN_SYSTEM.read_text(encoding="utf-8")
        match = re.search(r"func filledActionButton\([^)]*\)[^{]*\{(.*?)\n    \}", text, re.S)
        self.assertIsNotNone(match, "filledActionButton is missing from ExperienceDesignSystem.swift")
        body = match.group(1)
        self.assertIn("buttonStyle(.borderedProminent)", body)
        self.assertIn(".foregroundStyle(AppColors.onEvergreen)", body)


if __name__ == "__main__":
    unittest.main()
