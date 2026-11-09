#!/usr/bin/env python3
"""What is live right now, read from the things themselves (#3872). Stdlib, Python 3.9+. Read-only.

Owner, 2026-11-09: comments "shouldn't necessarily be used for finding out what is true about this project." Run this
before telling him what is deployed, uploaded or switched on:

  scripts/sm_live.py                         builds, site pages, web app, server
  scripts/sm_live.py --section builds        only that part (builds, site, web, server; repeatable)
  scripts/sm_live.py --json                  the same facts for scripts
  scripts/sm_live.py --tag-message ARCHIVE   the message for a build's upload tag, read from the archive
  scripts/sm_live.py --write-asc FILE        (hosted job only) save App Store Connect's view of the builds

Every line names its source and when it was read. A fact that can't be read prints `unknown` and why. It never falls
back on a comment, and neither should you: `unknown` is the answer until something can read it.

Where each fact comes from:
  builds   The `testflight/*` upload tags: commit and flags. New tags carry a `flags:` line read from the archive; older
           ones have only a sentence someone typed, and say so. App Store Connect, through the `live-state` workflow's
           artifact because only that workflow holds the key: which kind of tester group has the build.
  site     Each `Site/**/index.html` on `origin/main`, fetched from spokenmargins.com and compared byte for byte, and
           `deploy.json`, written by scripts/deploy-spoken-margins-site.sh.
  web      `deploy.json`, written by research/B4/deploy/deploy-web.sh.
  server   `/api/v1/health`, whose `commit` comes from research/B4/deploy/deploy.sh.
"""
import argparse
import base64
import datetime as dt
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_gate  # noqa: E402

REPO = os.environ.get('GITHUB_REPOSITORY') or 'Spoken-Margins/spoken-margins-native'
SITE = 'https://spokenmargins.com'
WEB = 'https://app.spokenmargins.com'
BUNDLE_ID = 'com.spokenmargins.native'
ASC_API = 'https://api.appstoreconnect.apple.com'
ASC_ARTIFACT = 'asc-builds'
ASC_FILE = 'asc-builds.json'
TRUNK = os.environ.get('SM_TRUNK') or 'main'
BUILDS_SHOWN = 4
ASC_STALE_HOURS = 13    # the workflow runs every 6 hours, so two misses in a row
TIMEOUT = 20
FEATURE_NAMES = {'SMShareLinkCreation': 'share links'}
SECTIONS = ('builds', 'site', 'web', 'server')


class ReadError(Exception):
    """A fact could not be read. The message is shown to the reader, so it never carries a secret."""


