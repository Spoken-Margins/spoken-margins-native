"""verify-tests.py --plan fast-portable (#1847): the fast plan's steps that need neither Swift nor an Apple tool.

The plan is for a hosted Linux job. What it must never do is quietly lose a step: every step the fast plan can
run is either in the portable plan or named, with its reason, as left out. The pointer check that lets the
contracts step run without Git LFS is tested here too.
"""
import ast
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verification = load('verification', 'verify-tests.py')
supertonic = load('validate_supertonic_assets', 'validate-supertonic-assets.py')

FAST_PLAN_METHODS = ('fast', 'portable', 'host_steps', 'package_steps', 'package_core', 'ops_steps')


def literal_steps():
    """The step names the fast plan's code gives to self.command(...) and self.skip(...) as string literals."""
    tree = ast.parse((SCRIPTS / 'verify-tests.py').read_text())
    run = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'Run')
    names = set()
    for method in run.body:
        if isinstance(method, ast.FunctionDef) and method.name in FAST_PLAN_METHODS:
            for call in ast.walk(method):
                if (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                        and call.func.attr in ('command', 'skip') and call.args
                        and isinstance(call.args[0], ast.Constant) and isinstance(call.args[0].value, str)):
                    names.add(call.args[0].value)
    return names


class PortableStepTable(unittest.TestCase):
    def test_every_step_the_fast_plan_names_is_run_or_left_out_with_a_reason(self):
        listed = set(verification.PORTABLE_STEPS) | set(verification.PORTABLE_LEFT_OUT)
        found = literal_steps()
        self.assertEqual(found - listed, set(), 'a fast-plan step the portable plan neither runs nor lists as left out')
        self.assertEqual(listed - found, set(), 'a listed step the fast plan no longer has')
        self.assertTrue(all(reason.strip() for reason in verification.PORTABLE_LEFT_OUT.values()))

    def test_the_left_out_tests_exist(self):
        for prefix in verification.PORTABLE_RUNNER_TESTS_LEFT_OUT:
            with self.subTest(prefix):
                module, _, rest = prefix.partition('.')
                text = (SCRIPTS / 'tests' / f'{module}.py').read_text()
                for part in [p for p in rest.split('.') if p]:
                    self.assertIn(part, text)
        for folder in verification.PORTABLE_OPS_LEFT_OUT:
            self.assertTrue(any((ROOT / folder).glob('test_*.py')), folder)

    def run_portable(self, plan='fast-portable'):
        calls, skipped, slots = [], [], []
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / 'node_modules').mkdir()
            run = verification.Run(Path(temporary) / 'run', plan)
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    patch.object(run, 'ops_steps', side_effect=lambda **kw: calls.append(('ops', kw))), \
                    patch.object(verification, 'ROOT', Path(temporary)), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    patch.object(verification, 'host_test_slot', side_effect=lambda *a, **k: slots.append(a)), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                run.fast()
            skipped = {step['name']: step['skipped'] for step in run.manifest['steps'] if 'skipped' in step}
        return calls, skipped, slots, printed.getvalue()

    def test_the_portable_plan_runs_its_steps_and_names_each_one_it_leaves_out(self):
        calls, skipped, slots, printed = self.run_portable()
        names = [name for name, _ in calls]
        self.assertEqual(names, ['runner-tests', 'ops', 'contracts', 'surfaces', 'inventory', 'browser', 'share-link',
                                 'research'])
        self.assertEqual(skipped, verification.PORTABLE_LEFT_OUT)
        for name in verification.PORTABLE_LEFT_OUT:
            self.assertIn(name, printed)
        self.assertEqual(slots, [], 'the Mac-wide host-test slot is not for a hosted job')

    def test_the_portable_plan_drops_the_apple_tests_and_checks_lfs_pointers(self):
        calls = dict(self.run_portable()[0])
        runner = calls['runner-tests']
        self.assertEqual(runner[:2], [sys.executable, '-c'])
        self.assertEqual(runner[3:], list(verification.PORTABLE_RUNNER_TESTS_LEFT_OUT))
        self.assertEqual(calls['ops'], {'left_out': verification.PORTABLE_OPS_LEFT_OUT})
        self.assertIn('--allow-lfs-pointers', calls['contracts'])

    def test_the_fast_plan_itself_is_unchanged(self):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / 'node_modules').mkdir()
            run = verification.Run(Path(temporary) / 'run', 'fast')
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    patch.object(run, 'ops_steps', side_effect=lambda *a, **kw: calls.append(('ops', (a, kw)))), \
                    patch.object(run, 'package_steps', side_effect=lambda expected: calls.append(('package-steps', None))), \
                    patch.object(verification, 'ROOT', Path(temporary)), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    patch.object(verification.sessionkit_pass, 'toolchain', return_value=None), \
                    patch.object(verification, 'host_test_slot', side_effect=lambda *a, **k: contextlib.nullcontext({})), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.fast()
        by_name = dict(calls)
        self.assertEqual(by_name['ops'], ((), {}))
        self.assertNotIn('--allow-lfs-pointers', by_name['contracts'])
        self.assertNotIn(verification.PORTABLE_RUNNER_LOADER, by_name['runner-tests'])
        self.assertIn('package-steps', by_name)

    def test_the_runner_loader_drops_only_the_listed_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            tests = Path(temporary) / 'scripts' / 'tests'
            tests.mkdir(parents=True)
            (tests / 'test_apple.py').write_text(
                'import unittest\nclass A(unittest.TestCase):\n    def test_needs_xcode(self): self.fail("xcode")\n')
            (tests / 'test_other.py').write_text(
                'import unittest\nclass B(unittest.TestCase):\n    def test_runs(self): pass\n'
                '    def test_needs_xcode_too(self): self.fail("xcode")\n')
            done = subprocess.run([sys.executable, '-c', verification.PORTABLE_RUNNER_LOADER,
                                   'test_apple.', 'test_other.B.test_needs_xcode_too'],
                                  cwd=temporary, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn('Ran 1 test', done.stderr)
            failing = subprocess.run([sys.executable, '-c', verification.PORTABLE_RUNNER_LOADER, 'test_apple.'],
                                     cwd=temporary, capture_output=True, text=True)
            self.assertNotEqual(failing.returncode, 0)  # a test that is not listed still fails the step


class LfsPointerCheck(unittest.TestCase):
    OID = 'ab' * 32

    def validate(self, files, allow):
        """(exit code, stdout, stderr) of the Supertonic check over a temporary asset folder."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entries = []
            for name, (content, bytes_, sha) in files.items():
                (root / name).write_bytes(content)
                entries.append({'path': name, 'bytes': bytes_, 'sha256': sha, 'provenance': 'p'})
            manifest = root / 'asset-manifest.json'
            manifest.write_text(json.dumps({
                'modelRevision': '3cadd1ee6394adea1bd021217a0e650ede09a323',
                'quantizedArchive': {'sha256': '82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427'},
                'provenance': {'p': {'source': 's', 'version': 'v'}}, 'files': entries}))
            out, err = io.StringIO(), io.StringIO()
            with patch.object(supertonic, 'ASSET_ROOT', root), patch.object(supertonic, 'MANIFEST_PATH', manifest), \
                    patch.object(sys, 'argv', ['validate-supertonic-assets.py'] + (['--allow-lfs-pointers'] if allow else [])), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = supertonic.main()
            return code, out.getvalue(), err.getvalue()

    def pointer(self, oid=None, size=1000):
        return f'version https://git-lfs.github.com/spec/v1\noid sha256:{oid or self.OID}\nsize {size}\n'.encode()

    def test_a_pointer_that_matches_the_manifest_passes_only_when_allowed(self):
        files = {'a.onnx': (self.pointer(), 1000, self.OID)}
        code, out, _ = self.validate(files, allow=True)
        self.assertEqual(code, 0)
        self.assertIn('1 checked as Git LFS pointers', out)
        code, _, err = self.validate(files, allow=False)
        self.assertEqual(code, 1)
        self.assertIn('size: a.onnx', err)  # the Mac's plan still insists on the real file

    def test_a_pointer_that_disagrees_with_the_manifest_fails(self):
        for name, content in (('wrong size', self.pointer(size=999)), ('wrong hash', self.pointer(oid='cd' * 32))):
            with self.subTest(name):
                code, _, err = self.validate({'a.onnx': (content, 1000, self.OID)}, allow=True)
                self.assertEqual(code, 1)
                self.assertIn('pointer ', err)

    def test_real_files_are_still_hashed_and_a_big_file_is_never_a_pointer(self):
        import hashlib
        body = b'real bytes'
        good = hashlib.sha256(body).hexdigest()
        self.assertEqual(self.validate({'a.onnx': (body, len(body), good)}, allow=True)[0], 0)
        code, _, err = self.validate({'a.onnx': (body, len(body), 'ef' * 32)}, allow=True)
        self.assertEqual(code, 1)
        self.assertIn('sha256: a.onnx', err)
        big = self.pointer() + b'x' * 2000      # starts like a pointer but is not one
        code, _, err = self.validate({'a.onnx': (big, 1000, self.OID)}, allow=True)
        self.assertEqual(code, 1)
        self.assertIn('size: a.onnx', err)


if __name__ == '__main__':
    unittest.main()
