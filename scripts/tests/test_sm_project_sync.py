"""Project synchronization regression: exercise the dispatcher command, not a label mirror."""
import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import importlib.util
import unittest
from pathlib import Path


class DispatchRegression(unittest.TestCase):
    def test_claim_missing_from_project_has_a_reconciler(self):
        path = Path(__file__).resolve().parents[1] / 'sm_project_sync.py'
        self.assertTrue(path.exists(), 'A claimed issue can stay missing/Todo: no reconciliation exists')
        spec = importlib.util.spec_from_file_location('sm_project_sync', path)
        sync = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sync)
        self.assertTrue(callable(sync.reconcile))

import copy
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sm_project_sync as sync
import sm_status
from test_sm_status import bundle, routes_for, comment, report, audit, HEAD, OLD, NOW


def issue(n=7, labels=(), state='open', milestone=None):
    return {'number': n, 'node_id': f'I{n}', 'state': state,
            'labels': [{'name': label} for label in labels],
            'milestone': {'title': milestone} if milestone else None}


def event(label='in-progress', at='2026-10-14T19:45:00Z'):
    return {'event': 'labeled', 'label': {'name': label}, 'created_at': at}


class API:
    """Stateful HTTP/GraphQL stand-in: stores fields, checks read-back, counts writes."""
    repo = 'example/repo'

    def __init__(self, issues=(), items=None, bundles=(), health=True):
        self.calls = self.writes = 0
        self.routes = routes_for(*bundles)
        self.routes['issues?state=open&sort=created&direction=asc'] = [i for i in issues if i['state'] == 'open']
        self.routes['pulls?state=all&base=main&sort=created&direction=asc'] = [copy.deepcopy(b['pull']) for b in bundles]
        for i in issues:
            n = i['number']
            self.routes.update({f'issues/{n}': i, f'issues/{n}/events': [event()],
                                f'issues/{n}/comments': [], f'git/matching-refs/heads/ws/{n}-': []})
        self.items = copy.deepcopy(items or {})
        self.health = health
        self.read_back = True
        self.graph_errors = {}
        self.mutations = []
        self.reads = []

    def get(self, path):
        self.calls += 1
        self.reads.append(path)
        value = self.routes[path]
        if isinstance(value, Exception):
            raise value
        return copy.deepcopy(value)

    pages = get

    def field_values(self, values):
        return {'pageInfo': {'hasNextPage': False}, 'nodes': [
            {'name' if key == 'Status' else 'text': value, 'field': {'name': key}}
            for key, value in values.items()]}

    def graphql(self, query, **v):
        self.calls += 1
        for token, error in self.graph_errors.items():
            if token in query:
                raise error
        if query.lstrip().startswith('mutation'):
            self.writes += 1
            self.mutations.append((query, v))
        if 'user(login:' in query:
            fields = [{'id': 'status', 'name': 'Status', 'options': [
                {'id': name, 'name': name} for name in sorted(sync.STATUSES)]}]
            if self.health:
                fields.append({'id': 'health', 'name': sync.HEALTH})
            return {'user': {'projectV2': {'id': 'project', 'fields': {
                'nodes': fields, 'pageInfo': {'hasNextPage': False}}}}}
        if 'items(first:' in query:
            nodes = [{'id': f'item{n}', 'content': {'__typename': 'Issue', 'id': f'I{n}', 'number': n,
                                                 'state': (self.routes.get(f'issues/{n}') or {}).get('state', 'open').upper(),
                                                 'repository': {'nameWithOwner': self.repo}},
                      'fieldValues': self.field_values(values)} for n, values in self.items.items()]
            # Unrelated content deliberately has no usable issue fields.
            nodes += [{'id': 'draft', 'content': {'__typename': 'DraftIssue'}},
                      {'id': 'foreign', 'content': {'__typename': 'Issue', 'number': 9,
                                                   'repository': {'nameWithOwner': 'other/repo'}}}]
            return {'node': {'items': {'nodes': nodes, 'pageInfo': {'hasNextPage': False}}}}
        if 'createProjectV2Field' in query:
            self.health = True
            return {'createProjectV2Field': {'projectV2Field': {'id': 'health'}}}
        if 'addProjectV2ItemById' in query:
            n = int(v['content'][1:])
            self.items[n] = {}
            return {'addProjectV2ItemById': {'item': {'id': f'item{n}'}}}
        if 'updateProjectV2ItemFieldValue' in query:
            n = int(v['item'][4:])
            field = 'Status' if v['field'] == 'status' else sync.HEALTH
            self.items[n][field] = v['value'].get('text', v['value'].get('singleSelectOptionId'))
            return {'updateProjectV2ItemFieldValue': {'projectV2Item': {'id': v['item']}}}
        if 'clearProjectV2ItemFieldValue' in query:
            self.items[int(v['item'][4:])].pop(sync.HEALTH, None)
            return {'clearProjectV2ItemFieldValue': {'projectV2Item': {'id': v['item']}}}
        values = self.items[int(v['id'][4:])] if self.read_back else {'Status': 'Todo'}
        return {'node': {'fieldValues': self.field_values(values)}}


