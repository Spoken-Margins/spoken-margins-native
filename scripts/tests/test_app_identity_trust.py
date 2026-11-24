"""#4915 step 1: every helper that decides trust by login reads the agents' GitHub App as ours.

GitHub reports a comment or issue from the App `spoken-margins-agent` as `spoken-margins-agent[bot]` with
author_association NONE. A helper that trusts only collaborators and `github-actions[bot]` reads that as a stranger,
so an audit, hold note, /lane request or report an agent posts as the App would be ignored and the PR held or the
report skipped. Each test below fails on the helper before its App entry was added.

Several helpers keep their own copy of the slug list (they load as standalone modules, some from the base branch).
`test_every_copy_matches_comment_trust` keeps those copies from drifting apart, so adding or renaming the App in
scripts/comment_trust.py without the others fails here.
"""
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(ROOT / 'ops' / 'dial'))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses look their module up here
    spec.loader.exec_module(module)
    return module


import comment_trust  # noqa: E402
import lane_inherited_holds  # noqa: E402
import lane_t3  # noqa: E402
import main_t3  # noqa: E402
import merge_audit  # noqa: E402
import dial_gate  # noqa: E402

lane_merge_rules = load('lane_merge_rules', SCRIPTS / 'lane_merge_rules.py')
precheck = load('integration_precheck', SCRIPTS / 'integration-precheck.py')

APP = 'spoken-margins-agent'


def rest(login, association='NONE', body='x'):
    return {'body': body, 'user': {'login': login}, 'author_association': association}


LOOKALIKES = (
    APP,                                # a person named like the slug
    f'{APP}[bot]x',
    f'x{APP}[bot]',
    f'{APP}s[bot]',
    'Spoken-Margins-Agent[bot]',
    'spoken-margins-helper[bot]',       # another App
    '',
)

HELPERS = {
    'lane_merge_rules.trusted_comment': lane_merge_rules.trusted_comment,
    'main_t3.trusted': main_t3.trusted,
    'lane_t3._tally_trusted': lane_t3._tally_trusted,
    'integration-precheck.trusted': precheck.trusted,
    'integration-precheck.report_author': precheck.report_author,
}


class AppReadsAsOurs(unittest.TestCase):

    def test_each_helper_trusts_the_app(self):
        for name, helper in HELPERS.items():
            with self.subTest(name):
                self.assertTrue(helper(rest(f'{APP}[bot]')))

    def test_each_helper_still_refuses_lookalikes(self):
        for name, helper in HELPERS.items():
            for login in LOOKALIKES:
                with self.subTest(name, login=login):
                    self.assertFalse(helper(rest(login)))

    def test_an_app_audit_clears_the_merge_rules_trust_gate(self):
        # The comment a local Codex or Claude audit posts, once it posts as the App.
        audit = rest(f'{APP}[bot]', 'NONE', '**Codex audit (Astra)** on `abc1234`: PASS')
        self.assertTrue(lane_merge_rules.trusted_comment(audit))

    def test_integration_precheck_sees_an_app_desk_report(self):
        report = rest(f'{APP}[bot]', 'NONE', 'Test Desk report\n\nPASS')
        self.assertTrue(precheck.is_desk(report))


class SlugListsAgree(unittest.TestCase):

    def test_every_copy_matches_comment_trust(self):
        copies = {
            'lane_merge_rules': lane_merge_rules.TRUSTED_APP_SLUGS,
            'main_t3': main_t3.TRUSTED_APP_SLUGS,
            'lane_t3': lane_t3.TRUSTED_APP_SLUGS,
            'integration-precheck': precheck.TRUSTED_APP_SLUGS,
            'merge_audit': merge_audit.TRUSTED_APP_SLUGS,
            'lane_inherited_holds': lane_inherited_holds.TRUSTED_APP_SLUGS,
            'dial_gate': dial_gate.TRUSTED_APP_SLUGS,
        }
        for name, slugs in copies.items():
            with self.subTest(name):
                self.assertEqual(tuple(slugs), tuple(comment_trust.TRUSTED_APP_SLUGS))


if __name__ == '__main__':
    unittest.main()
