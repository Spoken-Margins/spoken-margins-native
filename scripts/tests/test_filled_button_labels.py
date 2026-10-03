"""Filled evergreen and plum buttons must set their label colour (#537).

`.buttonStyle(.borderedProminent)` with `.tint(AppColors.evergreen)` draws the system's white label.
In dark mode evergreen is a light green, and white on it is about 1.8:1, which the owner (red-green
colour-blind) can't read on Add to Library. `AppSemanticColorRGB.onEvergreen` is the label colour the
contrast audit checks against evergreen and plum, so every such button goes through
`.filledActionButton(...)`, which sets it, or sets `.foregroundStyle(AppColors.onEvergreen)` itself.
The app's own contrast test can't see which label a SwiftUI style draws, so this scan guards it.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App"
TINTED = re.compile(r"\.tint\(AppColors\.(evergreen|plum)\)")


def unlabelled_filled_buttons(text: str) -> list[int]:
    """Line numbers of borderedProminent buttons tinted evergreen or plum with no label colour."""
    lines = text.splitlines()
    found = []
    for index, line in enumerate(lines):
        if ".buttonStyle(.borderedProminent)" not in line:
            continue
        chain = lines[index + 1:index + 4]
        if any(TINTED.search(link) for link in chain) and not any(
            ".foregroundStyle(AppColors.onEvergreen)" in link for link in chain
        ):
            found.append(index + 1)
    return found


class FilledButtonLabelTests(unittest.TestCase):
    def test_scan_flags_the_add_to_library_shape(self):
        bad = """
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.evergreen)
                    .disabled(false)
        """
        self.assertEqual(unlabelled_filled_buttons(bad), [2])
        good = """
                .buttonStyle(.borderedProminent)
                .tint(AppColors.plum)
                .foregroundStyle(AppColors.onEvergreen)
        """
        self.assertEqual(unlabelled_filled_buttons(good), [])

    def test_every_filled_evergreen_or_plum_button_sets_its_label(self):
        offenders = []
        for path in sorted(SOURCES.rglob("*.swift")):
            for line in unlabelled_filled_buttons(path.read_text(encoding="utf-8")):
                offenders.append(f"{path.relative_to(ROOT)}:{line}")
        self.assertEqual(offenders, [], "use .filledActionButton() so the label is onEvergreen")


if __name__ == "__main__":
    unittest.main()
