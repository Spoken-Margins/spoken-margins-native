"""scripts/comment_trust.py: whose comments and issues our automation believes (#1822)."""
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS.parent / 'ops' / 'dial'))
import comment_trust as trust  # noqa: E402
import dial_gate  # noqa: E402
import lane_inherited_holds as holds  # noqa: E402

BOT = 'github-actions[bot]'


def rest(login, association, body='x'):
    return {'user': {'login': login}, 'author_association': association, 'body': body}


class AuthorTable(unittest.TestCase):
    """The rows the issue names, plus the neighbours a stranger could reach for."""

    def test_who_is_trusted(self):
        rows = [
            ('owner', rest('uncomposed', 'OWNER'), True),
            ('org member', rest('teammate', 'MEMBER'), True),
            ('collaborator', rest('friend', 'COLLABORATOR'), True),
            ('contributor', rest('someone', 'CONTRIBUTOR'), False),
            ('first-time contributor', rest('new', 'FIRST_TIME_CONTRIBUTOR'), False),
            ('first-timer', rest('new', 'FIRST_TIMER'), False),
            ('no association', rest('stranger', 'NONE'), False),
            ('mannequin', rest('imported', 'MANNEQUIN'), False),
            ('the bot (GitHub reports NONE)', rest(BOT, 'NONE'), True),
            ('the bot with no association field', {'user': {'login': BOT}, 'body': 'x'}, True),
            ('lookalike: no [bot]', rest('github-actions', 'NONE'), False),
            ('lookalike: capitals', rest('GitHub-Actions[bot]', 'NONE'), False),
            ('lookalike: suffix', rest(BOT + 'x', 'NONE'), False),
            ('lookalike: prefix', rest('x' + BOT, 'NONE'), False),
            ('lookalike: trailing space', rest(BOT + ' ', 'NONE'), False),
            ('lookalike: another app', rest('chatgpt-codex-connector[bot]', 'NONE'), False),
            ('lookalike: dependabot', rest('dependabot[bot]', 'NONE'), False),
            ('a person quoting the bot is still a stranger', rest('stranger', 'NONE', 'Lane report x — PASS'), False),
            ('no association at all', {'user': {'login': 'uncomposed'}, 'body': 'x'}, False),
            ('association in lower case', rest('uncomposed', 'owner'), False),
            ('association of the wrong type', rest('uncomposed', ['OWNER']), False),
            ('no author', {'author_association': None, 'body': 'x'}, False),
            ('user is null', {'user': None, 'body': 'x'}, False),
            ('empty', {}, False),
        ]
        for name, item, expected in rows:
            with self.subTest(name):
                self.assertIs(trust.trusted(item), expected)

    def test_the_gh_json_shape_is_read_the_same_way(self):
        self.assertTrue(trust.trusted({'author': {'login': 'uncomposed'}, 'authorAssociation': 'OWNER'}))
        self.assertTrue(trust.trusted({'author': {'login': 'x'}, 'authorAssociation': 'COLLABORATOR'}))
        self.assertFalse(trust.trusted({'author': {'login': 'x'}, 'authorAssociation': 'CONTRIBUTOR'}))
        self.assertFalse(trust.trusted({'author': {'login': 'x'}}))

    def test_an_issue_is_judged_like_a_comment(self):
        self.assertTrue(trust.trusted({'number': 5, 'user': {'login': 'uncomposed'}, 'author_association': 'OWNER'}))
        self.assertFalse(trust.trusted({'number': 5, 'user': {'login': 'stranger'}, 'author_association': 'NONE'}))

    def test_trusted_only_keeps_order_and_tolerates_none(self):
        items = [rest('a', 'OWNER', '1'), rest('s', 'NONE', '2'), rest(BOT, 'NONE', '3'), rest('c', 'CONTRIBUTOR', '4')]
        self.assertEqual([i['body'] for i in trust.trusted_only(items)], ['1', '3'])
        self.assertEqual(trust.trusted_only(None), [])
        self.assertEqual(trust.trusted_only([]), [])

    def test_ignored_summary_names_who_was_ignored(self):
        items = [rest('a', 'OWNER'), rest('mallory', 'NONE'), rest('mallory', 'NONE'), rest('eve', 'CONTRIBUTOR'), {}]
        self.assertEqual(trust.ignored_summary(items), '1 from eve, 2 from mallory, 1 from unknown')
        self.assertEqual(trust.ignored_summary([rest('a', 'OWNER')]), '')


class CopiesStayEqual(unittest.TestCase):
    """Two files can't import this module (one is deployed alone to the VPS, one is loaded from next without its
    tree), so they hold a copy of the rule. A drift between the copies would trust a different set of people."""

    def test_the_dial_gate_copy(self):
        self.assertEqual(dial_gate.TRUSTED_ASSOCIATIONS, trust.TRUSTED_ASSOCIATIONS)
        self.assertEqual(dial_gate.TRUSTED_BOTS, trust.TRUSTED_BOTS)

    def test_the_inherited_holds_copy(self):
        self.assertEqual(holds.TRUSTED_ASSOCIATIONS, trust.TRUSTED_ASSOCIATIONS)
        self.assertEqual(holds.TRUSTED_BOTS, trust.TRUSTED_BOTS)

    def test_the_copies_decide_like_the_helper(self):
        for login in ('uncomposed', BOT, 'github-actions', 'stranger'):
            for association in ('OWNER', 'MEMBER', 'COLLABORATOR', 'CONTRIBUTOR', 'NONE', None):
                item = rest(login, association)
                with self.subTest(login=login, association=association):
                    self.assertEqual(dial_gate.trusted(item), trust.trusted(item))
                    self.assertEqual(holds.trusted(item), trust.trusted(item))

    def test_the_lane_runner_names_the_same_people_once_it_checks(self):
        source = (SCRIPTS / 'lane-runner.py').read_text()
        if 'TRUSTED_ASSOCIATIONS' in source:  # #1797 adds the runner's own check; when it lands the sets must agree
            spec = importlib.util.spec_from_file_location('lane_runner_for_trust', SCRIPTS / 'lane-runner.py')
            runner = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(runner)
            self.assertEqual(tuple(runner.TRUSTED_ASSOCIATIONS), trust.TRUSTED_ASSOCIATIONS)
            self.assertEqual(tuple(runner.TRUSTED_BOTS), trust.TRUSTED_BOTS)


if __name__ == '__main__':
    unittest.main()