def merged(paths=('App/SpokenMarginsApp/Player.swift',), body='Closes #7'):
    b = bundle(files=paths, body=body)
    b['pull'].update(state='closed', merged_at='2026-10-14T19:50:00Z')
    return b


class Reconciliation(unittest.TestCase):
    def run_sync(self, api, apply=False, only=None):
        return sync.reconcile(api, apply=apply, only=only, now=NOW)

    def test_missing_claim_added_and_status_read_back(self):
        api = API([issue(labels=['in-progress', 'priority'])])
        dry = self.run_sync(api)
        self.assertEqual(dry['changes'][0]['status'], 'In Progress')
        self.assertTrue(dry['changes'][0]['missing'])
        self.assertEqual(api.writes, 0)
        applied = self.run_sync(api, True)
        self.assertFalse(applied['unknown'])
        self.assertTrue(applied['changes'][0]['verified'])
        self.assertEqual(api.items[7]['Status'], 'In Progress')
        self.assertEqual(api.routes['issues/7']['labels'], issue(labels=['in-progress', 'priority'])['labels'])
        before = api.writes
        again = self.run_sync(api, True)
        self.assertEqual(again['unchanged'], 1)
        self.assertEqual(again['changes'], [])
        self.assertEqual(api.writes, before)

    def test_release_clears_health_and_preserves_area(self):
        api = API([issue()], {7: {'Status': 'Checking', sync.HEALTH: 'Needs attention: failure', 'Area': 'Groundwork'}})
        self.run_sync(api, True)
        self.assertEqual(api.items[7], {'Status': 'Todo', 'Area': 'Groundwork'})

    def test_open_pr_overrides_claim_and_has_health(self):
        api = API([issue(labels=['in-progress'])], bundles=[bundle()])
        result = self.run_sync(api, True)
        self.assertFalse(result['unknown'])
        self.assertEqual(api.items[7]['Status'], 'Checking')
        self.assertEqual(api.items[7][sync.HEALTH], 'Waiting on checks/review')

    def test_draft_is_implementation(self):
        api = API([issue()], bundles=[bundle(draft=True)])
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'In Progress')

    def test_failed_head_blocking_audit_and_conflict_remain_visible(self):
        b = bundle(comments=[report('PASS', OLD), audit('Blocking findings.')],
                   files=['Packages/SessionKit/Sources/SessionKitAudio/Player.swift'],
                   mergeable=False, checks=[{'id': 1, 'name': 'host', 'status': 'completed', 'conclusion': 'failure'}])
        api = API([issue()], bundles=[b])
        change = self.run_sync(api)['changes'][0]
        self.assertEqual(change['status'], 'Checking')
        self.assertIn('Needs attention:', change['health'])
        self.assertIn('red-on-head', change['health'])
        self.assertIn('audit-blocking', change['health'])
        self.assertIn('conflict', change['health'])
        self.assertIn('only PASS on bbbbbbb', change['reason'])

    def test_old_pass_is_not_a_head_pass(self):
        api = API([issue()], bundles=[bundle(comments=[report('PASS', OLD)])])
        change = self.run_sync(api)['changes'][0]
        self.assertIn('lane none on head', change['reason'])
        self.assertEqual(change['status'], 'Checking')

    def test_merged_but_unvalidated_is_never_done(self):
        for labels in ([], ['in-progress', 'status: needs-human-validation', 'found-on-phone', 'priority']):
            with self.subTest(labels=labels):
                api = API([issue(labels=labels)], bundles=[merged()])
                result = self.run_sync(api, True)
                self.assertFalse(result['unknown'])
                self.assertEqual(api.items[7]['Status'], 'Needs your check')
                self.assertEqual(api.routes['issues/7']['state'], 'open')
                self.assertEqual(api.routes['issues/7']['labels'], issue(labels=labels)['labels'])

    def test_agent_verify_and_validate_by_use_are_not_owner_checks(self):
        for label in ('agent-verify', 'validate-by-use'):
            with self.subTest(label=label):
                api = API([issue(labels=['found-on-phone', label])], bundles=[merged()])
                change = self.run_sync(api)['changes'][0]
                self.assertEqual(change['status'], 'Checking')
                self.assertIn(label, change['reason'])

    def test_705_later_beats_stale_claim_and_prior_merge(self):
        api = API([issue(labels=['in-progress'], milestone='Later')], bundles=[merged(paths=['scripts/tool.py'])])
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'Todo')

    def test_closed_issue_follows_completion_and_preserves_protected_labels(self):
        for labels, wanted in (([], 'Done'), (['found-on-phone', 'priority'], 'Done')):
            api = API([issue(labels=labels, state='closed')], {7: {'Status': 'Checking'}})
            self.assertEqual(self.run_sync(api)['changes'][0]['status'], wanted)

    def test_closed_card_is_done_from_the_project_read_alone(self):
        # A full run used to GET every closed card's issue one by one: 90 of a live run's 162 calls (2026-10-15).
        api = API([issue(labels=['found-on-phone'], state='closed'), issue(8)],
                  {7: {'Status': 'Checking', sync.HEALTH: 'Waiting on checks/review'}, 8: {'Status': 'Todo'}})
        result = self.run_sync(api, True)
        self.assertEqual([(c['issue'], c['status']) for c in result['changes']], [(7, 'Done')])
        self.assertTrue(result['changes'][0]['verified'])
        self.assertIn('issues/7', api.reads)          # a card about to be written is read from the issue first
        self.assertEqual(api.items[7], {'Status': 'Done'})
        api.reads.clear()
        again = self.run_sync(api, True)
        self.assertEqual((again['changes'], again['unchanged']), ([], 2))
        self.assertNotIn('issues/7', api.reads)       # already Done: the project read alone settles it
        targeted = self.run_sync(api, only=[7])       # a hook for one issue still reads it
        self.assertIn('issues/7', api.reads)
        self.assertEqual(targeted['changes'], [])

    def test_an_issue_reopened_during_the_run_is_never_set_done(self):
        # The project read says CLOSED and the open list was read before the reopen; Done would make the board's
        # Auto-close workflow close the owner's reopened issue again.
        api = API([issue(state='closed')], {7: {'Status': 'Needs your check'}})
        graphql = api.graphql
        def reopened_after_the_board_read(query, **v):
            data = graphql(query, **v)
            if 'items(first:' in query:
                api.routes['issues/7'] = issue(labels=['status: needs-human-validation'])
            return data
        api.graphql = reopened_after_the_board_read
        result = self.run_sync(api, True)
        self.assertNotIn('Done', [c['status'] for c in result['changes']])
        self.assertEqual(api.items[7]['Status'], 'Needs your check')

    def test_stale_claim_routine_comments_do_not_count_as_implementer(self):
        api = API([issue(labels=['in-progress'])])
        api.routes['issues/7/events'] = [event(at='2026-10-14T10:00:00Z')]
        api.routes['issues/7/comments'] = [
            comment('Claimed by project thread "A"', at='2026-10-14T10:00:00Z'),
            comment('**Owner phone check: PASS.**', at='2026-10-14T19:58:00Z'),
            comment('Lane report r — PASS', at='2026-10-14T19:59:00Z'),
            comment('**Claude audit on `abc`**', at='2026-10-14T19:59:00Z')]
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'Todo')

    def test_recent_progress_and_branch_commit_count(self):
        for branch in (False, True):
            api = API([issue(labels=['in-progress'])])
            api.routes['issues/7/events'] = [event(at='2026-10-14T10:00:00Z')]
            api.routes['issues/7/comments'] = [comment('Claimed by project thread "A"', at='2026-10-14T10:00:00Z')]
            if branch:
                api.routes['git/matching-refs/heads/ws/7-'] = [{'object': {'sha': HEAD}}]
                api.routes[f'commits/{HEAD}'] = {'commit': {'committer': {'date': '2026-10-14T19:58:00Z'}}}
            else:
                api.routes['issues/7/comments'].append(comment('Regression now fails; working on fix.', at='2026-10-14T19:58:00Z'))
            self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'In Progress')

    def test_stop_note_releases_still_labeled_claim(self):
        api = API([issue(labels=['in-progress'])])
        api.routes['issues/7/events'] = [event(at='2026-10-14T17:00:00Z')]
        api.routes['issues/7/comments'] = [comment('Claimed by project thread "A"'), comment('Thread "A" stopping: handed back')]
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'Todo')

    def test_a_strangers_comments_do_not_move_a_card(self):
        """#1822: a stranger's stop note doesn't release a claim, and a stranger's chatter isn't progress."""
        stranger = {'user': {'login': 'mallory'}, 'author_association': 'NONE'}
        api = API([issue(labels=['in-progress'])])
        api.routes['issues/7/events'] = [event(at='2026-10-14T17:00:00Z')]
        api.routes['issues/7/comments'] = [comment('Claimed by project thread "A"', at='2026-10-14T17:00:00Z'),
                                           dict(comment('Thread "A" stopping: handed back', at='2026-10-14T18:00:00Z'),
                                                **stranger)]
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'In Progress')
        api = API([issue(labels=['in-progress'])])
        api.routes['issues/7/events'] = [event(at='2026-10-14T10:00:00Z')]
        api.routes['issues/7/comments'] = [comment('Claimed by project thread "A"', at='2026-10-14T10:00:00Z'),
                                           dict(comment('Regression now fails; working on fix.', at='2026-10-14T19:58:00Z'),
                                                **stranger)]
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'Todo')

    def test_partial_pr_read_failure_no_speculative_downgrade(self):
        api = API([issue(), issue(8)], {7: {'Status': 'In Progress'}}, [bundle()])
        api.routes[f'commits/{HEAD}/check-runs'] = sm_status.GitHubError('rate limited')
        result = self.run_sync(api, True)
        self.assertEqual(result['unknown'][0]['issue'], 7)
        self.assertEqual(api.items[7]['Status'], 'In Progress')
        self.assertEqual(api.items[8]['Status'], 'Todo')
        self.assertFalse(any(v.get('item') == 'item7' for _, v in api.mutations))

    def test_global_issue_pr_and_project_read_failures_write_nothing(self):
        for location in ('issues', 'pulls', 'project'):
            api = API([issue()], {7: {'Status': 'In Progress'}})
            if location == 'project':
                api.graph_errors['items(first:'] = sm_status.GitHubError('partial GraphQL data')
            else:
                path = ('issues?state=open&sort=created&direction=asc' if location == 'issues' else
                        'pulls?state=all&base=main&sort=created&direction=asc')
                api.routes[path] = sm_status.GitHubError('incomplete paginated read')
            result = self.run_sync(api, True)
            self.assertTrue(result['unknown'])
            self.assertEqual(api.writes, 0)

    def test_claim_api_failure_keeps_current_card(self):
        api = API([issue(labels=['in-progress'])], {7: {'Status': 'In Progress'}})
        api.routes['git/matching-refs/heads/ws/7-'] = sm_status.GitHubError('unreadable')
        result = self.run_sync(api, True)
        self.assertTrue(result['unknown'])
        self.assertEqual(api.writes, 0)

    def test_read_back_failure_is_reported(self):
        api = API([issue(labels=['in-progress'])])
        api.read_back = False
        result = self.run_sync(api, True)
        self.assertTrue(result['unknown'])
        self.assertNotIn('verified', result['changes'][0])

    def test_health_field_created_once_only_when_needed(self):
        api = API([issue()], bundles=[bundle()], health=False)
        dry = self.run_sync(api)
        self.assertEqual(dry['field_changes'][0]['name'], sync.HEALTH)
        self.assertFalse(api.health)
        self.assertEqual(api.writes, 0)
        self.assertFalse(self.run_sync(api, True)['unknown'])
        self.assertTrue(api.health)
        before = api.writes
        self.run_sync(api, True)
        self.assertEqual(api.writes, before)

    def test_refs_are_not_implementation_prs(self):
        b = bundle(body='Refs #7', files=['docs/file.md'])
        b['pull']['head']['ref'] = 'ws/70-file'
        api = API([issue()], bundles=[b])
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'Todo')

    def test_targeted_hook_does_not_change_other_issue(self):
        api = API([issue(), issue(8)], {8: {'Status': 'Checking'}})
        result = self.run_sync(api, True, only=[7])
        self.assertEqual([c['issue'] for c in result['changes']], [7])
        self.assertEqual(api.items[8]['Status'], 'Checking')

    def test_internal_merge_waits_for_existing_closure_rule(self):
        api = API([issue()], bundles=[merged(paths=['scripts/fix.py'])])
        change = self.run_sync(api)['changes'][0]
        self.assertEqual(change['status'], 'Checking')
        self.assertIn('closure pending', change['health'])

    def test_reopened_or_reclaimed_issue_not_hidden_by_older_merge(self):
        api = API([issue(labels=['in-progress'])], bundles=[merged()])
        api.routes['issues/7/events'] = [event(at='2026-10-14T19:55:00Z')]
        self.assertEqual(self.run_sync(api)['changes'][0]['status'], 'In Progress')