class World:
    """Everything this script reads from outside. Tests replace it."""

    def __init__(self):
        self.now = dt.datetime.now(dt.timezone.utc)

    def gh(self, path):
        try:
            done = subprocess.run(['gh', 'api', path], capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReadError(f'gh could not run ({type(error).__name__})') from error
        if done.returncode:
            raise ReadError(f'gh api {path.split("?")[0]} failed: {done.stderr.decode(errors="replace").strip()[:120]}')
        return done.stdout

    def fetch(self, url):
        request = urllib.request.Request(url, headers={'User-Agent': 'spoken-margins-live-check'})
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as reply:
                return reply.status, dict(reply.headers), reply.read()
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers), b''
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise ReadError(f'could not reach {urllib.parse.urlsplit(url).hostname} ({error})') from error

    def git(self, *args):
        try:
            done = subprocess.run(['git', *args], capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReadError(f'git could not run ({type(error).__name__})') from error
        if done.returncode:
            raise ReadError(f'git {args[0]} failed: {done.stderr.decode(errors="replace").strip()[:120]}')
        return done.stdout


def stamp(moment):
    return moment.strftime('%Y-%m-%d %H:%M UTC')


def parse_time(text):
    return dt.datetime.fromisoformat(text.replace('Z', '+00:00'))


def unknown(why):
    return {'unknown': why}


# ---- Builds -----------------------------------------------------------------------------------------------------

def flags_from_message(message):
    """(flags, how), or (None, None). `flags:` lines come from the archive; the older sentence was typed by a person."""
    line = re.search(r'^flags:[ \t]*(.*)$', message or '', re.M)
    if line:
        pairs = re.findall(r'([A-Za-z][A-Za-z0-9_]*)=(YES|NO)\b', line.group(1))
        return {name: value == 'YES' for name, value in pairs}, 'read from the archive'
    typed = re.search(r'SM_SHARE_LINK_CREATION=(YES|NO)\b', message or '')
    if typed:
        return {'SMShareLinkCreation': typed.group(1) == 'YES'}, 'typed in the tag'
    typed = re.search(r'share[- ]link creation (on|off)\b', message or '', re.I)
    if typed:
        return {'SMShareLinkCreation': typed.group(1).lower() == 'on'}, 'typed in the tag'
    return None, None


def build_tags(world):
    refs = json.loads(world.gh(f'repos/{REPO}/git/matching-refs/tags/testflight/'))
    found = []
    for ref in refs:
        number = re.search(r'build-(\d+)$', ref.get('ref', ''))
        if number:
            found.append((int(number.group(1)), ref['object']))
    return sorted(found, key=lambda pair: pair[0], reverse=True)


def artifact_is_ours(artifact, branch=TRUNK):
    """Only a run of our own trunk counts: a fork's or a branch's workflow can upload an artifact with this name."""
    run = artifact.get('workflow_run') or {}
    return (not artifact.get('expired') and run.get('head_branch') == branch
            and run.get('repository_id') is not None and run.get('repository_id') == run.get('head_repository_id'))


def asc_reading(world):
    """App Store Connect's view, from the newest artifact of the `live-state` workflow, with its age."""
    listing = json.loads(world.gh(f'repos/{REPO}/actions/artifacts?name={ASC_ARTIFACT}&per_page=30'))
    ours = [a for a in listing.get('artifacts', []) if artifact_is_ours(a)]
    if not ours:
        raise ReadError('the live-state workflow has no reading yet')
    newest = max(ours, key=lambda a: a['created_at'])
    try:
        archive = zipfile.ZipFile(io.BytesIO(world.gh(newest['archive_download_url'].split('api.github.com/')[-1])))
        data = json.loads(archive.read(ASC_FILE))
    except (zipfile.BadZipFile, KeyError, ValueError) as error:
        raise ReadError(f'the App Store Connect reading is unreadable ({type(error).__name__})') from error
    return data, parse_time(data.get('read_at') or newest['created_at'])


def testers_of(entry):
    """In words, from App Store Connect's counts."""
    if entry is None:
        return 'not among the latest builds App Store Connect listed'
    if entry.get('expired'):
        return 'expired'
    kinds = [kind for kind, count in (('internal', entry.get('internal_groups')), ('external', entry.get('external_groups')))
             if count]
    who = ' and '.join(kinds) + ' testers' if kinds else 'in no tester group'
    state = entry.get('external_state') if entry.get('external_groups') else entry.get('internal_state')
    return f'{who} ({state})' if state else who


def builds(world):
    """Newest uploads first, or an `unknown` for the whole section."""
    try:
        tags = build_tags(world)
    except (ReadError, ValueError, KeyError, TypeError) as error:
        return unknown(f'could not list the upload tags: {error}')
    try:
        reading, read_at = asc_reading(world)
        by_build = {str(entry.get('build')): entry for entry in reading.get('builds', [])}
        hours = (world.now - read_at).total_seconds() / 3600
        testers_failed = None
    except (ReadError, ValueError, KeyError, TypeError) as error:
        by_build, read_at, hours = {}, None, None
        testers_failed = str(error)
    rows = []
    for number, target in tags[:BUILDS_SHOWN]:
        row = {'build': number, 'tag': f'testflight/0.1-build-{number}', 'commit': None, 'flags': None, 'flags_source': None}
        if target.get('type') == 'tag':
            try:
                tag = json.loads(world.gh(f'repos/{REPO}/git/tags/{target["sha"]}'))
                row['commit'] = tag['object']['sha'][:7]
                row['flags'], row['flags_source'] = flags_from_message(tag.get('message'))
            except (ReadError, ValueError, KeyError, TypeError) as error:
                row['flags_unknown'] = f'could not read the tag: {error}'
        else:
            row['commit'] = target.get('sha', '')[:7] or None
        if row['flags'] is None:
            row.setdefault('flags_unknown', 'the tag does not record them')
        if testers_failed:
            row['testers'] = unknown(testers_failed)
        else:
            row['testers'] = {'value': testers_of(by_build.get(str(number))), 'read_at': stamp(read_at),
                              'hours_old': round(hours, 1), 'stale': hours > ASC_STALE_HOURS}
        rows.append(row)
    return {'rows': rows, 'source': 'upload tags; App Store Connect through the live-state workflow'}


def tag_message(archive):
    """The upload tag's message: every `SM…` YES or NO setting in the archive's Info.plist. sm_live reads this back."""
    plist = release_gate.read_plist(Path(archive))
    flags = sorted((k, v) for k, v in plist.items() if k.startswith('SM') and v in ('YES', 'NO'))
    return (f'Build {plist.get("CFBundleVersion", "?")} ({plist.get("CFBundleShortVersionString", "?")}): TestFlight upload\n\n'
            'flags: ' + ' '.join(f'{k}={v}' for k, v in flags) + '\n')


# ---- App Store Connect (the hosted job only) ---------------------------------------------------------------------

def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode()


def der_to_raw(der):
    """openssl's ES256 signature is DER: SEQUENCE { INTEGER r, INTEGER s }. A JWT wants r and s as 32 bytes each."""
    try:
        if der[0] != 0x30:
            raise ValueError('not a sequence')
        at = 3 if der[1] == 0x81 else 2
        parts = []
        for _ in range(2):
            if der[at] != 0x02:
                raise ValueError('not an integer')
            size = der[at + 1]
            parts.append(der[at + 2:at + 2 + size])
            at += 2 + size
        if any(len(part.lstrip(b'\0')) > 32 for part in parts):
            raise ValueError('integer too long')
    except (IndexError, ValueError) as error:
        raise ReadError(f'openssl gave an unexpected signature ({error})') from error
    return b''.join(part.lstrip(b'\0').rjust(32, b'\0') for part in parts)


def asc_token(key_id, issuer, pem, now):
    header = _b64(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}).encode())
    issued = int(now.timestamp())
    claims = _b64(json.dumps({'iss': issuer, 'iat': issued, 'exp': issued + 600, 'aud': 'appstoreconnect-v1'}).encode())
    message = f'{header}.{claims}'
    with tempfile.NamedTemporaryFile('w', suffix='.p8') as key:    # created 0600
        key.write(pem if pem.endswith('\n') else pem + '\n')
        key.flush()
        done = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key.name], input=message.encode(),
                              capture_output=True, timeout=30)
    if done.returncode:
        raise ReadError('openssl could not sign with the key')    # its stderr is not repeated, in case it quotes the key
    return f'{message}.{_b64(der_to_raw(done.stdout))}'


