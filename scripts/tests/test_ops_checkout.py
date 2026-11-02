"""scripts/ops_checkout.py: the checkout the scheduled phone jobs run from stays on main (#2372).

Real git repositories in a temporary folder; no network, no swift, no launchd.
"""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ops_checkout', SCRIPTS / 'ops_checkout.py')
oc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oc)


def git(cwd, *args):
    return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args], cwd=cwd,
                          capture_output=True, text=True, check=True).stdout.strip()


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(['rm', '-rf', str(self.tmp)]))
        self.origin = self.tmp / 'origin'
        self.origin.mkdir()
        git(self.origin, 'init', '-q', '-b', 'main')
        self.commit(self.origin, 'a.txt', 'one')
        self.ops = self.tmp / 'ops'
        git(self.tmp, 'clone', '-q', str(self.origin), 'ops')
        self.state = self.tmp / 'state'
        self.notes = []

    def commit(self, repo, name, text):
        (repo / name).write_text(text)
        git(repo, 'add', name)
        git(repo, 'commit', '-q', '-m', f'change {name} {text}')
        return git(repo, 'rev-parse', 'HEAD')

    def pin(self, **kwargs):
        return oc.pin(self.ops, 'main', state=self.state, notify=lambda *a: self.notes.append(a),
                      min_interval=kwargs.pop('min_interval', 0), **kwargs)


class PinTests(Fixture):
    def test_a_new_main_commit_is_picked_up_detached(self):
        new = self.commit(self.origin, 'a.txt', 'two')
        self.assertTrue(self.pin().startswith('moved:'))
        self.assertEqual(git(self.ops, 'rev-parse', 'HEAD'), new)
        self.assertEqual(subprocess.run(['git', 'symbolic-ref', '-q', 'HEAD'], cwd=self.ops).returncode, 1)
        self.assertTrue(self.pin().startswith('current:'))

    def test_a_session_branch_left_in_the_checkout_is_put_back_on_main(self):
        # The 2026-10-21 failure: the checkout sat on ws/810-clipped-page-voiceover.
        git(self.ops, 'switch', '-q', '-c', 'ws/810-clipped-page-voiceover')
        branch_tip = self.commit(self.ops, 'b.txt', 'session work')
        main_tip = git(self.origin, 'rev-parse', 'HEAD')
        self.assertTrue(self.pin().startswith('moved:'))
        self.assertEqual(git(self.ops, 'rev-parse', 'HEAD'), main_tip)
        self.assertFalse((self.ops / 'b.txt').exists())
        git(self.ops, 'rev-parse', '--verify', 'ws/810-clipped-page-voiceover')  # the branch itself is kept
        self.assertEqual(git(self.ops, 'rev-parse', 'ws/810-clipped-page-voiceover'), branch_tip)
        self.assertEqual(self.notes, [])

    def test_a_branch_at_the_same_commit_as_main_is_still_detached(self):
        git(self.ops, 'switch', '-q', '-c', 'ws/same')
        self.assertTrue(self.pin().startswith('moved:'))
        self.assertEqual(subprocess.run(['git', 'symbolic-ref', '-q', 'HEAD'], cwd=self.ops).returncode, 1)

    def test_uncommitted_tracked_changes_are_left_alone_and_notified_once_a_day(self):
        self.commit(self.origin, 'a.txt', 'two')
        (self.ops / 'a.txt').write_text('hand edit')
        result = self.pin()
        self.assertTrue(result.startswith('problem:') and 'uncommitted' in result, result)
        self.assertEqual((self.ops / 'a.txt').read_text(), 'hand edit')
        self.pin()
        self.assertEqual(len(self.notes), 1)
        git(self.ops, 'checkout', '--', 'a.txt')
        self.assertTrue(self.pin().startswith('moved:'))
        self.assertFalse((self.state / 'problem.json').exists())

    def test_untracked_files_and_build_output_never_block_the_move(self):
        self.commit(self.origin, 'a.txt', 'two')
        (self.ops / '.build').mkdir()
        (self.ops / '.build/product').write_text('x')
        self.assertTrue(self.pin().startswith('moved:'))
        self.assertTrue((self.ops / '.build/product').exists())

    def test_offline_still_moves_to_the_main_it_already_has(self):
        git(self.ops, 'switch', '-q', '-c', 'ws/x')
        subprocess.run(['rm', '-rf', str(self.origin)])
        result = self.pin()
        self.assertTrue(result.startswith('moved:') and 'could not fetch' in result, result)
        self.assertEqual(self.notes, [])

    def test_a_recent_check_skips_the_fetch_but_still_fixes_a_wrong_branch(self):
        self.pin()  # stamps the time
        new = self.commit(self.origin, 'a.txt', 'two')
        self.assertTrue(self.pin(min_interval=3600).startswith('current:'))  # no fetch, so main did not move yet
        self.assertNotEqual(git(self.ops, 'rev-parse', 'HEAD'), new)
        git(self.ops, 'switch', '-q', '-c', 'ws/y')
        self.assertTrue(self.pin(min_interval=3600).startswith('moved:'))
        self.assertEqual(subprocess.run(['git', 'symbolic-ref', '-q', 'HEAD'], cwd=self.ops).returncode, 1)

    def test_a_folder_that_is_not_a_checkout_is_a_problem_not_a_crash(self):
        empty = self.tmp / 'empty'
        empty.mkdir()
        result = oc.pin(empty, 'main', state=self.state, notify=lambda *a: self.notes.append(a), min_interval=0)
        self.assertTrue(result.startswith('problem:'), result)
        self.assertEqual(len(self.notes), 1)

    def test_a_second_pin_while_one_runs_does_nothing(self):
        import fcntl
        self.state.mkdir(parents=True, exist_ok=True)
        with open(self.state / 'lock', 'a+') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(self.pin().startswith('busy:'))