class ReviewFixes(unittest.TestCase):
    def test_reclaimed_after_merge_shows_active_work_even_with_the_validation_label(self):
        labels = ['in-progress', 'status: needs-human-validation']
        api = API([issue(labels=labels)], bundles=[merged()])
        api.routes['issues/7/events'] = [event(at='2026-10-14T19:55:00Z')]
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'In Progress')
        # a claim older than the merge, or a quiet claim, leaves it waiting for the owner
        api.routes['issues/7/events'] = [event(at='2026-10-14T10:00:00Z')]
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'Needs your check')
        api.routes['issues/7/events'] = [event(at='2026-10-14T19:55:00Z')]
        api.routes['issues/7/comments'] = [comment('Thread "A" stopping: handed back', at='2026-10-14T19:57:00Z')]
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'Needs your check')

    def test_normal_merge_states_are_not_attention(self):
        for state in ('blocked', 'unstable', 'has_hooks'):
            with self.subTest(state=state):
                b = bundle()
                b['pull']['mergeable_state'] = state
                change = sync.reconcile(API([issue()], bundles=[b]), now=NOW)['changes'][0]
                self.assertEqual(change['health'], 'Waiting on checks/review')

    def test_issue_argument_that_is_a_pull_request_is_reported(self):
        api = API([issue()])
        api.routes['issues/9'] = {'number': 9, 'pull_request': {}}
        result = sync.reconcile(api, only=[9], now=NOW)
        self.assertEqual(result['unknown'], [{'issue': 9, 'reason': '#9 is a pull request, not an issue'}])


