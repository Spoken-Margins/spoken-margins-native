"""#712: real commit ancestry with REST-shaped source audits; no network/build/simulator."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane_inherited_audits as holds
import test_lane_runner as runner_tests
from test_lane_runner import FakeGitHub, lane

REPO = 'example/repo'
URL = f'https://github.com/{REPO}/pull/616#issuecomment-42'


def clean(head, marker=None, association='OWNER'):
    body = f'**Codex audit (Astra) on `{head[:7]}`**\n\nNo blocking findings.'
    if marker is not None:
        body += '\n<!-- inherited-audit-resolution: ' + json.dumps(marker) + ' -->'
    return {'body': body, 'author_association': association}


class InheritedAudits(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tree = Path(self.tmp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.test')
        self.base = self.commit('base')
        self.git('checkout', '-q', '-b', 'a')
        self.a = self.commit('blocked')
        self.git('checkout', '-q', '-b', 'b', self.base)
        self.commit('descendant')
        self.git('merge', '-q', '--no-ff', '-m', 'Include A', self.a)
        self.b = self.git('rev-parse', 'HEAD')
        self.source = [{'body': f'**Codex audit (Astra) on `{self.a[:7]}`**\n\n[P2] Text is lost.',
                        'html_url': URL}]
        self.calls = []

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.tree), *args], text=True,
                                       stderr=subprocess.PIPE).strip()

    def commit(self, name):
        (self.tree / name).write_text(name)
        self.git('add', name)
        self.git('commit', '-q', '-m', name)
        return self.git('rev-parse', 'HEAD')

    def api(self, path):
        self.calls.append(path)
        if '/pulls?state=closed' in path:
            return []
        if '/commits/' in path:
            sha = path.split('/commits/')[1].split('/')[0]
            # Source PR is closed and its current head has moved. Neither hides
            # its recorded blocking audit of the commit actually in B.
            return [{'number': 636}] + ([{'number': 616, 'state': 'closed', 'head': {'sha': 'f' * 40}}]
                                        if sha == self.a else [])
        self.assertEqual(path, f'repos/{REPO}/issues/616/comments?per_page=100')
        return self.source

    def findings(self, base=None, head=None):
        return holds.collect(self.tree, REPO, 636, base or self.base, head or self.b, api=self.api)

    def resolution(self, findings=None, head=None):
        finding = (findings or self.findings())[0]
        return {**{k: finding[k] for k in ('audit', 'audit_sha256')},
                'head': head or self.b, 'resolution': 'fixed',
                'evidence': 'App import regression now retains literal tags; reviewed the sanitizer fix.'}

    def test_blocked_a_in_clean_b_is_unresolved_even_with_closed_moved_source_pr(self):
        findings = self.findings()
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]['source_head'], self.a)
        self.assertEqual(holds.unresolved(findings, [clean(self.b)], self.b), findings)

    def test_exact_head_resolution_admits_and_wrong_head_or_edited_finding_does_not(self):
        findings = self.findings()
        resolution = self.resolution(findings)
        self.assertEqual(holds.unresolved(findings, [clean(self.b, resolution)], self.b), [])
        resolution['head'] = self.a
        self.assertEqual(holds.unresolved(findings, [clean(self.b, resolution)], self.b), findings)
        resolution = self.resolution(findings)
        self.source[0]['body'] += '\nAdditional counterexample.'
        edited = self.findings()
        self.assertEqual(holds.unresolved(edited, [clean(self.b, resolution)], self.b), edited)

    def test_generic_clean_source_or_descendant_does_not_clear_a_record(self):
        self.source.append(clean(self.a))
        findings = self.findings()
        self.assertEqual(holds.unresolved(findings, [clean(self.b)], self.b), findings)

    def test_resolution_does_not_clear_an_unfixed_sibling(self):
        cleared = clean(self.b, self.resolution())
        self.git('checkout', '-q', '-b', 'sibling', self.a)
        sibling = self.commit('unfixed')
        findings = self.findings(head=sibling)
        self.assertEqual(holds.unresolved(findings, [cleared, clean(sibling)], sibling), findings)

    def test_unrelated_and_already_integrated_commits_do_not_hold(self):
        self.git('checkout', '-q', '-b', 'unrelated', self.base)
        unrelated = self.commit('unrelated')
        self.assertEqual(self.findings(head=unrelated), [])
        self.calls.clear()
        self.assertEqual(self.findings(base=self.a), [])
        self.assertFalse(any('/issues/' in path for path in self.calls))

    def test_closed_unmerged_source_is_checked_without_commit_association(self):
        def api(path):
            if '/commits/' in path:
                return [{'number': 636}]
            if '/pulls?state=closed' in path:
                return [{'number': 616, 'merged_at': None, 'head': {'sha': 'f' * 40}}]
            return self.api(path)
        findings = holds.collect(self.tree, REPO, 636, self.base, self.b, api=api)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]['source_pr'], 616)

    def test_api_failure_is_not_an_empty_finding_set(self):
        with self.assertRaises(RuntimeError):
            holds.collect(self.tree, REPO, 636, self.base, self.b,
                          api=mock.Mock(side_effect=RuntimeError('GitHub unavailable')))

    def test_shallow_history_fails_closed(self):
        # Actual shallow clone, not a fake ancestry response.
        shallow = self.tree / 'shallow'
        subprocess.run(['git', 'clone', '-q', '--depth=1', self.tree.as_uri(), str(shallow)], check=True)
        with self.assertRaisesRegex(ValueError, 'complete Git history'):
            holds.collect(shallow, REPO, 636, self.base, self.b, api=self.api)

    def test_clearance_must_be_reviewed_in_the_latest_clean_head_audit(self):
        findings = self.findings()
        resolved = clean(self.b, self.resolution(findings))
        for comments in ([resolved, clean(self.b)], [clean(self.b, self.resolution(findings), 'NONE')],
                         [{'body': resolved['body'].replace('No blocking findings.', 'Blocking findings.'),
                           'author_association': 'OWNER'}]):
            with self.subTest(comments=comments):
                self.assertEqual(holds.unresolved(findings, comments, self.b), findings)
        no_evidence = {**self.resolution(findings), 'evidence': ' '}
        self.assertEqual(holds.unresolved(findings, [clean(self.b, no_evidence)], self.b), findings)

    def test_resolution_of_one_record_does_not_resolve_another(self):
        self.source.append({**self.source[0], 'html_url': URL.replace('42', '43')})
        findings = self.findings()
        self.assertEqual(holds.unresolved(findings, [clean(self.b, self.resolution(findings))], self.b), findings[1:])

    def test_candidate_own_audit_behavior_is_not_replaced(self):
        self.assertEqual(holds.collect(self.tree, REPO, 616, self.base, self.a,
                                      api=lambda _: [{'number': 616}]), [])

    def test_context_supplies_original_record_and_exact_resolution_contract(self):
        finding = self.findings()[0]
        context = holds.context([finding], self.b)
        for value in (URL, finding['body'], finding['audit_sha256'], self.b, 'inherited-audit-resolution'):
            self.assertIn(value, context)

    def test_real_ancestry_drives_runner_rejection_and_explicit_resolution_admission(self):
        # Keep real ancestry and parser; stub only expensive builds and remote push.
        for resolved in (False, True):
            comments = [clean(self.b, self.resolution() if resolved else None)]
            github = FakeGitHub(labels=('automerge',), head=self.b, comments=comments)
            github.inherited_audit_blockers = lambda *_: holds.reasons(self.findings(), github.comments(), self.b)
            with tempfile.TemporaryDirectory() as evidence, \
                    mock.patch.object(lane, 'ROOT', self.tree), \
                    mock.patch.object(lane, 'build_merge_commit', return_value=(self.b, [])), \
                    mock.patch.object(lane, 'warm_build_folders', return_value='warm'), \
                    mock.patch.object(lane, 'diff_scope', return_value=runner_tests.MergeTests_Runner.SCOPE), \
                    mock.patch.object(lane, 'run_automerge', return_value=('PASS', 'host', 'tests/builds pass', [])), \
                    mock.patch.object(lane, 'sweep_merge_audit'), \
                    mock.patch.object(lane, 'push_merge', return_value=(True, '')) as pushed:
                verdict, _, _, details = lane.run_auto(github, {}, 636, 'next', self.b, self.base, Path(evidence), [])
            self.assertEqual(verdict, 'PASS')
            self.assertEqual(pushed.called, resolved)
            self.assertIn('merged into next' if resolved else 'unresolved inherited audit', details[-1])


if __name__ == '__main__':
    unittest.main()
