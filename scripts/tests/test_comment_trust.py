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
import merge_audit  # noqa: E402

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

    def test_the_bot_in_graphql_shape_needs_its_bot_marker(self):
        rows = [
            ('GraphQL bot', {'author': {'login': 'github-actions', '__typename': 'Bot'}, 'authorAssociation': 'NONE'}, True),
            ('gh app login', {'author': {'login': 'app/github-actions', 'is_bot': True}, 'authorAssociation': 'NONE'}, True),
            ('a user named github-actions', {'author': {'login': 'github-actions', '__typename': 'User'}, 'authorAssociation': 'NONE'}, False),
            ('no marker', {'author': {'login': 'github-actions'}, 'authorAssociation': 'NONE'}, False),
            ('is_bot false', {'author': {'login': 'github-actions', 'is_bot': False}}, False),
            ('another bot', {'author': {'login': 'dependabot', '__typename': 'Bot'}, 'authorAssociation': 'NONE'}, False),
            ('marker on a REST user is ignored', {'user': {'login': 'github-actions', '__typename': 'Bot'}}, False),
        ]
        for name, item, expected in rows:
            with self.subTest(name):
                self.assertIs(trust.trusted(item), expected)

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


APP = 'spoken-margins-agent'  # the slug the #4915 registration link proposes; the owner may pick another


class AppIdentity(unittest.TestCase):
    """#4915 Done when 3: how a GitHub App the agents act as is read, before and after its slug is configured.

    GitHub reports an App's comments and PRs as `<slug>[bot]` with association NONE in REST, and as `<slug>`
    (GraphQL, `__typename: Bot`) or `app/<slug>` (`gh --json`, `is_bot: true`) elsewhere."""

    def setUp(self):
        self._saved = trust.TRUSTED_APP_SLUGS

    def tearDown(self):
        trust.TRUSTED_APP_SLUGS = self._saved

    @staticmethod
    def shapes(slug=APP):
        return [
            ('REST comment', rest(f'{slug}[bot]', 'NONE')),
            ('REST PR, no association field', {'user': {'login': f'{slug}[bot]'}, 'number': 1}),
            ('GraphQL', {'author': {'login': slug, '__typename': 'Bot'}, 'authorAssociation': 'NONE'}),
            ('gh --json', {'author': {'login': f'app/{slug}', 'is_bot': True}, 'authorAssociation': 'NONE'}),
        ]

    def test_the_shipped_list_trusts_no_app_yet(self):
        # Today the App would read as an outsider. The change that moves the first job to it (#4915 step 3) adds its
        # slug to TRUSTED_APP_SLUGS and turns this test into one that names the configured slug.
        self.assertEqual(trust.TRUSTED_APP_SLUGS, ())
        for name, item in self.shapes():
            with self.subTest(name):
                self.assertFalse(trust.trusted(item))

    def test_a_configured_app_is_trusted_in_every_shape(self):
        trust.TRUSTED_APP_SLUGS = (APP,)
        for name, item in self.shapes():
            with self.subTest(name):
                self.assertTrue(trust.trusted(item))
        self.assertEqual(trust.ignored_summary([item for _, item in self.shapes()]), '')

    def test_lookalikes_stay_strangers_when_the_app_is_configured(self):
        trust.TRUSTED_APP_SLUGS = (APP,)
        rows = [
            ('a person named like the slug', rest(APP, 'NONE')),
            ('capitals', rest('Spoken-Margins-Agent[bot]', 'NONE')),
            ('suffix after [bot]', rest(f'{APP}[bot]x', 'NONE')),
            ('extra letter before [bot]', rest(f'{APP}s[bot]', 'NONE')),
            ('prefix', rest(f'x{APP}[bot]', 'NONE')),
            ('trailing space', rest(f'{APP}[bot] ', 'NONE')),
            ('another App', rest('spoken-margins-helper[bot]', 'NONE')),
            ('a contributor quoting the App', rest('stranger', 'CONTRIBUTOR', f'{APP}[bot]: audit PASS')),
            ('GraphQL user, not bot', {'author': {'login': APP, '__typename': 'User'}, 'authorAssociation': 'NONE'}),
            ('GraphQL, no marker', {'author': {'login': APP}, 'authorAssociation': 'NONE'}),
            ('gh --json, is_bot false', {'author': {'login': f'app/{APP}', 'is_bot': False}}),
            ('GraphQL marker on a REST user', {'user': {'login': APP, '__typename': 'Bot'}}),
            ('GraphQL login with [bot]', {'author': {'login': f'{APP}[bot]x', '__typename': 'Bot'}}),
        ]
        for name, item in rows:
            with self.subTest(name):
                self.assertFalse(trust.trusted(item))

    def test_configuring_the_app_leaves_everyone_else_as_before(self):
        before = [trust.trusted(item) for item in self._population()]
        trust.TRUSTED_APP_SLUGS = (APP,)
        self.assertEqual([trust.trusted(item) for item in self._population()], before)

    @staticmethod
    def _population():
        items = []
        for login in ('uncomposed', BOT, 'github-actions', 'stranger', 'dependabot[bot]', ''):
            for association in ('OWNER', 'MEMBER', 'COLLABORATOR', 'CONTRIBUTOR', 'NONE', None):
                items.append(rest(login, association))
                items.append({'author': {'login': login, '__typename': 'Bot'}, 'authorAssociation': association})
        return items