class SafetyEdges(unittest.TestCase):
    def test_pr_merged_during_live_read_uses_fresh_state(self):
        b = merged()
        api = API([issue()], bundles=[b])
        api.routes['pulls?state=all&base=main&sort=created&direction=asc'][0]['state'] = 'open'
        result = sync.reconcile(api, now=NOW)
        self.assertEqual(result['changes'][0]['status'], 'Needs your check')

    def test_closed_unmerged_pr_is_not_completion(self):
        b = bundle()
        b['pull']['state'] = 'closed'
        api = API([issue()], bundles=[b])
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'Todo')

    def test_empty_claim_metadata_is_unknown(self):
        api = API([issue(labels=['in-progress'])], {7: {'Status': 'Checking'}})
        api.routes['issues/7/events'] = []
        result = sync.reconcile(api, apply=True, now=NOW)
        self.assertTrue(result['unknown'])
        self.assertEqual(api.writes, 0)

    def test_blocked_issue_is_distinguished_from_backlog(self):
        api = API([issue(labels=['blocked'])])
        change = sync.reconcile(api, now=NOW)['changes'][0]
        self.assertEqual(change['status'], 'Todo')
        self.assertIn('Needs attention: blocked', change['health'])

    def test_graphql_partial_errors_are_not_success(self):
        api = sync.GitHub(token='unused')
        api.post = lambda *args: {'errors': [{'message': 'permission denied'}], 'data': {'user': None}}
        with self.assertRaises(sm_status.GitHubError):
            api.graphql('query { user { id } }')

    def test_mutation_failure_is_reported_and_not_verified(self):
        api = API([issue()])
        api.graph_errors['updateProjectV2ItemFieldValue'] = sm_status.GitHubError('mutation failed')
        result = sync.reconcile(api, apply=True, now=NOW)
        self.assertTrue(result['unknown'])
        self.assertNotIn('verified', result['changes'][0])

    def test_incomplete_project_field_read_is_unknown(self):
        api = API([issue()])
        graphql = api.graphql
        def incomplete(query, **variables):
            data = graphql(query, **variables)
            if 'user(login:' in query:
                data['user']['projectV2']['fields']['pageInfo']['hasNextPage'] = True
            return data
        api.graphql = incomplete
        result = sync.reconcile(api, apply=True, now=NOW)
        self.assertTrue(result['unknown'])
        self.assertEqual(api.writes, 0)

    def test_missing_status_options_leave_every_field_untouched(self):
        api = API([issue()])
        graphql = api.graphql
        def missing(query, **variables):
            data = graphql(query, **variables)
            if 'user(login:' in query:
                data['user']['projectV2']['fields']['nodes'][0]['options'] = []
            return data
        api.graphql = missing
        result = sync.reconcile(api, apply=True, now=NOW)
        self.assertIn('Status options missing', result['unknown'][0]['reason'])
        self.assertEqual(api.writes, 0)

    def test_multiple_issues_share_one_live_pr_read(self):
        b = bundle(body='Closes #7. Fixes #8.')
        api = API([issue(), issue(8)], bundles=[b])
        result = sync.reconcile(api, now=NOW)
        self.assertEqual(len(result['changes']), 2)
        self.assertEqual(api.reads.count('pulls/1'), 1)
        self.assertEqual(api.reads.count('pulls/1/files'), 1)

    def test_project_pagination_visits_later_items(self):
        api = API([issue(), issue(8)], {7: {'Status': 'Todo'}, 8: {'Status': 'Checking'}})
        graphql = api.graphql
        cursors = []
        def paged(query, **v):
            data = graphql(query, **v)
            if 'items(first:' in query:
                cursors.append(v['cursor'])
                connection = data['node']['items']
                if v['cursor'] is None:
                    connection['nodes'] = connection['nodes'][:1]
                    connection['pageInfo'] = {'hasNextPage': True, 'endCursor': 'second'}
                else:
                    connection['nodes'] = connection['nodes'][1:]
            return data
        api.graphql = paged
        result = sync.reconcile(api, apply=True, now=NOW)
        self.assertFalse(result['unknown'])
        self.assertEqual(cursors, [None, 'second'])
        self.assertEqual(api.items[8]['Status'], 'Todo')


