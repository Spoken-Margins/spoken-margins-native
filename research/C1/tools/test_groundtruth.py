"""Ground-truth conversion checks that don't need the corpus."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from groundtruth import Segment, claim_parenthetical_authors  # noqa: E402


class ParentheticalAuthorsTest(unittest.TestCase):
    def claim(self, text, label):
        seg = Segment("body")
        seg.text = text
        return claim_parenthetical_authors(seg, label), seg.text

    def test_names_before_a_tagged_year_join_the_citation(self):
        self.assertEqual(self.claim("ataxia (Gilman et al., ", "2008"), ("Gilman et al., 2008", "ataxia ("))
        self.assertEqual(self.claim("ataxia ( ; Wenning and Krismer, ", "2022"), ("Wenning and Krismer, 2022", "ataxia ( ; "))
        self.assertEqual(self.claim("(see Langfelder and Horvath, ", "2008"), ("see Langfelder and Horvath, 2008", "("))

    def test_narrative_and_non_citation_text_stays_body(self):
        self.assertEqual(self.claim("as Gilman et al. (", "2008"), ("2008", "as Gilman et al. ("))
        self.assertEqual(self.claim("(Table 1, ", "2008"), ("2008", "(Table 1, "))
        self.assertEqual(self.claim("(Gilman et al., ", "12"), ("12", "(Gilman et al., "))


if __name__ == "__main__":
    unittest.main()