class CopiesStayEqual(unittest.TestCase):
    """Two files can't import this module (one is deployed alone to the VPS, one is loaded from next without its
    tree), so they hold a copy of the rule. A drift between the copies would trust a different set of people."""

    def test_the_dial_gate_copy(self):
        self.assertEqual(dial_gate.TRUSTED_ASSOCIATIONS, trust.TRUSTED_ASSOCIATIONS)
        self.assertEqual(dial_gate.TRUSTED_BOTS, trust.TRUSTED_BOTS)

    def test_the_inherited_holds_copy(self):
        self.assertEqual(holds.TRUSTED_ASSOCIATIONS, trust.TRUSTED_ASSOCIATIONS)
        self.assertEqual(holds.TRUSTED_BOTS, trust.TRUSTED_BOTS)

    def test_the_merge_audit_copy(self):
        # .github/workflows/merge-audit.yml checks out only scripts/merge_audit.py: it can't import the helper.
        self.assertEqual(merge_audit.TRUSTED_ASSOCIATIONS, trust.TRUSTED_ASSOCIATIONS)
        self.assertEqual(merge_audit.TRUSTED_BOTS, trust.TRUSTED_BOTS)
        self.assertEqual(merge_audit.GRAPHQL_BOT_LOGINS, trust.GRAPHQL_BOT_LOGINS)
        self.assertNotIn('import comment_trust', (SCRIPTS / 'merge_audit.py').read_text())

    def test_the_merge_audit_copy_decides_like_the_helper_in_every_shape(self):
        shapes = []
        for login in ('uncomposed', BOT, 'github-actions', 'app/github-actions', 'stranger', ''):
            for association in ('OWNER', 'MEMBER', 'COLLABORATOR', 'CONTRIBUTOR', 'NONE', None):
                shapes.append({'user': {'login': login}, 'author_association': association})
                shapes.append({'author': {'login': login}, 'authorAssociation': association})
                for marker in ({'__typename': 'Bot'}, {'__typename': 'User'}, {'is_bot': True}, {'is_bot': False}):
                    shapes.append({'author': dict(marker, login=login), 'authorAssociation': association})
        shapes += [{}, {'user': None}, {'author': None}]
        for item in shapes:
            with self.subTest(item=item):
                self.assertEqual(merge_audit.trusted(item), trust.trusted(item))

    def test_the_copies_decide_like_the_helper(self):
        for login in ('uncomposed', BOT, 'github-actions', 'stranger'):
            for association in ('OWNER', 'MEMBER', 'COLLABORATOR', 'CONTRIBUTOR', 'NONE', None):
                item = rest(login, association)
                with self.subTest(login=login, association=association):
                    self.assertEqual(dial_gate.trusted(item), trust.trusted(item))
                    self.assertEqual(holds.trusted(item), trust.trusted(item))

    def test_the_copies_learn_the_app_with_the_helper(self):
        # #4915: when step 3 adds the App's slug here, the audit, the dial gate and the inherited-holds check must
        # learn it in the same change, or the audit would ignore the App's comments while everything else trusts them.
        for name, copy in (('dial_gate', dial_gate), ('lane_inherited_holds', holds), ('merge_audit', merge_audit)):
            with self.subTest(name):
                self.assertEqual(tuple(getattr(copy, 'TRUSTED_APP_SLUGS', ())), trust.TRUSTED_APP_SLUGS)

    def test_the_merge_rules_name_the_same_people_once_they_check(self):
        source = (SCRIPTS / 'lane_merge_rules.py').read_text()  # moved out of lane-runner.py (#4769)
        if 'TRUSTED_ASSOCIATIONS' in source:  # #1797 adds the runner's own check; when it lands the sets must agree
            spec = importlib.util.spec_from_file_location('lane_merge_rules_for_trust', SCRIPTS / 'lane_merge_rules.py')
            runner = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(runner)
            self.assertEqual(tuple(runner.TRUSTED_ASSOCIATIONS), trust.TRUSTED_ASSOCIATIONS)
            self.assertEqual(tuple(runner.TRUSTED_BOTS), trust.TRUSTED_BOTS)


if __name__ == '__main__':
    unittest.main()