class CommandAndCost(unittest.TestCase):
    def test_real_client_counts_graphql_reads_separately_from_mutations(self):
        from unittest.mock import patch
        api = sync.GitHub(token='unused')
        with patch.object(sm_status.GitHub, 'request', return_value=({'data': {'ok': True}}, {})):
            api.graphql('query { viewer { id } }')
            api.graphql('mutation { something }')
            api.get('issues/7')
        self.assertEqual(api.calls, 3)
        self.assertEqual(api.writes, 1)

    def test_cli_default_dry_run_and_existing_ledger_apply(self):
        from unittest.mock import patch
        import contextlib
        import io
        import json
        import tempfile
        api = API([issue(labels=['in-progress'])])
        with patch.object(sync, 'GitHub', return_value=api), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sync.main([]), 0)
        self.assertEqual(api.writes, 0)
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(sync, 'GitHub', return_value=api), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sync.main(['--apply', '--ledger-state', folder]), 0)
            ledger = json.loads((Path(folder) / 'step-ledger.json').read_text())
            self.assertEqual(ledger['steps']['project-sync']['runs'], 1)
            self.assertEqual(ledger['steps']['project-sync']['pass'], 1)

    def test_cli_unknown_exits_two(self):
        from unittest.mock import patch
        import contextlib
        import io
        api = API([issue()])
        api.graph_errors['user(login:'] = sm_status.GitHubError('unreachable')
        with patch.object(sync, 'GitHub', return_value=api), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sync.main(['--apply']), 2)
        self.assertEqual(api.writes, 0)


