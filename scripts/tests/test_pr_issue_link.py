"""PR issue-link check (#2167): the neighbour table of body forms, and the label and comment it leaves behind."""
import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pr_issue_link as link
import sm_status

URL = 'https://github.com/Spoken-Margins/spoken-margins-native/issues/12'


def pull(number=50, body='', title='Fix the thing', labels=()):
    return {'number': number, 'body': body, 'title': title, 'labels': [{'name': name} for name in labels]}


class Names(unittest.TestCase):
    def test_body_forms(self):
        table = {
            'Closes #12': [12],
            'closes #12': [12],
            'CLOSES #12': [12],
            'Fixes: #12': [12],
            'Resolves #12': [12],
            'Part of #12': [12],
            'part of #12': [12],
            f'Closes {URL}': [12],
            'Closes #12\nPart of #13': [12, 13],
            'Closes #12 and Closes #12': [12],
            '<!-- claude-projects-attribution -->\n_Requested by **Cole**_\n\nCloses #12\n\nCost and catch': [12],
            f'See {URL}': [],          # a bare URL is no link
            'Related to #12': [],
            'see #12': [],
            'Closes\n#12': [],         # GitHub needs the number on the same line
            'Closes #50': [],          # the PR's own number
            'Closes 12': [],
            'Closes': [],
            '': [],
            None: [],
        }
        for body, expected in table.items():
            with self.subTest(body=body):
                self.assertEqual(link.named_issues(pull(body=body)), expected)

    def test_a_number_in_the_title_alone_is_not_a_link(self):
        self.assertEqual(link.named_issues(pull(title='Fix the thing (#12)')), [])

    def test_housekeeping_is_exempt(self):
        self.assertTrue(link.exempt(pull(body='No issue')))
        self.assertTrue(link.exempt(pull(body='Tidy.\n\nno issue\n')))
        self.assertTrue(link.exempt(pull(body='- No issue: ops notes only')))
        self.assertTrue(link.exempt(pull(title='chore: bump the lockfile')))
        self.assertTrue(link.exempt(pull(title='Chore(ops): rotate logs')))
        self.assertFalse(link.exempt(pull(body='There is no issue for this yet, sorry')))
        self.assertFalse(link.exempt(pull(body='No issue yet, filing later')))
        self.assertTrue(link.exempt(pull(body='**No issue**')))
        self.assertTrue(link.exempt(pull(body='No issue: ops notes only.')))
        self.assertFalse(link.exempt(pull(title='chores for the week')))
        self.assertFalse(link.exempt(pull()))

    def test_only_ops_notes_are_exempt_by_path(self):
        self.assertTrue(link.exempt(pull(), ['ops/dial/README.md', 'ops/claude/README.md']))
        self.assertFalse(link.exempt(pull(), ['ops/dial/README.md', 'scripts/x.py']))
        self.assertFalse(link.exempt(pull(), ['ops/dial/dial_gate.py']))
        self.assertFalse(link.exempt(pull(), ['docs/x.md']))
        self.assertFalse(link.exempt(pull(), []))
        self.assertFalse(link.exempt(pull(), None))


class API:
    def __init__(self, pulls, files=None, comments=None):
        self.pulls, self.files, self.comment_rows = pulls, files or {}, comments or {}
        self.writes = []

    def pages(self, path, **_):
        if path.startswith('pulls?state=open'):
            return self.pulls
        if path.endswith('/files'):
            number = int(path.split('/')[1])
            return [{'filename': name} for name in self.files.get(number, ['App/x.swift'])]
        if path.endswith('/comments'):
            return self.comment_rows.get(int(path.split('/')[1]), [])
        raise AssertionError(path)

    def post(self, path, body):
        self.writes.append(('POST', path, body))

    def delete(self, path):
        self.writes.append(('DELETE', path))


def comment(body, association='OWNER', login='uncomposed'):
    return {'body': body, 'author_association': association, 'user': {'login': login}}


class Reconcile(unittest.TestCase):
    def test_dry_run_reads_and_writes_nothing(self):
        api = API([pull(1), pull(2, 'Closes #9')])
        report = link.reconcile(api)
        self.assertEqual((report['flagged'], api.writes), ([1], []))

    def test_flags_once_with_label_and_comment(self):
        api = API([pull(1)])
        report = link.reconcile(api, apply=True)
        self.assertEqual(report['flagged'], [1])
        self.assertEqual(api.writes[0][:2], ('POST', 'issues/1/comments'))
        self.assertIn(link.MARKER, api.writes[0][2]['body'])
        self.assertIn('Closes #N', api.writes[0][2]['body'])
        self.assertEqual(api.writes[1], ('POST', 'issues/1/labels', {'labels': [link.LABEL]}))

    def test_a_failed_comment_leaves_no_label_so_the_next_run_retries(self):
        class NoComment(API):
            def post(self, path, body):
                if path.endswith('/comments'):
                    raise sm_status.GitHubError('HTTP 502')
                super().post(path, body)
        api = NoComment([pull(1)])
        report = link.reconcile(api, apply=True)
        self.assertEqual((api.writes, report['unknown'][0]['pr']), ([], 1))

    def test_a_label_already_gone_is_not_a_fault(self):
        class Gone(API):
            def delete(self, path):
                raise sm_status.GitHubError('DELETE ' + path + ': HTTP 404 Label does not exist')
        report = link.reconcile(Gone([pull(1, 'Closes #9', labels=[link.LABEL])]), apply=True)
        self.assertEqual((report['cleared'], report['unknown']), ([1], []))

    def test_a_labelled_pr_that_is_still_unlinked_is_left_alone(self):
        api = API([pull(1, labels=[link.LABEL])])
        report = link.reconcile(api, apply=True)
        self.assertEqual((report['flagged'], report['unchanged'], api.writes), ([], 1, []))

    def test_label_removed_by_hand_returns_without_a_second_comment(self):
        api = API([pull(1)], comments={1: [comment(link.COMMENT)]})
        link.reconcile(api, apply=True)
        self.assertEqual([w[1] for w in api.writes], ['issues/1/labels'])

    def test_a_stranger_copying_the_marker_does_not_silence_the_comment(self):
        api = API([pull(1)], comments={1: [comment(link.MARKER, 'NONE', 'mallory')]})
        link.reconcile(api, apply=True)
        self.assertEqual([w[1] for w in api.writes], ['issues/1/comments', 'issues/1/labels'])

    def test_fixing_the_body_clears_the_label(self):
        api = API([pull(1, 'Closes #9', labels=[link.LABEL])])
        report = link.reconcile(api, apply=True)
        self.assertEqual((report['cleared'], api.writes), ([1], [('DELETE', f'issues/1/labels/{link.LABEL}')]))

    def test_ops_notes_only_pr_is_not_flagged(self):
        api = API([pull(1)], files={1: ['ops/dial/README.md']})
        self.assertEqual(link.reconcile(api, apply=True)['flagged'], [])
        self.assertEqual(api.writes, [])

    def test_a_failed_read_is_reported_and_the_rest_continue(self):
        class Broken(API):
            def pages(self, path, **kw):
                if path == 'pulls/1/files':
                    raise sm_status.GitHubError('HTTP 502')
                return super().pages(path, **kw)
        api = Broken([pull(1), pull(2)])
        report = link.reconcile(api)
        self.assertEqual(report['flagged'], [2])
        self.assertEqual(report['unknown'][0]['pr'], 1)


if __name__ == '__main__':
    unittest.main()