def asc_get(path, token):
    request = urllib.request.Request(ASC_API + path, headers={'Authorization': f'Bearer {token}'})
    try:
        with urllib.request.urlopen(request, timeout=60) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as error:
        raise ReadError(f'App Store Connect answered {error.code} for {path.split("?")[0]}') from error
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise ReadError(f'could not read App Store Connect ({type(error).__name__})') from error


def asc_summary(document, now):
    """Build numbers and counts only. Group names and testers stay out: this lands in a public artifact (AGENTS.md)."""
    included = {(item['type'], item['id']): item for item in document.get('included', [])}

    def related(build, name):
        data = (build.get('relationships', {}).get(name) or {}).get('data')
        if data is None:
            return []
        return [included[(d['type'], d['id'])] for d in ([data] if isinstance(data, dict) else data)
                if (d['type'], d['id']) in included]

    rows = []
    for build in document.get('data', []):
        attributes = build.get('attributes', {})
        groups = [g.get('attributes', {}) for g in related(build, 'betaGroups')]
        detail = (related(build, 'buildBetaDetail') or [{}])[0].get('attributes', {})
        version = (related(build, 'preReleaseVersion') or [{}])[0].get('attributes', {}).get('version')
        rows.append({'build': attributes.get('version'), 'version': version, 'uploaded': attributes.get('uploadedDate'),
                     'processing': attributes.get('processingState'), 'expired': bool(attributes.get('expired')),
                     'internal_groups': sum(1 for g in groups if g.get('isInternalGroup')),
                     'external_groups': sum(1 for g in groups if not g.get('isInternalGroup')),
                     'internal_state': detail.get('internalBuildState'), 'external_state': detail.get('externalBuildState')})
    return {'read_at': now.strftime('%Y-%m-%dT%H:%M:%SZ'), 'builds': rows}


