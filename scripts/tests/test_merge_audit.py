from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import merge_audit as audit  # noqa: E402

HEAD = '92533d3' + 'a' * 33
MERGED_AT = '2026-09-29T16:20:47Z'


def comment(body, created_at='2026-09-29T16:12:22Z'):
    return {'body': body, 'created_at': created_at}


CHECK = '**Merge check (triage desk) on `92533d3`: green.**\n- Full `scripts/tests` with the venv Python: 118 OK, twice.'


class MergeCheckTests(unittest.TestCase):
    """The rule from the owner's spec: prefix, head sha7, posted before the merge."""

    def test_a_check_on_the_merged_head_before_the_merge_passes(self):
        self.assertTrue(audit.has_merge_check([comment('Lane report …'), comment(CHECK)], HEAD, MERGED_AT))
        self.assertTrue(audit.has_merge_check([comment('\n  ' + CHECK)], HEAD, MERGED_AT))

    def test_no_check_or_a_check_on_another_head_fails(self):
        self.assertFalse(audit.has_merge_check([comment('Lane report pr254 — PASS')], HEAD, MERGED_AT))
        self.assertFalse(audit.has_merge_check([comment(CHECK.replace('92533d3', '8635de8'))], HEAD, MERGED_AT))
        self.assertFalse(audit.has_merge_check([], HEAD, MERGED_AT))

    def test_a_check_posted_after_the_merge_fails(self):
        # #253: "recorded after the merge, for the audit trail" doesn't count.
        self.assertFalse(audit.has_merge_check([comment(CHECK, '2026-09-29T16:21:16Z')], HEAD, MERGED_AT))
        self.assertFalse(audit.has_merge_check([comment(CHECK, MERGED_AT)], HEAD, MERGED_AT))

    def test_a_comment_with_another_prefix_fails(self):
        for body in ('**Merged under the owner\'s out-of-diff rule** on `92533d3`',
                     'Merge check (triage desk) on `92533d3`: green.',
                     'Looks good. **Merge check (triage desk) on `92533d3`** later.'):
            with self.subTest(body=body):
                self.assertFalse(audit.has_merge_check([comment(body)], HEAD, MERGED_AT))

    def test_the_failure_comment_is_the_specified_text(self):
        self.assertEqual(audit.failure_comment(HEAD), 'Merged into next without a triage-desk merge check on 92533d3. '
                                                      'If the owner merged this directly, remove the label.')


class PushTests(unittest.TestCase):
    """Which merged PRs a push to next brought in, and whether its tip came from no PR."""

    def pr(self, number, merge_sha, base='next', merged=True):
        return {'number': number, 'merge_commit_sha': merge_sha, 'base': {'ref': base},
                'merged_at': MERGED_AT if merged else None, 'head': {'sha': HEAD}}

    def test_a_pr_merge_is_found_by_its_merge_commit(self):
        merged, direct = audit.classify_push(['c1', 'c2', 'm254'], 'm254',
                                             [self.pr(254, 'm254'), self.pr(253, 'm253'), self.pr(1, 'x', merged=False)])
        self.assertEqual((sorted(merged), direct), ([254], False))

    def test_a_push_whose_tip_is_no_pr_merge_is_direct(self):
        merged, direct = audit.classify_push(['c9'], 'c9', [self.pr(254, 'm254')])
        self.assertEqual((merged, direct), ({}, True))
        # A local merge commit on top of a real PR merge still leaves the tip unexplained.
        merged, direct = audit.classify_push(['m254', 'local'], 'local', [self.pr(254, 'm254')])
        self.assertEqual((sorted(merged), direct), ([254], True))

    def test_prs_into_other_branches_are_ignored(self):
        merged, direct = audit.classify_push(['m1'], 'm1', [self.pr(7, 'm1', base='main')])
        self.assertEqual((merged, direct), ({}, True))


if __name__ == '__main__':
    unittest.main()
