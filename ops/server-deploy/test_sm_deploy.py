"""Host tests for the server deploy tool (#4866). Run: python3 -m unittest ops/server-deploy/test_sm_deploy.py"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import sm_deploy as d  # noqa: E402

SHA = 'a' * 40


class FakeGitHub:
    """Serves the compare, tree and raw URLs from tables. `files` is {repo path: bytes}."""

    def __init__(self, files, compare=None, truncated=False, extra_tree=()):
        self.files = files
        self.compare = compare or {'status': 'ahead', 'behind_by': 0}
        self.truncated = truncated
        self.extra_tree = list(extra_tree)
        self.urls = []

    def __call__(self, url, limit=d.MAX_FILE):
        self.urls.append(url)
        if '/compare/' in url:
            return json.dumps(self.compare).encode()
        if '/git/trees/' in url:
            tree = [{'path': p, 'type': 'blob'} for p in [*self.files, *self.extra_tree]]
            return json.dumps({'truncated': self.truncated, 'tree': tree}).encode()
        path = url.split(f'/{SHA}/', 1)[1]
        return self.files[path.replace('%20', ' ')]


class Systemctl:
    def __init__(self, enabled=()):
        self.enabled, self.calls = set(enabled), []

    def __call__(self, cmd, **_):
        self.calls.append(cmd[1:])
        out = ''
        if cmd[1] == 'is-enabled':
            out = 'enabled\n' if cmd[2] in self.enabled else 'disabled\n'
        return subprocess.CompletedProcess(cmd, 0, stdout=out, stderr='')


def table_files(target):
    spec = d.TARGETS[target]
    files = {src: f'content of {src}'.encode() for src, _dest, _mode in spec['files']}
    for src, _dest in spec['trees']:
        files[f'{src}/licenses/a.txt'] = b'licence'
        files[f'{src}/sources.json'] = b'{}'
    return files


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.logs = []
        self._log = d.log
        d.log = self.logs.append
        self.addCleanup(setattr, d, 'log', self._log)

    def deployer(self, files, systemctl=None, **kw):
        self.gh = FakeGitHub(files, **kw)
        self.sc = systemctl or Systemctl()
        return d.Deployer(get=self.gh, run=self.sc, root=self.root)


class ArgumentTests(unittest.TestCase):
    def test_accepts_target_and_sha(self):
        self.assertEqual(d.parse_args(['dial', SHA]), ('dial', SHA))

    def test_refuses_everything_else(self):
        for argv in ([], ['dial'], ['dial', SHA, 'x'], ['nope', SHA], ['dial', 'A' * 40], ['dial', 'a' * 39],
                     ['dial', 'a' * 41], ['dial', SHA[:-1] + ';'], ['--dry-run', SHA], ['dial', '../../etc/passwd'],
                     ['dial', SHA + '\n'], ['backstop', 'main'], ['-h']):
            with self.assertRaises(d.Refused, msg=argv):
                d.parse_args(argv)

    def test_main_returns_2_for_refused(self):
        self.assertEqual(d.main(['rm', '-rf']), 2)


class DeployTests(Base):
    def test_backstop_installs_files_and_modes(self):
        files = table_files('backstop')
        self.deployer(files).deploy('backstop', SHA)
        script = Path(self.root, 'opt/sm-dispatch/sm_dispatch_backstop.py')
        self.assertEqual(script.read_bytes(), files['ops/dispatch-backstop/sm_dispatch_backstop.py'])
        self.assertEqual(script.stat().st_mode & 0o777, 0o755)
        unit = Path(self.root, 'etc/systemd/system/sm-dispatch-backstop.timer')
        self.assertEqual(unit.stat().st_mode & 0o777, 0o644)

    def test_refuses_a_sha_that_is_not_on_main(self):
        for compare in ({'status': 'diverged', 'behind_by': 3}, {'status': 'behind', 'behind_by': 2},
                        {'status': 'ahead', 'behind_by': 1}, {'message': 'Not Found'}):
            dep = self.deployer(table_files('dial'), compare=compare)
            with self.assertRaises(d.Refused):
                dep.deploy('dial', SHA)
            self.assertFalse(Path(self.root, 'opt').exists())
            self.assertFalse([u for u in self.gh.urls if 'raw.githubusercontent' in u], 'fetched files before the main check')

    def test_identical_to_main_is_allowed(self):
        self.deployer(table_files('dial'), compare={'status': 'identical', 'behind_by': 0}).deploy('dial', SHA)

    def test_second_run_reports_unchanged_and_does_not_reload(self):
        files = table_files('bandwidth')
        self.deployer(files).deploy('bandwidth', SHA)
        sc = Systemctl(enabled=['sm-bandwidth.timer'])
        self.logs.clear()
        self.deployer(files, systemctl=sc).deploy('bandwidth', SHA)
        self.assertTrue(all(line.startswith('unchanged') or 'left as it was' in line or line.startswith('deployed')
                            for line in self.logs), self.logs)
        self.assertNotIn(['daemon-reload'], sc.calls)

    def test_changed_unit_reloads_and_restarts_only_an_enabled_timer(self):
        files = table_files('dial')
        sc = Systemctl(enabled=['sm-dial-gate.timer'])
        self.deployer(files, systemctl=sc).deploy('dial', SHA)
        self.assertIn(['daemon-reload'], sc.calls)
        self.assertIn(['restart', 'sm-dial-gate.timer'], sc.calls)

    def test_never_enables_or_starts_a_disabled_timer(self):
        sc = Systemctl()
        self.deployer(table_files('voice-catalog'), systemctl=sc).deploy('voice-catalog', SHA)
        verbs = {call[0] for call in sc.calls}
        self.assertEqual(verbs, {'daemon-reload', 'is-enabled'})

    def test_script_only_change_does_not_reload(self):
        files = table_files('dial')
        self.deployer(files).deploy('dial', SHA)
        files['ops/dial/dial_gate.py'] = b'new'
        sc = Systemctl(enabled=['sm-dial-gate.timer'])
        self.deployer(files, systemctl=sc).deploy('dial', SHA)
        self.assertNotIn(['daemon-reload'], sc.calls)
        self.assertEqual(Path(self.root, 'opt/sm-dial/dial_gate.py').read_bytes(), b'new')

    def test_a_failed_systemctl_fails_the_deploy(self):
        def failing(cmd, **_):
            return subprocess.CompletedProcess(cmd, 1 if cmd[1] == 'daemon-reload' else 0, stdout='', stderr='boom')
        with self.assertRaises(RuntimeError):
            self.deployer(table_files('dial'), systemctl=failing).deploy('dial', SHA)

    def test_a_failed_tree_swap_puts_the_old_tree_back(self):
        tree = Path(self.root, 'opt/sm-voice-catalog/Contracts/voice-models')
        tree.mkdir(parents=True)
        (tree / 'keep.txt').write_text('old')
        real = os.rename
        def flaky(src, dst):
            if str(src).endswith('.sm-deploy-new'):
                raise OSError('boom')
            return real(src, dst)
        os.rename = flaky
        self.addCleanup(setattr, os, 'rename', real)
        with self.assertRaises(OSError):
            self.deployer(table_files('voice-catalog')).deploy('voice-catalog', SHA)
        self.assertEqual((tree / 'keep.txt').read_text(), 'old')

    def test_a_failed_fetch_leaves_the_old_file(self):
        files = table_files('dial')
        self.deployer(files).deploy('dial', SHA)
        before = Path(self.root, 'opt/sm-dial/dial_gate.py').read_bytes()
        files2 = dict(files)
        files2['ops/dial/dial_gate.py'] = b'new'
        del files2['ops/dial/sm-dial-gate.timer']
        with self.assertRaises(KeyError):
            self.deployer(files2).deploy('dial', SHA)
        self.assertEqual(Path(self.root, 'opt/sm-dial/dial_gate.py').read_bytes(), before)

    def test_voice_catalog_tree_is_replaced_whole(self):
        files = table_files('voice-catalog')
        tree = Path(self.root, 'opt/sm-voice-catalog/Contracts/voice-models')
        tree.mkdir(parents=True)
        (tree / 'stale.txt').write_text('old')
        self.deployer(files).deploy('voice-catalog', SHA)
        self.assertFalse((tree / 'stale.txt').exists())
        self.assertEqual((tree / 'licenses/a.txt').read_bytes(), b'licence')
        self.assertEqual(sorted(p.name for p in tree.parent.iterdir()), ['voice-models'])

    def test_tree_with_dotdot_or_truncated_is_refused(self):
        files = table_files('voice-catalog')
        with self.assertRaises(d.Refused):
            self.deployer(files, extra_tree=['Contracts/voice-models/../../etc/x']).deploy('voice-catalog', SHA)
        with self.assertRaises(d.Refused):
            self.deployer(files, truncated=True).deploy('voice-catalog', SHA)
        self.assertFalse(Path(self.root, 'opt').exists())

    def test_other_folders_in_the_tree_are_ignored(self):
        files = table_files('voice-catalog')
        dep = self.deployer(files, extra_tree=['Contracts/voice-models-other/x', 'scripts/other.py'])
        paths = dep.tree_files(SHA, 'Contracts/voice-models')
        self.assertTrue(all(p.startswith('Contracts/voice-models/') for p in paths))


class ChangedTargetsTests(unittest.TestCase):
    def test_maps_files_to_targets(self):
        self.assertEqual(d.targets_for(['ops/dial/dial_gate.py']), ['dial'])
        self.assertEqual(d.targets_for(['Contracts/voice-models/licenses/x.txt', 'ops/bandwidth/sm-bandwidth.timer']),
                         ['bandwidth', 'voice-catalog'])
        self.assertEqual(d.targets_for(['README.md', 'ops/dial/README.md', 'ops/dial/deploy.sh']), [])


class RepoDriftTests(unittest.TestCase):
    """The table, the workflow's triggers and the older deploy.sh scripts must describe the same files."""

    def test_every_source_exists_and_matches_its_deploy_script(self):
        script_of = {'backstop': 'ops/dispatch-backstop/deploy.sh', 'dial': 'ops/dial/deploy.sh',
                     'bandwidth': 'ops/bandwidth/deploy.sh', 'voice-catalog': 'ops/voice-catalog/deploy.sh'}
        for name, spec in d.TARGETS.items():
            text = (REPO / script_of[name]).read_text()
            for src, dest, _mode in spec['files']:
                self.assertTrue((REPO / src).is_file(), src)
                folder = dest.rsplit('/', 1)[0]
                self.assertTrue(folder.startswith('/opt/') or folder == d.SYSTEMD, dest)
                self.assertIn(os.path.basename(dest), text, f'{dest} not in {script_of[name]}')
            for src, dest in spec['trees']:
                self.assertTrue((REPO / src).is_dir(), src)
                self.assertIn(dest.replace('/opt/sm-voice-catalog/', ''), text)

    def test_workflow_triggers_cover_every_source(self):
        workflow = (REPO / '.github/workflows/server-deploy.yml').read_text()
        paths = re.findall(r"^      - '([^']+)'$", workflow.split('workflow_dispatch:')[0], re.M)
        covered = set()
        for name, spec in d.TARGETS.items():
            for src, _dest, _mode in spec['files']:
                self.assertIn(src, paths, f'{src} would not trigger a deploy')
                covered.add(src)
            for src, _dest in spec['trees']:
                self.assertIn(src + '/**', paths)
                covered.add(src + '/**')
        self.assertEqual(sorted(paths), sorted(covered), 'a trigger path names no deploy source')
        options = re.search(r'options: \[all, ([^\]]+)\]', workflow).group(1).split(', ')
        self.assertEqual(options, list(d.TARGETS))
        self.assertIn('all="backstop dial bandwidth voice-catalog"', workflow)
        self.assertNotIn('compare/', workflow)

    def test_workflow_never_prints_the_key_and_uses_the_environment(self):
        workflow = (REPO / '.github/workflows/server-deploy.yml').read_text()
        self.assertIn('environment: server-deploy', workflow)
        self.assertNotIn('set -x', workflow)
        self.assertIn('StrictHostKeyChecking=yes', workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertNotIn('pull_request', workflow.split('permissions:')[0].split('on:')[1])

    def test_shell_files_parse_and_the_sudoers_line_is_exact(self):
        for name in ('sm-deploy-ssh', 'bootstrap-root.sh', 'install-on-server.sh'):
            subprocess.run(['sh', '-n', str(HERE / name)], check=True)
        self.assertEqual((HERE / 'sm-deploy.sudoers').read_text(), 'smci ALL=(root) NOPASSWD: /usr/local/sbin/sm-deploy\n')
        visudo = shutil.which('visudo')
        if visudo:
            result = subprocess.run([visudo, '-cf', str(HERE / 'sm-deploy.sudoers')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bootstrap_accepts_one_commented_key_line_and_refuses_more(self):
        check = (HERE / 'bootstrap-root.sh').read_text().splitlines()[7]
        self.assertIn('exactly one public key line', check)
        for text, ok in (('ssh-ed25519 AAAAC3Nza sm-deploy github-actions\n', True), ('ssh-ed25519 AAAAC3Nza\n', True),
                         ('ssh-ed25519 AAAA x\nssh-ed25519 BBBB y\n', False), ('command="x" ssh-ed25519 AAAA x\n', False),
                         ('', False)):
            with tempfile.TemporaryDirectory() as folder:
                Path(folder, 'deploy_key.pub').write_text(text)
                result = subprocess.run(['sh', '-c', check], env={'stage': folder, 'PATH': os.environ['PATH']},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, ok, text)

    def test_forced_command_script_passes_args_unglobbed(self):
        text = (HERE / 'sm-deploy-ssh').read_text()
        self.assertIn('set -f', text)
        self.assertIn('/usr/bin/sudo -n /usr/local/sbin/sm-deploy ${SSH_ORIGINAL_COMMAND:-}', text)


if __name__ == '__main__':
    unittest.main()
