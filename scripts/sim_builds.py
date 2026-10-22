#!/usr/bin/env python3
"""Ready-made simulator builds of the base branch's tip, kept so desks install instead of building.

Stdlib only, Python 3.9+. The integration run (ops/testdesk/sm_integration_run.py) calls store() after a
good simulator build of a tip. Only SpokenMarginsApp.app is copied, never DerivedData. The newest two
builds are kept, each in `<root>/<sha7>/` with a `build.json`, and `<root>/latest` points at the newest.
scripts/sim-build-latest reads them.

While the integration run is on a GitHub-hosted Mac (LANE_HOSTED_APP, #1389), it pack()s the app instead, and
hosted-integration.yml uploads it as the artifact `sim-app-<full sha>` for 2 days. fetch() downloads the newest
one (or one commit's) with gh and store()s it here, so desks still install instead of building.

Root: SM_SIM_BUILDS, else <ops home>/sim-builds (~/SpokenMarginsOps/sim-builds).
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
import re
import shutil
import subprocess
import time

from trunk import trunk_branch  # (#1492: older build records name no branch)
from typing import Callable, Optional
import zipfile

import sm_paths

APP_NAME = 'SpokenMarginsApp.app'
KEEP = 2
MIN_FREE_BYTES = 10 * 1024 ** 3      # ops/disk: no copy below 10 GB free
LATEST = 'latest'
SHA_RE = re.compile(r'[0-9a-f]{40}')
ARTIFACT_PREFIX = 'sim-app-'         # hosted-integration.yml: sim-app-<full sha>
PACKED_APP = APP_NAME + '.zip'       # ditto's zip inside the artifact: upload-artifact drops modes and symlinks
REPO = os.environ.get('SM_INTEGRATION_REPO', 'Spoken-Margins/spoken-margins-native')


def root() -> Path:
    setting = os.environ.get('SM_SIM_BUILDS', '').strip()
    return Path(os.path.expanduser(setting)) if setting else sm_paths.ops_home() / 'sim-builds'


def tree_bytes(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob('*') if f.is_file() and not f.is_symlink())


def builds(folder: Path) -> list[dict]:
    """Kept builds, newest first: {'sha', 'branch', 'built_at', 'size_bytes', 'app', 'dir'}."""
    found = []
    if not folder.is_dir():
        return found
    for entry in folder.iterdir():
        if entry.is_symlink() or not entry.is_dir() or entry.name.endswith('.partial'):
            continue
        try:
            record = json.loads((entry / 'build.json').read_text())
        except (OSError, ValueError):
            continue
        app = entry / APP_NAME
        if SHA_RE.fullmatch(record.get('sha', '')) and app.is_dir():
            found.append(dict(record, app=str(app), dir=str(entry)))
    return sorted(found, key=lambda b: b.get('built_at', 0), reverse=True)


def latest(folder: Path) -> Optional[dict]:
    kept = builds(folder)
    return kept[0] if kept else None


def find(folder: Path, sha: str) -> Optional[dict]:
    """The kept build of exactly this commit (a full SHA, or a prefix of at least 7)."""
    sha = sha.strip().lower()
    if not re.fullmatch(r'[0-9a-f]{7,40}', sha):
        return None
    return next((b for b in builds(folder) if b['sha'].startswith(sha)), None)


def store(app: Path, sha: str, branch: str, folder: Path, *, free_bytes: int,
          keep: int = KEEP, now: Optional[float] = None, built_by: Optional[str] = None) -> dict:
    """Copy one built .app in as `sha`'s build, point `latest` at it and drop all but the newest `keep`.

    Returns {'stored': bool, 'why' or the build record}. Never deletes the build it just stored."""
    if not SHA_RE.fullmatch(sha):
        return {'stored': False, 'why': f'not a full SHA: {sha!r}'}
    if not (app / 'Info.plist').is_file():
        return {'stored': False, 'why': f'no built app at {app}'}
    if free_bytes < MIN_FREE_BYTES:
        return {'stored': False, 'why': f'{free_bytes / 1024 ** 3:.1f} GB free, under the 10 GB floor'}
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / sha[:7]
    partial = folder / f'{sha[:7]}.partial'
    shutil.rmtree(partial, ignore_errors=True)
    partial.mkdir()
    # ditto keeps the bundle's symlinks, modes and extended attributes, so the signed app installs as built.
    subprocess.run(['ditto', str(app), str(partial / APP_NAME)], check=True, timeout=600,
                   stdin=subprocess.DEVNULL, capture_output=True)
    record = {'sha': sha, 'branch': branch, 'built_at': now if now is not None else time.time(),
              'size_bytes': tree_bytes(partial / APP_NAME)}
    if built_by:
        record['built_by'] = built_by
    (partial / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
    shutil.rmtree(target, ignore_errors=True)
    partial.rename(target)
    link = folder / f'{LATEST}.tmp'
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(target.name)
    link.replace(folder / LATEST)
    removed = []
    for old in builds(folder)[keep:]:
        if Path(old['dir']) != target:
            shutil.rmtree(old['dir'], ignore_errors=True)
            removed.append(old['sha'][:7])
    for stale in folder.glob('*.partial'):  # a copy cut off by a restart
        if stale != partial:
            shutil.rmtree(stale, ignore_errors=True)
    return dict(record, stored=True, app=str(target / APP_NAME), removed=removed)


def pack(app: Path, sha: str, branch: str, out: Path, *, built_by: str, now: Optional[float] = None) -> dict:
    """Zip one built .app with ditto into `out` (PACKED_APP plus build.json) for the hosted upload.

    ditto keeps the bundle's symlinks and modes, which upload-artifact's own zip loses."""
    if not SHA_RE.fullmatch(sha):
        return {'packed': False, 'why': f'not a full SHA: {sha!r}'}
    if not (app / 'Info.plist').is_file():
        return {'packed': False, 'why': f'no built app at {app}'}
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(out / PACKED_APP)], check=True,
                   timeout=900, stdin=subprocess.DEVNULL, capture_output=True)
    record = {'sha': sha, 'branch': branch, 'built_at': now if now is not None else time.time(),
              'size_bytes': tree_bytes(app), 'built_by': built_by}
    (out / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
    return dict(record, packed=True, zip_bytes=(out / PACKED_APP).stat().st_size)


def pick_artifact(artifacts: list[dict], sha: Optional[str] = None) -> Optional[dict]:
    """The newest unexpired `sim-app-<sha>` artifact, of exactly `sha` (full or a 7+ prefix) when given."""
    want = (sha or '').strip().lower()
    if sha is not None and not re.fullmatch(r'[0-9a-f]{7,40}', want):
        return None
    found = []
    for item in artifacts:
        name = item.get('name', '')
        art_sha = name[len(ARTIFACT_PREFIX):]
        if not name.startswith(ARTIFACT_PREFIX) or not SHA_RE.fullmatch(art_sha) or item.get('expired'):
            continue
        if want and not art_sha.startswith(want):
            continue
        found.append(dict(item, sha=art_sha))
    return max(found, key=lambda a: a.get('created_at', ''), default=None)


def unpack(artifact_zip: Path, folder: Path, *, free_bytes: int) -> dict:
    """store() the app inside one downloaded sim-app artifact. Reads only its two expected members."""
    with tempfile.TemporaryDirectory(prefix='sim-app-') as tmp:
        work = Path(tmp)
        with zipfile.ZipFile(artifact_zip) as outer:
            names = set(outer.namelist())
            if not {'build.json', PACKED_APP} <= names:
                return {'stored': False, 'why': f'the artifact holds {sorted(names)[:5]}, not {PACKED_APP}'}
            record = json.loads(outer.read('build.json'))
            sha = record.get('sha', '')
            if not SHA_RE.fullmatch(sha):
                return {'stored': False, 'why': f'the artifact names no full SHA: {sha!r}'}
            with outer.open(PACKED_APP) as src, (work / PACKED_APP).open('wb') as dst:
                shutil.copyfileobj(src, dst)
        subprocess.run(['ditto', '-x', '-k', str(work / PACKED_APP), str(work / 'app')], check=True,
                       timeout=900, stdin=subprocess.DEVNULL, capture_output=True)
        return store(work / 'app' / APP_NAME, sha, record.get('branch') or trunk_branch(), folder,
                     free_bytes=free_bytes, now=record.get('built_at'), built_by=record.get('built_by'))


Runner = Callable[..., subprocess.CompletedProcess]


def fetch(folder: Path, sha: Optional[str] = None, *, free_bytes: int, repo: str = REPO,
          run: Runner = subprocess.run) -> dict:
    """Download the newest hosted sim-app artifact (of exactly `sha` when given) and store() it.

    Returns {'stored': False, 'why'} when gh can't list or download one, or none is unexpired."""
    if free_bytes < MIN_FREE_BYTES:
        return {'stored': False, 'why': f'{free_bytes / 1024 ** 3:.1f} GB free, under the 10 GB floor'}
    query = f'repos/{repo}/actions/artifacts?per_page=100'
    if sha and SHA_RE.fullmatch(sha.strip().lower()):
        query += f'&name={ARTIFACT_PREFIX}{sha.strip().lower()}'
    listed = run(['gh', 'api', query], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    if listed.returncode:
        return {'stored': False, 'why': 'gh could not list artifacts: ' + (listed.stderr or '').strip()[:200]}
    try:
        artifacts = json.loads(listed.stdout).get('artifacts', [])
    except ValueError:
        return {'stored': False, 'why': 'gh returned no artifact list'}
    chosen = pick_artifact(artifacts, sha)
    if not chosen:
        return {'stored': False, 'why': 'no hosted build of ' + (f'commit {sha}' if sha else 'any commit')
                + ' in the last 2 days'}
    have = find(folder, chosen['sha'])
    if have:
        return dict(have, stored=True, artifact=chosen['name'], already=True)
    folder.mkdir(parents=True, exist_ok=True)
    download = folder / f'{chosen["sha"][:7]}.download.zip'
    try:
        with download.open('wb') as out:
            got = run(['gh', 'api', f'repos/{repo}/actions/artifacts/{chosen["id"]}/zip'], stdout=out,
                      stderr=subprocess.PIPE, timeout=1200, stdin=subprocess.DEVNULL)
        if got.returncode:
            return {'stored': False, 'why': f'gh could not download {chosen["name"]}'}
        return dict(unpack(download, folder, free_bytes=free_bytes), artifact=chosen['name'])
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        return {'stored': False, 'why': f'{chosen["name"]}: {str(error)[:200]}'}
    finally:
        download.unlink(missing_ok=True)
