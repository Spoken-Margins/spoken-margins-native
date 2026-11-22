#!/usr/bin/env python3
"""sm-deploy: install one of our named server tools from a commit that is on main (#4866).

Installed once, by hand, as /usr/local/sbin/sm-deploy (root-owned). The deploy workflow reaches it over a
forced-command SSH key for the `smci` user, and sudo lets `smci` run only this file. It takes exactly two
arguments, a target name and a 40-character commit sha:

    sm-deploy <target> <sha>

It refuses any sha that is not already an ancestor of main (or main itself), fetches only the files listed in
TARGETS from that commit on raw.githubusercontent.com, writes them to their fixed destinations, and reloads
systemd. It never enables a timer that is off and never touches a secret under /etc/sm-*. So a stolen key can
only re-install code that already merged into main, onto four fixed targets.

    sm_deploy.py --targets-for   reads changed file paths on stdin and prints the targets they affect (the workflow uses it)
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

REPO = 'Spoken-Margins/spoken-margins-native'
BRANCH = 'main'
LOCK = '/run/sm-deploy.lock'
LOG = '/var/log/sm-deploy.log'
MAX_FILE = 5 * 1024 * 1024
MAX_TREE_FILES = 500
SHA = re.compile(r'[0-9a-f]{40}')
SYSTEMD = '/etc/systemd/system'

# (source path in the repo, destination on the host, mode). `trees` are whole folders replaced as a unit.
# `timers` are only restarted when their unit changed and they are already enabled.
TARGETS = {
    'backstop': {
        'files': [
            ('ops/dispatch-backstop/sm_dispatch_backstop.py', '/opt/sm-dispatch/sm_dispatch_backstop.py', 0o755),
            ('ops/dispatch-backstop/sm-dispatch-backstop.service', f'{SYSTEMD}/sm-dispatch-backstop.service', 0o644),
            ('ops/dispatch-backstop/sm-dispatch-backstop.timer', f'{SYSTEMD}/sm-dispatch-backstop.timer', 0o644),
        ],
        'trees': [],
        'timers': ['sm-dispatch-backstop.timer'],
    },
    'dial': {
        'files': [
            ('ops/dial/dial_gate.py', '/opt/sm-dial/dial_gate.py', 0o755),
            ('ops/dial/sm-dial-gate.service', f'{SYSTEMD}/sm-dial-gate.service', 0o644),
            ('ops/dial/sm-dial-gate.timer', f'{SYSTEMD}/sm-dial-gate.timer', 0o644),
        ],
        'trees': [],
        'timers': ['sm-dial-gate.timer'],
    },
    'bandwidth': {
        'files': [
            ('ops/bandwidth/bandwidth_check.py', '/opt/sm-bandwidth/bandwidth_check.py', 0o755),
            ('ops/bandwidth/sm-bandwidth.service', f'{SYSTEMD}/sm-bandwidth.service', 0o644),
            ('ops/bandwidth/sm-bandwidth.timer', f'{SYSTEMD}/sm-bandwidth.timer', 0o644),
        ],
        'trees': [],
        'timers': ['sm-bandwidth.timer'],
    },
    'voice-catalog': {
        'files': [
            ('scripts/voice_catalog.py', '/opt/sm-voice-catalog/scripts/voice_catalog.py', 0o755),
            ('scripts/voice_catalog_tools.py', '/opt/sm-voice-catalog/scripts/voice_catalog_tools.py', 0o644),
            ('ops/voice-catalog/sm-voice-catalog.service', f'{SYSTEMD}/sm-voice-catalog.service', 0o644),
            ('ops/voice-catalog/sm-voice-catalog.timer', f'{SYSTEMD}/sm-voice-catalog.timer', 0o644),
        ],
        'trees': [('Contracts/voice-models', '/opt/sm-voice-catalog/Contracts/voice-models')],
        'timers': ['sm-voice-catalog.timer'],
    },
}


class Refused(Exception):
    """A request the tool will not act on. The message is shown to the caller."""


def parse_args(argv):
    if len(argv) != 2 or argv[0] not in TARGETS or not SHA.fullmatch(argv[1]):
        raise Refused('usage: sm-deploy <%s> <40-hex commit sha>' % '|'.join(TARGETS))
    return argv[0], argv[1]


def targets_for(paths):
    """The targets whose source files or folders contain any of `paths`, in table order."""
    paths = list(paths)
    found = []
    for name, spec in TARGETS.items():
        sources = [src for src, _dest, _mode in spec['files']]
        trees = [src for src, _dest in spec['trees']]
        if any(p in sources or any(p.startswith(t + '/') for t in trees) for p in paths):
            found.append(name)
    return found


def http_get(url, limit=MAX_FILE):
    request = urllib.request.Request(url, headers={'User-Agent': 'sm-deploy', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise Refused(f'{url} is larger than {limit} bytes')
    return data


def log(message):
    print(message, flush=True)
    try:
        with open(LOG, 'a') as handle:
            handle.write(message + '\n')
    except OSError:
        pass


class Deployer:
    def __init__(self, get=http_get, run=subprocess.run, root='/'):
        self.get, self.run, self.root = get, run, root

    def dest(self, path):
        return os.path.join(self.root, path.lstrip('/'))

    def api(self, path):
        return json.loads(self.get(f'https://api.github.com/repos/{REPO}/{path}'))

    def raw(self, sha, path):
        return self.get(f'https://raw.githubusercontent.com/{REPO}/{sha}/{urllib.parse.quote(path)}')

    def require_on_main(self, sha):
        compare = self.api(f'compare/{sha}...{BRANCH}')
        if compare.get('status') not in ('ahead', 'identical') or compare.get('behind_by') != 0:
            raise Refused(f'{sha} is not on {BRANCH}')

    def tree_files(self, sha, folder):
        tree = self.api(f'git/trees/{sha}?recursive=1')
        if tree.get('truncated'):
            raise Refused('the commit tree was too large to list')
        paths = [e['path'] for e in tree['tree'] if e['type'] == 'blob' and e['path'].startswith(folder + '/')]
        if not paths or len(paths) > MAX_TREE_FILES:
            raise Refused(f'{folder}: {len(paths)} files, expected 1 to {MAX_TREE_FILES}')
        for p in paths:
            parts = p.split('/')
            if '..' in parts or '' in parts:
                raise Refused(f'unsafe path in the tree: {p}')
        return paths

    def write(self, dest, data, mode):
        """Atomic replace. Returns True when the content or mode changed."""
        dest = self.dest(dest)
        try:
            with open(dest, 'rb') as handle:
                same = handle.read() == data and (os.stat(dest).st_mode & 0o777) == mode
        except OSError:
            same = False
        if same:
            return False
        os.makedirs(os.path.dirname(dest), mode=0o755, exist_ok=True)
        temp = dest + '.sm-deploy-new'
        with open(temp, 'wb') as handle:
            handle.write(data)
        os.chmod(temp, mode)
        os.replace(temp, dest)
        return True

    def replace_tree(self, files, dest):
        """files: {relative path: bytes}. Swaps the whole folder; returns True when anything differs."""
        dest = self.dest(dest)
        current = {}
        if os.path.isdir(dest):
            for base, _dirs, names in os.walk(dest):
                for name in names:
                    full = os.path.join(base, name)
                    with open(full, 'rb') as handle:
                        current[os.path.relpath(full, dest)] = handle.read()
        if current == files:
            return False
        new, old = dest + '.sm-deploy-new', dest + '.sm-deploy-old'
        for leftover in (new, old):
            if os.path.islink(leftover):
                os.unlink(leftover)
            else:
                shutil.rmtree(leftover, ignore_errors=True)
        for rel, data in files.items():
            target = os.path.join(new, rel)
            os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
            with open(target, 'wb') as handle:
                handle.write(data)
            os.chmod(target, 0o644)
        if os.path.isdir(dest):
            os.rename(dest, old)
        try:
            os.rename(new, dest)
        except OSError:
            if os.path.isdir(old):
                os.rename(old, dest)
            raise
        shutil.rmtree(old, ignore_errors=True)
        return True

    def systemctl(self, *args, check=False):
        result = self.run(['/usr/bin/systemctl', *args], capture_output=True, text=True)
        if check and result.returncode != 0:
            raise RuntimeError(f'systemctl {" ".join(args)} failed: {(result.stderr or result.stdout).strip()}')
        return result

    def deploy(self, target, sha):
        spec = TARGETS[target]
        self.require_on_main(sha)
        fetched = [(dest, self.raw(sha, src), mode) for src, dest, mode in spec['files']]
        trees = []
        for src, dest in spec['trees']:
            trees.append((dest, {p[len(src) + 1:]: self.raw(sha, p) for p in self.tree_files(sha, src)}))
        changed_units = set()
        for dest, data, mode in fetched:
            did = self.write(dest, data, mode)
            log(f'{"changed  " if did else "unchanged"} {dest}')
            if did and dest.startswith(SYSTEMD + '/'):
                changed_units.add(os.path.basename(dest))
        for dest, files in trees:
            did = self.replace_tree(files, dest)
            log(f'{"changed  " if did else "unchanged"} {dest} ({len(files)} files)')
        if changed_units:
            self.systemctl('daemon-reload', check=True)
        for timer in spec['timers']:
            state = self.systemctl('is-enabled', timer).stdout.strip()
            if state == 'enabled' and timer in changed_units:
                self.systemctl('restart', timer, check=True)
                log(f'restarted {timer}')
            else:
                log(f'{timer}: {state or "not installed"}, left as it was')
        log(f'deployed {target} at {sha[:7]}')


def main(argv):
    if argv == ['--targets-for']:
        print('\n'.join(targets_for(line.strip() for line in sys.stdin if line.strip())))
        return 0
    try:
        target, sha = parse_args(argv)
        lock = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            Deployer().deploy(target, sha)
        finally:
            os.close(lock)
    except Refused as error:
        print(f'sm-deploy: {error}', file=sys.stderr)
        return 2
    except Exception as error:  # a network or filesystem failure is a failed deploy, shown to the workflow
        print(f'sm-deploy: failed: {error!r}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
