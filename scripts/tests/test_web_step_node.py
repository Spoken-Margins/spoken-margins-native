"""verify-tests.py's web step runs on a Node that meets .nvmrc, not whatever PATH holds first (#3006).

The Mac lane runners' PATH starts with Node 20. There `node --test 'Web/src/**/*.test.ts'` reads the glob as a file
name, prints "Could not find", runs nothing, and the zero-tests guard failed every PR's Mac host tests.
These tests use stand-in `node` scripts, so they run the same on the Mac and on a hosted Linux job.
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

spec = importlib.util.spec_from_file_location('verification_for_web_node', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)

# What Node 20 printed on the runners (log of PR #2986's lane run), and what Node 24 prints for a passing suite.
OLD_NODE = "echo \"Could not find '$PWD/Web/src/**/*.test.ts'\"; exit 1"
NEW_NODE = 'echo "ℹ tests 3"; echo "ℹ pass 3"'


def fake_node(folder, version, body=''):
    """A `node` that answers --version with `version` and otherwise runs `body`."""
    folder.mkdir(parents=True, exist_ok=True)
    node = folder / 'node'
    node.write_text(f'#!/bin/sh\nif [ "$1" = "--version" ]; then echo {version}; exit 0; fi\n{body}\n')
    node.chmod(0o755)
    return folder


class Machine:
    """A temporary checkout with an .nvmrc, a PATH folder and an nvm folder."""

    def __init__(self, temporary, nvmrc='24'):
        self.root = Path(temporary) / 'checkout'
        self.root.mkdir()
        (self.root / '.nvmrc').write_text(nvmrc + '\n')
        self.path = Path(temporary) / 'path-bin'
        self.path.mkdir()
        self.nvm = Path(temporary) / 'nvm'
        (self.nvm / 'versions/node').mkdir(parents=True)
        self.home = Path(temporary) / 'home'
        self.home.mkdir()

    def nvm_node(self, version, body=''):
        return fake_node(self.nvm / 'versions/node' / version / 'bin', version, body)

    def environ(self, nvm_dir=True):
        environ = {'PATH': f'{self.path}{os.pathsep}/usr/bin{os.pathsep}/bin', 'HOME': str(self.home)}
        if nvm_dir:
            environ['NVM_DIR'] = str(self.nvm)
        return environ

    def pick(self, **kw):
        return verification.node_for_nvmrc(self.root, self.environ(**kw))


class NodeForNvmrc(unittest.TestCase):
    def test_table(self):
        rows = [
            # (case, PATH node or None, nvm versions, the folder expected: 'path', a version, or None for an error)
            ('the Mac runners: Node 20 first, 24 in nvm (#3006)', 'v20.19.0', ['v18.20.5', 'v20.19.4', 'v24.22.1'], 'v24.22.1'),
            ('hosted Linux: setup-node puts 24 on PATH', 'v24.11.0', [], 'path'),
            ('a newer major on PATH is new enough', 'v25.0.0', ['v24.22.1'], 'path'),
            ("nvm's newest of the named major", 'v20.19.0', ['v24.1.0', 'v24.22.1', 'v24.3.0'], 'v24.22.1'),
            ('the named major before a newer one', 'v20.19.0', ['v26.0.0', 'v24.22.1'], 'v24.22.1'),
            ('a newer major when the named one is missing', 'v20.19.0', ['v26.0.0'], 'v26.0.0'),
            ('no node on PATH at all', None, ['v24.22.1'], 'v24.22.1'),
            ('Node 22 on PATH is still too old', 'v22.6.0', ['v24.22.1'], 'v24.22.1'),
            ('nothing new enough anywhere', 'v20.19.0', ['v18.20.5', 'v20.19.4'], None),
            ('nothing installed', None, [], None),
        ]
        for case, on_path, installed, expected in rows:
            with self.subTest(case), tempfile.TemporaryDirectory() as temporary:
                machine = Machine(temporary)
                if on_path:
                    fake_node(machine.path, on_path)
                for version in installed:
                    machine.nvm_node(version)
                if expected is None:
                    with self.assertRaises(RuntimeError) as raised:
                        machine.pick()
                    self.assertIn('Node 24 or later is needed', str(raised.exception))
                    self.assertIn('nvm install 24', str(raised.exception))
                else:
                    want = machine.path if expected == 'path' else machine.nvm / 'versions/node' / expected / 'bin'
                    self.assertEqual(machine.pick(), want)

    def test_nvm_dir_defaults_to_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            machine = Machine(temporary)
            fake_node(machine.path, 'v20.19.0')
            want = fake_node(machine.home / '.nvm/versions/node/v24.22.1/bin', 'v24.22.1')
            self.assertEqual(machine.pick(nvm_dir=False), want)

    def test_nvmrc_with_a_v_and_a_full_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            machine = Machine(temporary, nvmrc='v24.1.0')
            fake_node(machine.path, 'v24.0.0')
            self.assertEqual(machine.pick(), machine.path)


class WebStep(unittest.TestCase):
    def run_web(self, machine, environ, node):
        """Run the step as the fast plan does, in the temporary checkout; return the error or None, and the entry."""
        run = verification.Run(machine.root / f'run-{node}', 'fast')
        with patch.object(verification, 'ROOT', machine.root), patch.dict(os.environ, environ, clear=True), \
                contextlib.redirect_stdout(io.StringIO()):
            try:
                run.command('web', ['node', '--test', 'Web/src/**/*.test.ts'], node=node)
                error = None
            except RuntimeError as failed:
                error = str(failed)
        return error, run.manifest['steps'][-1]

    def test_the_web_step_runs_on_nvms_node_when_path_has_node_20(self):
        with tempfile.TemporaryDirectory() as temporary:
            machine = Machine(temporary)
            fake_node(machine.path, 'v20.19.0', OLD_NODE)
            folder = machine.nvm_node('v24.22.1', NEW_NODE)
            error, entry = self.run_web(machine, machine.environ(), node=True)
            self.assertIsNone(error)
            self.assertEqual(entry['executed_count'], 3)
            self.assertEqual(entry['node'], str(folder))
            # The stand-in for what the step did before #3006: PATH's Node 20, zero tests, a failed step.
            error, _ = self.run_web(machine, machine.environ(), node=False)
            self.assertIn('web executed zero tests', error)

    def test_the_web_step_fails_plainly_when_no_node_is_new_enough(self):
        with tempfile.TemporaryDirectory() as temporary:
            machine = Machine(temporary)
            fake_node(machine.path, 'v20.19.0', OLD_NODE)
            error, entry = self.run_web(machine, machine.environ(), node=True)
            self.assertIn('Node 24 or later is needed', error)
            self.assertIn('the web step did not run', error)
            self.assertEqual(entry['errors'], [error.removesuffix(' (the web step did not run)')])

    def test_the_fast_plan_asks_for_the_nvmrc_node_for_the_web_step(self):
        calls = {}
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / 'node_modules').mkdir()
            run = verification.Run(Path(temporary) / 'run', 'fast-portable')
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.setdefault(name, kw)), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification, 'ROOT', Path(temporary)), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']), \
                    contextlib.redirect_stdout(io.StringIO()):
                run.fast()
        self.assertTrue(calls['web'].get('node'))

    def test_the_repo_nvmrc_names_a_node_new_enough_for_the_web_suite(self):
        # 23.6 is the first Node that strips TypeScript types by default; 22.6 the first with `--test` globs.
        self.assertGreaterEqual(int((ROOT / '.nvmrc').read_text().strip().lstrip('v').split('.')[0]), 24)


if __name__ == '__main__':
    unittest.main()