def write_asc(path, now):
    missing = [name for name in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8') if not os.environ.get(name)]
    if missing:
        raise ReadError('missing ' + ', '.join(missing))
    token = asc_token(os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID'], os.environ['ASC_KEY_P8'], now)
    # Apple's filter is looser than an exact match: it returned a second app on this job's first real run.
    apps = asc_get(f'/v1/apps?filter%5BbundleId%5D={BUNDLE_ID}&limit=200', token).get('data', [])
    apps = [app for app in apps if app.get('attributes', {}).get('bundleId') == BUNDLE_ID]
    if len(apps) != 1:
        raise ReadError(f'expected one app for {BUNDLE_ID}, found {len(apps)}')
    document = asc_get(f'/v1/builds?filter%5Bapp%5D={apps[0]["id"]}&sort=-uploadedDate&limit=10'
                       '&include=betaGroups,buildBetaDetail,preReleaseVersion', token)
    Path(path).write_text(json.dumps(asc_summary(document, now), indent=1) + '\n')


# ---- Site, web app, server --------------------------------------------------------------------------------------

def page_url(path):
    return SITE + '/' + path[len('Site/'):-len('index.html')]


def deploy_stamp(world, origin):
    """The `deploy.json` a deploy script wrote at this origin, or an `unknown`."""
    url = f'{origin}/deploy.json'
    try:
        code, _, body = world.fetch(url)
    except ReadError as error:
        return unknown(str(error))
    try:
        stamped = json.loads(body) if code == 200 else None
    except ValueError:
        stamped = None
    if not isinstance(stamped, dict) or not stamped.get('commit'):
        return unknown(f'{url} has no deploy stamp (HTTP {code}); the deploy that adds one has not run')
    return {'commit': str(stamped['commit']), 'deployed': stamped.get('deployed_at'), 'source': url}


def site(world):
    trunk = f'origin/{TRUNK}'
    try:
        world.git('fetch', '-q', 'origin', TRUNK)
        files = world.git('ls-tree', '-r', '--name-only', trunk, 'Site/').decode().split('\n')
    except ReadError as error:
        return unknown(f'could not read {trunk}: {error}')
    rows = []
    for path in sorted(f for f in files if f.endswith('index.html')):
        url = page_url(path)
        row = {'page': url[len(SITE):]}
        try:
            code, _, body = world.fetch(url)
        except ReadError as error:
            rows.append(dict(row, unknown=str(error)))
            continue
        row['http'] = code
        if code == 200:
            row['matches_trunk'] = (hashlib.sha256(body).digest() ==
                                    hashlib.sha256(world.git('show', f'{trunk}:{path}')).digest())
        rows.append(row)
    return {'rows': rows, 'deploy': deploy_stamp(world, SITE), 'source': f'fetched from {SITE}, compared with {trunk}'}


def changes_since(world, commit, path):
    """How many commits on the trunk touched `path` after `commit`; None when that can't be worked out."""
    if not commit or not re.fullmatch(r'[0-9a-f]{7,40}', commit):
        return None
    try:
        return int(world.git('rev-list', '--count', f'{commit}..origin/{TRUNK}', '--', path).strip())
    except (ReadError, ValueError):
        return None


def web(world):
    stamped = deploy_stamp(world, WEB)
    if 'unknown' not in stamped:
        stamped['behind'] = changes_since(world, stamped['commit'], 'Web')
    return stamped


def server(world):
    url = f'{SITE}/api/v1/health'
    try:
        code, _, body = world.fetch(url)
        doc = json.loads(body) if code == 200 else None
    except ReadError as error:
        return unknown(str(error))
    except ValueError:
        doc = None
    if not isinstance(doc, dict):
        return unknown(f'{url} did not answer with health data')
    commit = doc.get('commit') or None
    services = doc.get('services') if isinstance(doc.get('services'), dict) else {}
    out = {'status': doc.get('status'), 'version': doc.get('version'), 'commit': commit, 'built': doc.get('built') or None,
           'services_on': sorted(k for k, v in services.items() if v == 'on'),
           'services_off': sorted(k for k, v in services.items() if v != 'on'),
           'behind': changes_since(world, commit, 'research/B4/server'), 'source': url}
    if not commit:
        out['commit_unknown'] = 'this server was deployed before it recorded its commit'
    return out


# ---- Output -----------------------------------------------------------------------------------------------------

def feature_words(flags):
    return ', '.join(f'{FEATURE_NAMES.get(k, k)} {"on" if v else "off"}' for k, v in sorted(flags.items())) or 'no flags recorded'


def behind_words(count):
    return '' if count is None else ', same as main' if count == 0 else f', {count} commit(s) behind main'


def render_builds(part):
    if 'unknown' in part:
        return [f'  unknown: {part["unknown"]}']
    lines = []
    for row in part['rows']:
        features = f'{feature_words(row["flags"])} [{row["flags_source"]}]' if row['flags'] is not None \
            else f'flags unknown: {row["flags_unknown"]}'
        testers = row['testers']
        if 'unknown' in testers:
            who = f'testers unknown: {testers["unknown"]}'
        else:
            who = f'{testers["value"]} [App Store Connect, read {testers["read_at"]}]'
            if testers['stale']:
                who = f'STALE, {testers["hours_old"]:.0f} hours old: ' + who
        lines.append(f'  Build {row["build"]}, commit {row["commit"] or "unknown"}: {features}; {who}')
    return lines or ['  no upload tags found']


def render_site(part):
    if 'unknown' in part:
        return [f'  unknown: {part["unknown"]}']
    deploy = part['deploy']
    lines = [f'  last deploy unknown: {deploy["unknown"]}' if 'unknown' in deploy
             else f'  last deploy {deploy.get("deployed") or "unknown"}, commit {deploy["commit"]} [{deploy["source"]}]']
    for row in part['rows']:
        if 'unknown' in row:
            lines.append(f'  {row["page"]}: unknown: {row["unknown"]}')
        elif row['http'] != 200:
            lines.append(f'  {row["page"]}: NOT LIVE (HTTP {row["http"]})')
        else:
            same = 'matches main' if row['matches_trunk'] else 'DIFFERS FROM MAIN'
            lines.append(f'  {row["page"]}: {same}')
    return lines


def render_web(part):
    if 'unknown' in part:
        return [f'  unknown: {part["unknown"]}']
    return [f'  commit {part["commit"]}, deployed {part.get("deployed") or "unknown"}{behind_words(part.get("behind"))} [{part["source"]}]']


def render_server(part):
    if 'unknown' in part:
        return [f'  unknown: {part["unknown"]}']
    commit = part['commit'] or f'unknown ({part["commit_unknown"]})'
    return [f'  {part["status"]}, version {part["version"]}, commit {commit}{behind_words(part.get("behind"))} [{part["source"]}]',
            '  on: ' + (', '.join(part['services_on']) or 'nothing'),
            '  off: ' + (', '.join(part['services_off']) or 'nothing')]


READERS = {'builds': (builds, render_builds, 'Tester builds'), 'site': (site, render_site, 'Site pages'),
           'web': (web, render_web, 'Web app'), 'server': (server, render_server, 'Server')}


def main(argv=None, world=None):
    parser = argparse.ArgumentParser(description='What is live right now, read from the things themselves.')
    parser.add_argument('--section', action='append', choices=SECTIONS)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--tag-message', metavar='ARCHIVE')
    parser.add_argument('--write-asc', metavar='FILE')
    args = parser.parse_args(argv)
    world = world or World()
    try:
        if args.tag_message:
            print(tag_message(args.tag_message), end='')
            return 0
        if args.write_asc:
            write_asc(args.write_asc, world.now)
            return 0
    except (ReadError, release_gate.InputError) as error:
        print(f'sm_live: {error}', file=sys.stderr)
        return 1
    chosen = args.section or list(SECTIONS)
    facts = {name: READERS[name][0](world) for name in chosen}
    if args.json:
        print(json.dumps(dict(facts, read_at=stamp(world.now)), indent=1))
        return 0
    print(f'What is live, read {stamp(world.now)}. "unknown" means it could not be read; do not fill it in from a comment.')
    for name in chosen:
        print(f'\n{READERS[name][2]}')
        print('\n'.join(READERS[name][1](facts[name])))
    return 0


if __name__ == '__main__':
    sys.exit(main())