class EnvTests(Fixture):
    def test_nothing_happens_without_the_setting(self):
        git(self.ops, 'switch', '-q', '-c', 'ws/dev')
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(oc.PIN_ENV, None)
            os.environ.pop(oc.DONE_ENV, None)
            self.assertIsNone(oc.pin_from_env(None))
        self.assertEqual(git(self.ops, 'branch', '--show-current'), 'ws/dev')

    def test_the_setting_pins_that_checkout_once_per_process(self):
        git(self.ops, 'switch', '-q', '-c', 'ws/dev')
        env = {oc.PIN_ENV: str(self.ops), 'SM_OPS_HOME': str(self.tmp / 'opshome'), 'SM_TRUNK': 'main'}
        with mock.patch.dict(os.environ, env):
            os.environ.pop(oc.DONE_ENV, None)
            with mock.patch('sys.stderr'):
                self.assertTrue(oc.pin_from_env(None).startswith('moved:'))
                self.assertIsNone(oc.pin_from_env(None))
        self.assertEqual(git(self.ops, 'branch', '--show-current'), '')

    def test_after_a_move_the_script_starts_again_from_the_new_files(self):
        git(self.ops, 'switch', '-q', '-c', 'ws/dev')
        env = {oc.PIN_ENV: str(self.ops), 'SM_OPS_HOME': str(self.tmp / 'opshome'), 'SM_TRUNK': 'main'}
        with mock.patch.dict(os.environ, env), mock.patch('sys.stderr'), mock.patch.object(oc.os, 'execv') as execv:
            os.environ.pop(oc.DONE_ENV, None)
            oc.pin_from_env(None, reexec=True)
            execv.assert_called_once()
            oc.pin_from_env(None, reexec=True)  # the second call is a no-op, so the new process cannot loop
            execv.assert_called_once()

    def test_a_current_checkout_does_not_restart_the_script(self):
        env = {oc.PIN_ENV: str(self.ops), 'SM_OPS_HOME': str(self.tmp / 'opshome'), 'SM_TRUNK': 'main'}
        with mock.patch.dict(os.environ, env), mock.patch('sys.stderr'), mock.patch.object(oc.os, 'execv') as execv:
            os.environ.pop(oc.DONE_ENV, None)
            git(self.ops, 'checkout', '-q', '--detach')
            oc.pin_from_env(None, reexec=True)
            execv.assert_not_called()

    def test_a_bad_trunk_name_is_a_logged_problem_not_a_crash(self):
        env = {oc.PIN_ENV: str(self.ops), 'SM_OPS_HOME': str(self.tmp / 'opshome'), 'SM_TRUNK': '--oops'}
        with mock.patch.dict(os.environ, env), mock.patch('sys.stderr'):
            os.environ.pop(oc.DONE_ENV, None)
            self.assertTrue(oc.pin_from_env(None).startswith('problem:'))