class PhoneEvidence(unittest.TestCase):
    def test_new_found_on_phone_bug_is_backlog_not_acceptance(self):
        api = API([issue(labels=['found-on-phone', 'ready', 'priority'])])
        result = sync.reconcile(api, now=NOW)
        self.assertEqual(result['changes'][0]['status'], 'Todo')

    def test_explicit_validation_label_is_owner_acceptance(self):
        for label in sync.VALIDATION:
            api = API([issue(labels=[label])])
            result = sync.reconcile(api, now=NOW)
            self.assertEqual(result['changes'][0]['status'], 'Needs your check')

    def test_merged_found_on_phone_fix_is_not_internal_auto_completion(self):
        api = API([issue(labels=['found-on-phone'])], bundles=[merged(paths=['scripts/fix.py'])])
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'Needs your check')


class ExistingPhoneRules(unittest.TestCase):
    def test_model_move_and_app_hosted_tests_await_internal_closure(self):
        for title, paths in [('Move playback to its own file', ['App/SpokenMarginsApp/Coordinator.swift']),
                             ('Test playback', ['App/SpokenMarginsAppTests/Tests.swift'])]:
            b = merged(paths=paths)
            b['pull']['title'] = title
            api = API([issue()], bundles=[b])
            change = sync.reconcile(api, now=NOW)['changes'][0]
            self.assertEqual(change['status'], 'Checking')
            self.assertIn('closure pending', change['health'])

    def test_explicit_no_phone_check_uses_existing_parser(self):
        b = merged(body='Closes #7\n\n**Owner check:** none (model split only).')
        api = API([issue()], bundles=[b])
        change = sync.reconcile(api, now=NOW)['changes'][0]
        self.assertEqual(change['status'], 'Checking')

    def test_validation_evidence_overrides_no_check_prose(self):
        b = merged(body='Closes #7\nOwner check: none.')
        api = API([issue(labels=['status: needs-human-validation'])], bundles=[b])
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'Needs your check')


class ClaimOrdering(unittest.TestCase):
    def test_reclaim_label_after_old_stop_is_active(self):
        api = API([issue(labels=['in-progress'])])
        api.routes['issues/7/comments'] = [comment('Claimed by project thread "A"'), comment('Thread "A" stopping: handed back')]
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'In Progress')


class IncompleteResponse(unittest.TestCase):
    def test_incomplete_success_response_does_not_downgrade(self):
        api = API([], {7: {'Status': 'In Progress'}})
        api.routes['issues/7'] = {'number': 7}
        result = sync.reconcile(api, apply=True, now=NOW)
        self.assertTrue(result['unknown'])
        self.assertEqual(api.writes, 0)
        self.assertEqual(api.items[7]['Status'], 'In Progress')


class PhoneCheckConflict(unittest.TestCase):
    def test_real_check_is_not_discarded_by_an_older_none_field(self):
        b = merged(body='Closes #7\nOwner check: Play the article and record a Margin.')
        i = issue()
        i['body'] = 'Owner check: none.'
        api = API([i], bundles=[b])
        self.assertEqual(sync.reconcile(api, now=NOW)['changes'][0]['status'], 'Needs your check')
