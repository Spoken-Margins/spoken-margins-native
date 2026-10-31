"""Area backfill (#2173): maps only unambiguous labels, never overwrites, reads every write back."""
import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sm_area_backfill as backfill
import sm_status


def issue(n, *labels):
    return {'number': n, 'labels': [{'name': label} for label in labels]}


class API:
    repo = 'example/repo'

    def __init__(self, issues, areas, options=('Get it in', 'Hear it well', 'Answer it', 'Pass it on', 'Groundwork'),
                 read_back=True):
        self.issues, self.areas, self.options, self.read_back = issues, areas, options, read_back
        self.mutations = []

    def pages(self, path):
        assert path.startswith('issues?state=open')
        return copy.deepcopy(self.issues)

    def graphql(self, query, **v):
        if query.lstrip().startswith('mutation'):
            self.mutations.append(v)
            name = next(o for o in self.options if f'opt-{o}' == v['value']['singleSelectOptionId'])
            if self.read_back:
                self.areas[int(v['item'][1:])] = name
            return {}
        if 'user(login:' in query:
            return {'user': {'projectV2': {'id': 'P', 'fields': {'pageInfo': {'hasNextPage': False}, 'nodes': [
                {}, {'id': 'F', 'name': 'Area', 'options': [{'id': f'opt-{o}', 'name': o} for o in self.options]}]}}}}
        if 'node(id:$id) { ... on ProjectV2Item' in query:
            return {'node': self.values(int(v['id'][1:]))}
        nodes = [{'id': f'I{n}', 'content': {'__typename': 'Issue', 'repository': {'nameWithOwner': 'Example/Repo'},
                                           'number': n, 'id': f'n{n}', 'state': 'OPEN'},
                  'fieldValues': self.values(n)['fieldValues']} for n in self.areas]
        return {'node': {'items': {'pageInfo': {'hasNextPage': False, 'endCursor': None}, 'nodes': nodes}}}

    def values(self, n):
        value = self.areas[n]
        nodes = [{'name': value, 'field': {'name': 'Area'}}] if value else []
        return {'fieldValues': {'pageInfo': {'hasNextPage': False}, 'nodes': nodes}}


class Propose(unittest.TestCase):
    def test_table(self):
        rows = [
            ((), '', (None, 'no area label')),
            (('bug',), '', (None, 'no area label')),
            (('area: sharing',), '', ('Pass it on', '')),
            (('area: groundwork',), '', ('Groundwork', '')),
            (('area: sharing', 'area: rights'), '', ('Pass it on', '')),          # an unmapped label beside a mapped one
            (('area: sharing', 'area: groundwork'), '', (None, 'labels disagree: area: groundwork, area: sharing')),
            (('area: collaboration',), '', (None, 'unmapped label: area: collaboration')),
            (('area: anchors', 'area: rights'), '', (None, 'unmapped label: area: anchors, area: rights')),
            (('AREA: sharing',), '', (None, 'no area label')),                        # lookalike casing is not the label
            (('area:sharing',), '', (None, 'no area label')),                         # missing space is not the label
            (('area: sharing',), 'Answer it', (None, 'has Area')),                    # never overwrite
        ]
        for labels, current, expected in rows:
            with self.subTest(labels=labels, current=current):
                self.assertEqual(backfill.propose(labels, current), expected)


class Reconcile(unittest.TestCase):
    def run_it(self, api, apply):
        return backfill.reconcile(api, apply=apply)

    def test_dry_run_writes_nothing(self):
        api = API([issue(1, 'area: sharing')], {1: ''})
        report = self.run_it(api, False)
        self.assertEqual(report['set'], [{'issue': 1, 'area': 'Pass it on'}])
        self.assertEqual(api.mutations, [])

    def test_apply_sets_reads_back_and_skips_the_rest(self):
        api = API([issue(1, 'area: sharing'), issue(2, 'area: groundwork', 'bug'), issue(3, 'area: collaboration'),
                   issue(4, 'area: sharing'), issue(5), {'number': 6, 'labels': [], 'pull_request': {}},
                   issue(7, 'area: sharing')],
                  {1: '', 2: '', 3: '', 4: 'Answer it', 5: ''})
        report = self.run_it(api, True)
        self.assertEqual([c['issue'] for c in report['set']], [1, 2])
        self.assertTrue(all(c['verified'] for c in report['set']))
        self.assertEqual(api.areas, {1: 'Pass it on', 2: 'Groundwork', 3: '', 4: 'Answer it', 5: ''})
        self.assertEqual([s['issue'] for s in report['skipped']], [3])
        self.assertEqual(report['no_card'], [7])
        self.assertEqual(report['unknown'], [])

    def test_failed_read_back_is_unknown_not_verified(self):
        api = API([issue(1, 'area: sharing')], {1: ''}, read_back=False)
        report = self.run_it(api, True)
        self.assertEqual(report['unknown'], [{'issue': 1, 'reason': 'Area read-back did not match'}])
        self.assertNotIn('verified', report['set'][0])

    def test_missing_option_stops_before_any_write(self):
        api = API([issue(1, 'area: sharing')], {1: ''}, options=('Get it in', 'Groundwork'))
        report = self.run_it(api, True)
        self.assertEqual(api.mutations, [])
        self.assertIn('Area options missing: Pass it on', report['unknown'][0]['reason'])

    def test_second_run_changes_nothing(self):
        api = API([issue(1, 'area: sharing')], {1: ''})
        self.run_it(api, True)
        self.assertEqual(self.run_it(api, True)['set'], [])


if __name__ == '__main__':
    unittest.main()
