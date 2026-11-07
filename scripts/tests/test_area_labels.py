"""Area labels (#3636): exactly one area label per open issue, `needs-area` otherwise, and the one-off board copy."""
import os
os.environ.pop('SM_TRUNK', None)
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import area_labels as al
import sm_status


def issue(number, *labels, pull=False):
    item = {'number': number, 'labels': [{'name': name} for name in labels]}
    if pull:
        item['pull_request'] = {}
    return item


class FakeApi:
    def __init__(self, issues, labels=None):
        self.issues = issues
        self.labels = labels if labels is not None else [*al.AREAS, al.NEEDS]
        self.writes = []

    def pages(self, path, limit=30, partial=False):
        if path == 'labels':
            return [{'name': name} for name in self.labels]
        assert path.startswith('issues?state=open'), path
        return self.issues

    def post(self, path, body):
        self.writes.append(('POST', path, body))

    def delete(self, path):
        self.writes.append(('DELETE', path))
        if path.endswith('/gone'):
            raise sm_status.GitHubError('HTTP 404')


class BoardNames(unittest.TestCase):
    def test_board_option_names(self):
        table = {
            '1. Get it in': 'area: get it in',
            '2. Hear it well': 'area: hear it well',
            '3) Answer it': 'area: answer it',
            '4 Pass it on': 'area: pass it on',
            'Groundwork': 'area: groundwork',
            'groundwork': 'area: groundwork',
            '  Hear   it  well ': 'area: hear it well',
            'GET IT IN': 'area: get it in',
            'Social': None,
            '': None,
            'Hear it': None,
            '5. Groundworks': None,
        }
        for name, want in table.items():
            with self.subTest(name=name):
                self.assertEqual(al.board_name_to_label(name), want)


class Reconcile(unittest.TestCase):
    def test_one_area_is_fine_none_or_two_are_flagged_and_prs_are_skipped(self):
        api = FakeApi([issue(1, 'area: groundwork', 'bug'), issue(2, 'bug'),
                       issue(3, 'area: groundwork', 'area: hear it well'), issue(4, pull=True)])
        report = al.reconcile(api, apply=True)
        self.assertEqual(report['unchanged'], 1)
        self.assertEqual(report['flagged'], [{'issue': 2, 'areas': []},
                                             {'issue': 3, 'areas': ['area: groundwork', 'area: hear it well']}])
        self.assertEqual(api.writes, [('POST', 'issues/2/labels', {'labels': ['needs-area']}),
                                      ('POST', 'issues/3/labels', {'labels': ['needs-area']})])

    def test_a_fixed_issue_loses_needs_area_and_a_flagged_one_is_not_flagged_again(self):
        api = FakeApi([issue(1, 'area: answer it', 'needs-area'), issue(2, 'needs-area')])
        report = al.reconcile(api, apply=True)
        self.assertEqual((report['cleared'], report['flagged'], report['unchanged']), ([1], [], 1))
        self.assertEqual(api.writes, [('DELETE', 'issues/1/labels/needs-area')])

    def test_a_look_alike_label_is_not_an_area(self):
        api = FakeApi([issue(1, 'area:groundwork'), issue(2, 'Area: Groundwork')])
        self.assertEqual([f['issue'] for f in al.reconcile(api)['flagged']], [1, 2])

    def test_dry_run_writes_nothing_and_missing_labels_are_created_on_apply(self):
        api = FakeApi([issue(1)], labels=['bug'])
        report = al.reconcile(api)
        self.assertEqual(api.writes, [])
        self.assertEqual(report['labels_created'], [*al.AREAS, al.NEEDS])
        al.reconcile(api, apply=True)
        self.assertEqual(sum(1 for w in api.writes if w[1] == 'labels'), 6)

    def test_the_board_copy_fills_only_issues_with_no_area(self):
        api = FakeApi([issue(1), issue(2, 'area: pass it on'), issue(3), issue(4)])
        board = {1: '1. Get it in', 2: 'Groundwork', 3: 'Social'}
        report = al.reconcile(api, apply=True, board=board)
        self.assertEqual(report['copied'], [{'issue': 1, 'label': 'area: get it in'}])
        self.assertEqual(report['unknown'], [{'issue': 3, 'reason': "board Area 'Social' is no area"}])
        self.assertEqual([f['issue'] for f in report['flagged']], [3, 4])
        self.assertIn(('POST', 'issues/1/labels', {'labels': ['area: get it in']}), api.writes)
        self.assertNotIn(('POST', 'issues/1/labels', {'labels': ['needs-area']}), api.writes)


if __name__ == '__main__':
    unittest.main()
