"""Host tests for the C2 text front end. Run: .venv/bin/python -m unittest discover -s frontend"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from normalize import normalize  # noqa: E402
from frontend import FrontEnd  # noqa: E402
from lexmap import misaki_to_espeak  # noqa: E402

FE = FrontEnd()


class NoGPL(unittest.TestCase):
    def test_front_end_never_loads_espeak(self):
        loaded = [m for m in sys.modules if m.split(".")[0] in ("phonemizer", "espeakng_loader", "piper", "misaki")]
        self.assertEqual(loaded, [], "the shipping front end must not import espeak, phonemizer or misaki's code")


class Normalization(unittest.TestCase):
    """The I14 examples in docs/workstreams/interfaces.md."""
    def test_statistics(self):
        self.assertEqual(
            normalize("compared with placebo (hazard ratio, 0.88; 95% CI, 0.75 to 1.04; p = 0.12)."),
            "compared with placebo, hazard ratio, zero point eight eight; ninety-five percent confidence interval, "
            "zero point seven five to one point zero four; p equals zero point one two.")

    def test_numeric_citations_are_silent(self):
        self.assertEqual(normalize("consistent with earlier meta-analyses [12, 14] but"),
                         "consistent with earlier meta-analyses but")

    def test_parenthetical_citations_are_silent(self):
        self.assertEqual(normalize("as shown previously (Lee, 2019)."), "as shown previously.")

    def test_et_al_reads_as_colleagues(self):
        self.assertEqual(normalize("reported by Pittas et al."), "reported by Pittas and colleagues.")

    def test_units_after_a_number(self):
        self.assertEqual(normalize("rose from 28 to 54 ng/mL."), "rose from twenty-eight to fifty-four nanograms per milliliter.")

    def test_numbers_years_ordinals_times(self):
        self.assertEqual(normalize("On March 3rd, 2024, at 11:45"), "On March third, twenty twenty-four, at eleven forty-five")
        self.assertEqual(normalize("1,284 adults"), "one thousand two hundred eighty-four adults")

    def test_codes_are_spelled(self):
        self.assertEqual(normalize("baseline HbA1c"), "baseline H B A one C")

    def test_greek(self):
        self.assertIn("beta equals", normalize("β = 0.21"))


class Words(unittest.TestCase):
    def test_function_words_use_reduced_forms(self):
        self.assertEqual(FE.phonemize("the cat"), "ðə kˈæt")
        self.assertEqual(FE.phonemize("the apple").split()[0], "ðɪ")

    def test_abbreviations_are_spelled(self):
        self.assertEqual(FE.word("PBS"), "pˌiːbˌiːˈɛs")

    def test_dictionary_word_in_espeak_convention(self):
        self.assertEqual(misaki_to_espeak("wˈɔɾəɹ", "water"), "wˈɔːɾɚ")
        self.assertEqual(misaki_to_espeak("həlˈO", "hello"), "həlˈoʊ")

    def test_unknown_word_uses_neural_fallback(self):
        before = FE.source_counts.get("neural", 0)
        self.assertTrue(FE.word("Quibbletonkery"))  # used nowhere else, so not cached
        self.assertEqual(FE.source_counts.get("neural", 0), before + 1)

    def test_glued_compound_uses_two_dictionary_words(self):
        self.assertIn("vˈaɪɾəmən", FE.word("hydroxyvitamin"))


class Vectors(unittest.TestCase):
    def test_reference_vectors_still_hold(self):
        path = HERE / "test_vectors.json"
        if not path.exists():
            self.skipTest("run export_for_swift.py first")
        for v in json.loads(path.read_text())["sentences"]:
            self.assertEqual(FE.phonemize(v["text"]), v["phonemes"], v["text"])


if __name__ == "__main__":
    unittest.main()