class ValidatorTests(Fixture):
    def setUp(self):
        super().setUp()
        for package in ('SessionKitTools', 'SessionKit'):
            (self.ops / 'Packages' / package).mkdir(parents=True)
            (self.ops / 'Packages' / package / 'f.swift').write_text('x')
        git(self.ops, 'add', '.')
        git(self.ops, 'commit', '-q', '-m', 'packages')
        self.binary = self.ops / oc.VALIDATOR
        self.calls = []

    def build(self, code=0, make=True):
        def run(command, **kwargs):
            self.calls.append(command)
            if make and code == 0:
                self.binary.parent.mkdir(parents=True, exist_ok=True)
                self.binary.write_text('binary')
            return SimpleNamespace(returncode=code, stdout='', stderr='boom')
        return run

    def test_a_missing_binary_is_built_once_and_then_reused(self):
        self.assertEqual(oc.ensure_validator(self.ops, self.build()), self.binary)
        self.assertEqual(oc.ensure_validator(self.ops, self.build()), self.binary)
        self.assertEqual(len(self.calls), 1)
        self.assertIn('phone-plan', self.calls[0])
        self.assertIn('--disable-sandbox', self.calls[0])

    def test_a_change_to_either_package_rebuilds(self):
        oc.ensure_validator(self.ops, self.build())
        (self.ops / 'Packages/SessionKit/f.swift').write_text('changed')
        git(self.ops, 'commit', '-qam', 'sessionkit change')
        oc.ensure_validator(self.ops, self.build())
        self.assertEqual(len(self.calls), 2)

    def test_a_change_elsewhere_does_not_rebuild(self):
        oc.ensure_validator(self.ops, self.build())
        self.commit(self.ops, 'a.txt', 'unrelated')
        oc.ensure_validator(self.ops, self.build())
        self.assertEqual(len(self.calls), 1)

    def test_a_checkout_without_tree_ids_keeps_its_binary_instead_of_rebuilding_every_tick(self):
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text('binary')
        with mock.patch.object(oc, '_trees', return_value=''):
            oc.ensure_validator(self.ops, self.build())
        self.assertEqual(self.calls, [])

    def test_a_failed_rebuild_keeps_the_old_binary_but_a_first_failure_raises(self):
        with self.assertRaisesRegex(RuntimeError, 'could not be built.*boom'):
            oc.ensure_validator(self.ops, self.build(code=1))
        oc.ensure_validator(self.ops, self.build())
        (self.ops / 'Packages/SessionKitTools/f.swift').write_text('changed')
        git(self.ops, 'commit', '-qam', 'tools change')
        with mock.patch('sys.stderr'):
            self.assertEqual(oc.ensure_validator(self.ops, self.build(code=1)), self.binary)
        # the stamp was not advanced, so the next run tries again
        oc.ensure_validator(self.ops, self.build())
        self.assertEqual(len(self.calls), 4)


if __name__ == '__main__':
    unittest.main()
