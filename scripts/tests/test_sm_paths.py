"""scripts/sm_paths.py (#1844): the owner-only scripts find the public checkout through SM_REPO and their state
through SM_OPS_HOME, and with neither set they use exactly the paths they always did.

Two layers. The helper is checked as a table. Then every script the issue lists is imported in a fresh
interpreter with HOME, SM_REPO and SM_OPS_HOME pointing at temporary folders, and each path it resolved is
checked to sit inside them; the same imports, run from a copy laid out as the owner's Mac is
(~/SpokenMarginsOps/repo) with neither variable set, must give the paths the scripts had before.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import sm_paths  # noqa: E402


def checkout(path: Path, *, git=True) -> Path:
    path.mkdir(parents=True)
    if git:
        (path / '.git').mkdir()
    (path / 'scripts').mkdir()
    (path / 'scripts' / 'anchor.py').write_text('')
    return path


class HelperTable(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / 'home'

    def test_ops_home(self):
        rows = [
            ('unset', {}, self.home / 'SpokenMarginsOps'),
            ('empty', {'SM_OPS_HOME': ''}, self.home / 'SpokenMarginsOps'),
            ('blank', {'SM_OPS_HOME': '  '}, self.home / 'SpokenMarginsOps'),
            ('set', {'SM_OPS_HOME': str(self.tmp / 'ops-state')}, self.tmp / 'ops-state'),
        ]
        for name, env, expected in rows:
            with self.subTest(name):
                self.assertEqual(sm_paths.ops_home(env, home=self.home), expected)

    def test_tilde_in_a_setting_is_expanded(self):
        env = {'SM_OPS_HOME': '~/somewhere', 'HOME': str(self.home)}
        saved, os.environ['HOME'] = os.environ.get('HOME'), str(self.home)
        try:
            self.assertEqual(sm_paths.ops_home(env), self.home / 'somewhere')
            self.assertEqual(sm_paths.repo(self.tmp, env={'SM_REPO': '~/checkout'}), self.home / 'checkout')
        finally:
            if saved is None:
                del os.environ['HOME']
            else:
                os.environ['HOME'] = saved

    def test_state_dir_and_fallback(self):
        env = {'SM_OPS_HOME': str(self.tmp / 'o')}
        self.assertEqual(sm_paths.state_dir('disk-relief', env), self.tmp / 'o' / 'disk-relief')
        self.assertEqual(sm_paths.state_dir('disk-relief', {}, home=self.home),
                         self.home / 'SpokenMarginsOps' / 'disk-relief')
        self.assertEqual(sm_paths.state_dir_or('audit', self.tmp / 'in-repo', env), self.tmp / 'o' / 'audit')
        self.assertEqual(sm_paths.state_dir_or('audit', self.tmp / 'in-repo', {}), self.tmp / 'in-repo')

    def test_repo(self):
        mac = checkout(self.home / 'SpokenMarginsOps' / 'repo')               # today: scripts live in the checkout
        dev = checkout(self.home / 'Documents' / 'GitHub' / 'spoken-margins-native')
        worktree = checkout(self.tmp / 'work' / 'ws-1', git=False)
        (worktree / 'project.yml').write_text('')
        private = checkout(self.home / 'SpokenMarginsOps' / 'ops')            # after the move: ops beside repo
        elsewhere = self.tmp / 'elsewhere'
        elsewhere.mkdir()
        rows = [
            ('owner Mac today: the live ops copy is its own checkout', mac / 'scripts' / 'anchor.py', {}, None, mac),
            ('a development checkout', dev / 'scripts' / 'anchor.py', {}, None, dev),
            ('a worktree found by project.yml', worktree / 'scripts' / 'anchor.py', {}, None, worktree),
            ('after the move: the sibling repo folder', private / 'scripts' / 'anchor.py', {}, None, mac),
            ('SM_REPO beats the sibling', private / 'scripts' / 'anchor.py', {'SM_REPO': str(elsewhere)}, None, elsewhere),
            ('SM_REPO beats a default', dev / 'scripts' / 'anchor.py', {'SM_REPO': str(elsewhere)}, dev, elsewhere),
            ('a script whose default is another checkout', mac / 'scripts' / 'anchor.py', {}, dev, dev),
            ('an empty SM_REPO is unset', mac / 'scripts' / 'anchor.py', {'SM_REPO': ''}, None, mac),
            ('a sibling folder without .git is not a checkout',
             checkout(self.tmp / 'solo' / 'tools') / 'scripts' / 'anchor.py', {}, None, self.tmp / 'solo' / 'tools'),
        ]
        (self.tmp / 'solo' / 'repo').mkdir()
        for name, anchor, env, default, expected in rows:
            with self.subTest(name):
                self.assertEqual(sm_paths.repo(anchor, default=default, env=env), expected)

    def test_a_copied_script_outside_any_checkout_is_its_own_root(self):
        loose = self.tmp / 'loose'
        loose.mkdir()
        (loose / 'tool.py').write_text('')
        self.assertEqual(sm_paths.own_root(loose / 'tool.py'), loose)


class ShellSnippet(unittest.TestCase):
    def run_sh(self, env_extra, home):
        env = {'PATH': os.environ['PATH'], 'HOME': str(home), **env_extra}
        script = f'sm_paths_dir={SCRIPTS}; . "$sm_paths_dir/sm_paths.sh" && echo "$SM_REPO" && echo "$SM_OPS_HOME"'
        done = subprocess.run(['sh', '-c', script], env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.split('\n')[:2]

    def test_sets_both_settings_the_way_python_does(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp).resolve()
            self.assertEqual(self.run_sh({'SM_REPO': str(tmp / 'r'), 'SM_OPS_HOME': str(tmp / 'o')}, tmp),
                             [str(tmp / 'r'), str(tmp / 'o')])
            self.assertEqual(self.run_sh({}, tmp), [str(ROOT), str(tmp / 'SpokenMarginsOps')])

    def test_the_cli_agrees(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {'PATH': os.environ['PATH'], 'HOME': tmp, 'SM_OPS_HOME': str(Path(tmp) / 'o')}
            out = subprocess.run([sys.executable, str(SCRIPTS / 'sm_paths.py'), 'state', 'keep-awake'],
                                 env=env, capture_output=True, text=True, check=True).stdout.strip()
            self.assertEqual(out, str(Path(tmp) / 'o' / 'keep-awake'))


# Each script the issue lists: how to load it and which values show where it looks. Run in a fresh interpreter,
# because the scripts fix their paths when they are imported.
PROBE = textwrap.dedent('''
    import importlib.machinery, importlib.util, json, sys
    from pathlib import Path
    root = Path(sys.argv[1])
    out = {}

    def load(name, rel):
        path = root / rel
        sys.path.insert(0, str(path.parent))
        loader = importlib.machinery.SourceFileLoader(name, str(path))
        spec = importlib.util.spec_from_loader(name, loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        loader.exec_module(module)
        return module

    m = load('sm_claude_worker', 'ops/claude/sm_claude_worker.py')
    out['claude-worker'] = {'repo': m.REPO_ROOT, 'state': m.HOME_DIR, 'ledger': m.usage.DEFAULT_DIR}
    m = load('sm_codex_audit', 'ops/codex/sm_codex_audit.py')
    out['audit'] = {'repo': m.REPO_ROOT, 'state': m.OPS_DIR, 'log': m.LOG_PATH, 'lock': m.LOCK_PATH,
                    'failures': m.FAILURES_PATH, 'outputs': m.OUTPUT_KEEP_DIR}
    m = load('sm_disk_relief', 'ops/disk/sm_disk_relief.py')
    cfg = m.Config()
    out['disk-relief'] = {'repo': cfg.repo, 'glob': cfg.checkout_glob, 'state': cfg.ops_dir, 'log': cfg.log_file}
    m = load('sm_lane_power_guard', 'ops/lane/sm_lane_power_guard.py')
    out['power-guard'] = {'state': m.STATE_DIR, 'log': m.LOG, 'paused': m.PAUSED, 'lock': m.LOCK}
    m = load('sm_keep_awake', 'ops/power/sm_keep_awake.py')
    out['keep-awake'] = {'state': m.STATE_DIR}
    m = load('sm_integration_run', 'ops/testdesk/sm_integration_run.py')
    out['integration-run'] = {'repo': m.REPO_ROOT, 'state': m.HOME_DIR}
    m = load('phone_build', 'scripts/phone-build')
    out['phone-build'] = {'repo': m.ROOT, 'public': m.PUBLIC}
    m = load('daily_phone_plan', 'scripts/daily-phone-plan')
    out['daily-phone-plan'] = {'repo': m.phone.ROOT, 'public': m.phone.PUBLIC}
    m = load('sm_status', 'scripts/sm_status.py')
    out['status'] = {'public': m.PUBLIC}
    m = load('sm_sweep', 'scripts/sm_sweep.py')
    out['sweep'] = {'public': m.sm_status.PUBLIC}
    print(json.dumps({job: {k: str(v) for k, v in values.items()} for job, values in out.items()}))
''')

COPY_IGNORE = shutil.ignore_patterns('tests', 'fixtures', '__pycache__', 'test_*.py', '*.swift', 'build29-db-reader')


def probe(root: Path, home: Path, env_extra: dict) -> dict:
    env = {'PATH': os.environ['PATH'], 'HOME': str(home), **env_extra}
    done = subprocess.run([sys.executable, '-I', '-c', PROBE, str(root)], env=env, cwd=str(home),
                          capture_output=True, text=True)
    if done.returncode:
        raise AssertionError(done.stderr[-3000:])
    return json.loads(done.stdout.strip().splitlines()[-1])


def under(path: str, folder: Path) -> bool:
    try:
        Path(path).relative_to(folder)
        return True
    except ValueError:
        return False


class EveryListedScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp()).resolve()
        cls.home = cls.tmp / 'home'
        cls.home.mkdir()
        # The owner's Mac: the live ops copy at ~/SpokenMarginsOps/repo, which is its own checkout.
        cls.mac = cls.home / 'SpokenMarginsOps' / 'repo'
        cls.mac.mkdir(parents=True)
        (cls.mac / '.git').mkdir()
        for folder in ('ops', 'scripts'):
            shutil.copytree(ROOT / folder, cls.mac / folder, ignore=COPY_IGNORE)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_with_neither_setting_each_script_uses_the_paths_it_always_did(self):
        got = probe(self.mac, self.home, {})
        ops = self.home / 'SpokenMarginsOps'
        mac, dev = str(self.mac), str(self.home / 'Documents/GitHub/spoken-margins-native')
        expected = {
            'claude-worker': {'repo': mac, 'state': str(ops / 'claude-worker'), 'ledger': str(ops / 'ledger')},
            'audit': {'repo': mac, 'state': f'{mac}/artifacts/ops', 'log': f'{mac}/artifacts/ops/codex-audit.log',
                      'lock': f'{mac}/artifacts/ops/codex-audit.lock',
                      'failures': f'{mac}/artifacts/ops/codex-audit-failures.json',
                      'outputs': f'{mac}/artifacts/ops/codex-audit-outputs'},
            'disk-relief': {'repo': dev, 'glob': dev + '*', 'state': str(ops / 'disk-relief'),
                            'log': str(ops / 'disk-relief' / 'log.txt')},
            'power-guard': {'state': str(ops / 'lane-power-guard'), 'log': str(ops / 'lane-power-guard/log.txt'),
                            'paused': str(ops / 'lane-power-guard/paused'), 'lock': str(ops / 'lane-power-guard/lock')},
            'keep-awake': {'state': str(ops / 'keep-awake')},
            'integration-run': {'repo': mac, 'state': str(ops / 'integration-run')},
            'phone-build': {'repo': mac, 'public': mac},
            'daily-phone-plan': {'repo': mac, 'public': mac},
            'status': {'public': mac},
            'sweep': {'public': mac},
        }
        self.assertEqual(got, expected)

    def test_with_both_settings_nothing_resolves_outside_them(self):
        public, state = self.tmp / 'public-checkout', self.tmp / 'ops-state'
        public.mkdir()
        got = probe(self.mac, self.home, {'SM_REPO': str(public), 'SM_OPS_HOME': str(state)})
        stray = []
        for job, values in got.items():
            for key, value in values.items():
                if key in ('repo', 'public'):
                    ok = under(value, public)
                elif key == 'glob':
                    ok = value == str(public) + '*'
                else:
                    ok = under(value, state)
                if not ok:
                    stray.append(f'{job}.{key} = {value}')
        self.assertEqual(stray, [], 'paths that ignore SM_REPO / SM_OPS_HOME')

    def test_only_sm_repo_set_moves_the_checkout_and_leaves_the_state_alone(self):
        public = self.tmp / 'only-repo'
        public.mkdir()
        got = probe(self.mac, self.home, {'SM_REPO': str(public)})
        self.assertEqual(got['audit']['state'], f'{public}/artifacts/ops')       # the audit's files live in the checkout
        self.assertEqual(got['disk-relief']['state'], str(self.home / 'SpokenMarginsOps/disk-relief'))
        self.assertEqual(got['claude-worker']['repo'], str(public))

    def test_only_sm_ops_home_set_moves_the_state_and_leaves_the_checkout_alone(self):
        state = self.tmp / 'only-state'
        got = probe(self.mac, self.home, {'SM_OPS_HOME': str(state)})
        self.assertEqual(got['audit']['state'], str(state / 'codex-audit'))
        self.assertEqual(got['claude-worker']['state'], str(state / 'claude-worker'))
        self.assertEqual(got['claude-worker']['repo'], str(self.mac))


if __name__ == '__main__':
    unittest.main()
