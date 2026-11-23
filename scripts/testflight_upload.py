#!/usr/bin/env python3
"""The checks around a TestFlight upload from GitHub (.github/workflows/testflight-upload.yml, #4915). Stdlib, 3.9+.

Uploads ran only on the owner's Mac, so a lost or sleeping Mac meant no build reached testers. The workflow archives
the Release app from main on a hosted Mac, has Apple's cloud-managed certificate sign it, and uploads it, but only
after the owner taps Approve. This script is everything in that workflow that is not xcodebuild:

  plan        Before the tap, no secrets: the build number from project.yml (and the generated project, which is
              what xcodebuild reads), refused if a `testflight/*` tag already has it or a higher one, and the commits
              since the last upload tag. Writes the run summary and `build=`, `version=`, `last_tag=` step outputs.
  asc-check   With the App Store Connect key, GET requests only: refuse if App Store Connect already has this build
              number for the app. Runs before the tap and again right before the archive.
  notice      As github-actions[bot]: one comment that @mentions the owner on the PR behind the commit (or the
              commit), saying what would ship and linking the run where he taps Approve.
  gate        In the approval job: the environment really requires the owner, prevents self-review and admits main
              alone, and this run carries his approval. GitHub creates a missing environment with no rules on first
              use, so without this a run before the environment was set up would upload with no tap at all.
  archive     After the archive: its Info.plist must say this build number, this commit, a Release build (no phone
              build switch) and the share-link setting the run asked for.
  asc-wait    After the upload, in its own job: wait until App Store Connect lists the build. Xcode's "EXPORT
              SUCCEEDED" is not proof. A re-run of that job waits again instead of refusing the number it uploaded.
  tag         As the spoken-margins-agent App: the annotated tag `testflight/<version>-build-N` on the commit, with
              the archive's flags line (scripts/sm_live.py --tag-message), refused if the tag exists.

  python3 scripts/testflight_upload.py plan --sha SHA --share-links off
  python3 scripts/testflight_upload.py asc-check --build 37
  python3 scripts/testflight_upload.py notice --sha SHA --build 37 --version 0.1 --last-tag TAG --share-links off --run-url URL
  python3 scripts/testflight_upload.py gate --run-id ID
  python3 scripts/testflight_upload.py archive --archive PATH --build 37 --sha SHA --share-links off
  python3 scripts/testflight_upload.py asc-wait --build 37 --timeout 1200
  python3 scripts/testflight_upload.py tag --build 37 --version 0.1 --sha SHA --message-file FILE
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy_check  # noqa: E402
import release_gate  # noqa: E402
import sm_live  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TAG_RE = re.compile(r'^testflight/(\d+(?:\.\d+)*)-build-(\d+)$')
SHOWN = 30
NOTICE_TARGET = 'testflight'


class Failure(Exception):
    """A reason not to upload; printed as an error and the step fails."""


# ---- Build number -----------------------------------------------------------------------------------------------

def one_value(values, what, where):
    found = sorted(set(values))
    if not found:
        raise Failure(f'{where} has no {what}')
    if len(found) > 1:
        raise Failure(f'{where} has more than one {what}: {", ".join(found)}; every target must match')
    return found[0]


def project_versions(project_yml, pbxproj):
    """(build, version) from project.yml, which must agree with the generated project xcodebuild actually reads."""
    build = one_value(re.findall(r'^\s+CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)"?\s*$', project_yml, re.M),
                      'CURRENT_PROJECT_VERSION', 'project.yml')
    version = one_value(re.findall(r'^\s+MARKETING_VERSION:\s*"?([^"\s]+)"?\s*$', project_yml, re.M),
                        'MARKETING_VERSION', 'project.yml')
    if not build.isdecimal():
        raise Failure(f'CURRENT_PROJECT_VERSION is {build!r}, not a whole number')
    if not re.fullmatch(r'\d+(\.\d+)*', version):
        raise Failure(f'MARKETING_VERSION is {version!r}, not a dotted number')
    generated = one_value(re.findall(r'\bCURRENT_PROJECT_VERSION = "?([^";]+)"?;', pbxproj),
                          'CURRENT_PROJECT_VERSION', 'the generated project')
    if generated != build:
        raise Failure(f'project.yml says build {build} but the generated project says {generated}; '
                      'run xcodegen generate and commit it')
    generated = one_value(re.findall(r'\bMARKETING_VERSION = "?([^";]+)"?;', pbxproj),
                          'MARKETING_VERSION', 'the generated project')
    if generated != version:
        raise Failure(f'project.yml says version {version} but the generated project says {generated}')
    return int(build), version


def tag_numbers(tags):
    """{build number: tag} for every upload tag, whatever its version prefix: Apple's build numbers never repeat here."""
    found = {}
    for tag in tags:
        match = TAG_RE.match(tag.strip())
        if match:
            found[int(match.group(2))] = tag.strip()
    return found


def refuse_used(build, tags):
    numbers = tag_numbers(tags)
    if build in numbers:
        raise Failure(f'Build {build} was already uploaded ({numbers[build]}). Land a PR that bumps '
                      'CURRENT_PROJECT_VERSION in project.yml, then run this again.')
    newest = max(numbers, default=None)
    if newest is not None and build < newest:
        raise Failure(f'Build {build} is lower than the last upload, Build {newest} ({numbers[newest]}). '
                      'Apple refuses a lower build number; bump CURRENT_PROJECT_VERSION.')


def git(*args):
    done = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True, timeout=120)
    if done.returncode:
        raise Failure(f'git {args[0]} failed: {done.stderr.strip()[:200]}')
    return done.stdout


def last_upload_tag(sha, run=git):
    """The highest-numbered upload tag whose commit is in SHA's history, or None."""
    merged = tag_numbers(run('tag', '--list', 'testflight/*', '--merged', sha).split())
    return merged[max(merged)] if merged else None


MERGE_RE = re.compile(r'^Merge pull request (#\d+) from \S+$')


def change_line(short, subject, body):
    """One line per change on main: a merged PR by its number and title, any other commit by its subject."""
    merge = MERGE_RE.match(subject)
    title = next((line.strip() for line in body.splitlines() if line.strip()), '')
    if merge and title:
        return f'{merge.group(1)} {title}'
    return f'{short} {subject}'


def changes_since(tag, sha, run=git):
    """(lines, total): main's own commits (merged PRs) after TAG up to SHA, newest first, capped at SHOWN."""
    span = f'{tag}..{sha}' if tag else sha
    out = run('log', '--first-parent', '-z', '--format=%h%x1f%s%x1f%b', span)
    lines = [change_line(*(entry.split('\x1f') + ['', ''])[:3]) for entry in out.split('\0') if entry.strip()]
    total = len(lines)
    shown = lines[:SHOWN] + ([f'and {total - SHOWN} more'] if total > SHOWN else [])
    return shown, total


def summary_lines(build, version, sha, share_links, tag, lines, total):
    head = f'Build {build} ({version}) from {sha[:9]}, share-link creation {share_links}.'
    if tag:
        since = f'{total} change(s) since the last upload, {tag}:' if total else f'No change since {tag}.'
    else:
        since = 'No earlier upload tag in this commit\'s history; this is the newest change:'
    return [head, since] + [f'- {deploy_check.quiet(line)}' for line in lines]


def plan(args, run=git, root=ROOT):
    build, version = project_versions((root / 'project.yml').read_text(),
                                      (root / 'SpokenMarginsNative.xcodeproj/project.pbxproj').read_text())
    refuse_used(build, run('tag', '--list', 'testflight/*').split())
    tag = last_upload_tag(args.sha, run)
    lines, total = changes_since(tag, args.sha, run)
    if not tag:
        lines = [run('log', '-1', '--format=%h %s', args.sha).strip()]
    text = '\n'.join(['### TestFlight upload waiting for approval', ''] +
                     summary_lines(build, version, args.sha, args.share_links, tag, lines, total)) + '\n'
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as out:
            out.write(text)
    print(text, end='')
    outputs = f'build={build}\nversion={version}\nlast_tag={tag or ""}\n'
    print(outputs, end='')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
            out.write(outputs)
    return 0


# ---- App Store Connect (GET only) -------------------------------------------------------------------------------

TOKEN_REFRESH_SECONDS = 480  # sm_live.asc_token's tokens expire 600 s after they are made


def asc_session(mint=sm_live.asc_token, fetch=sm_live.asc_get, now=lambda: dt.datetime.now(dt.timezone.utc)):
    """A GET function that makes a new App Store Connect token once the last is 8 minutes old, so a wait longer
    than one token's 10 minutes keeps reading instead of failing with a 401 after a real upload (#5156 audit)."""
    missing = [name for name in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8') if not os.environ.get(name)]
    if missing:
        raise Failure('the environment is missing ' + ', '.join(missing))
    held = {}

    def get(path):
        moment = now()
        if 'token' not in held or (moment - held['made']).total_seconds() >= TOKEN_REFRESH_SECONDS:
            held['token'] = mint(os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID'], os.environ['ASC_KEY_P8'], moment)
            held['made'] = moment
        return fetch(path, held['token'])
    return get


def app_id(get):
    apps = get(f'/v1/apps?filter%5BbundleId%5D={sm_live.BUNDLE_ID}&limit=200').get('data', [])
    apps = [a for a in apps if a.get('attributes', {}).get('bundleId') == sm_live.BUNDLE_ID]
    if len(apps) != 1:
        raise Failure(f'expected one App Store Connect app for {sm_live.BUNDLE_ID}, found {len(apps)}')
    return apps[0]['id']


def asc_builds(get, app, build):
    """App Store Connect's builds of APP whose build number is BUILD, under any version."""
    query = urllib.parse.urlencode({'filter[app]': app, 'filter[version]': str(build), 'limit': 200})
    rows = get(f'/v1/builds?{query}').get('data', [])
    return [r for r in rows if str(r.get('attributes', {}).get('version')) == str(build)]


def asc_check(args, get=None):
    get = get or asc_session()
    found = asc_builds(get, app_id(get), args.build)
    if found:
        state = found[0].get('attributes', {}).get('processingState') or 'unknown state'
        raise Failure(f'App Store Connect already has Build {args.build} ({state}). Bump CURRENT_PROJECT_VERSION.')
    print(f'App Store Connect has no Build {args.build} yet.')
    return 0


def asc_wait(args, get=None, sleep=time.sleep, clock=time.monotonic):
    get = get or asc_session()
    app = app_id(get)
    deadline = clock() + args.timeout
    while True:
        found = asc_builds(get, app, args.build)
        if found:
            state = found[0].get('attributes', {}).get('processingState') or 'unknown state'
            print(f'App Store Connect lists Build {args.build} ({state}).')
            if state == 'INVALID':
                raise Failure(f'App Store Connect marked Build {args.build} INVALID; read the email Apple sent')
            return 0
        if clock() >= deadline:
            raise Failure(f'App Store Connect did not list Build {args.build} within {args.timeout} s of the upload')
        sleep(30)


# ---- Notice -----------------------------------------------------------------------------------------------------

def notice_body(build, version, sha, share_links, tag, lines, total, run_url):
    body = [f'@{deploy_check.OWNER_LOGIN} Build {build} is ready to upload to TestFlight, and it is waiting for your OK.',
            '', 'What would ship.'] + summary_lines(build, version, sha, share_links, tag, lines, total)[1:]
    body += ['', f'Share-link creation is {share_links} in this build. It goes to App Store Connect only; '
             'no tester group is changed by this run.',
             f'To upload it, open the run and tap "Review deployments", then Approve: {run_url}',
             'If you do nothing, nothing is uploaded.', '', deploy_check.marker(NOTICE_TARGET, sha)]
    return '\n'.join(body) + '\n'


def notice(args, run=git, api=deploy_check.gh):
    tag = args.last_tag or None
    lines, total = changes_since(tag, args.sha, run)
    if not tag:
        lines = [run('log', '-1', '--format=%h %s', args.sha).strip()]
    body = notice_body(args.build, args.version, args.sha, args.share_links, tag, lines, total, args.run_url)
    if args.dry_run:
        print(body, end='')
        return 0
    repo = os.environ.get('GITHUB_REPOSITORY') or sm_live.REPO
    print(f'Posted the upload notice on {deploy_check.post_notice(repo, args.sha, body, NOTICE_TARGET, api=api)}.')
    return 0


# ---- Gate -------------------------------------------------------------------------------------------------------

GATE_ENVIRONMENT = 'testflight-upload'


def gate_problems(environment, policies, approvals, owner=deploy_check.OWNER_LOGIN):
    """Why the approval job's own pass is not the owner's tap, or []. GitHub makes a missing environment on first use
    with no rules at all, so a job in it passes untouched; this refuses that, and any approval not by the owner."""
    problems = []
    rules = environment.get('protection_rules') or []
    reviewers = [rule for rule in rules if rule.get('type') == 'required_reviewers']
    logins = {(r.get('reviewer') or {}).get('login') for rule in reviewers for r in rule.get('reviewers') or []}
    if owner not in logins:
        problems.append(f'the {GATE_ENVIRONMENT} environment does not require {owner}\'s review')
    if not any(rule.get('prevent_self_review') for rule in reviewers):
        problems.append(f'the {GATE_ENVIRONMENT} environment does not prevent self-review')
    branch = environment.get('deployment_branch_policy') or {}
    names = sorted((p.get('name'), p.get('type', 'branch')) for p in policies)
    if not branch.get('custom_branch_policies') or names != [('main', 'branch')]:
        problems.append(f'the {GATE_ENVIRONMENT} environment does not admit main alone')
    approved = [a for a in approvals if a.get('state') == 'approved'
                and (a.get('user') or {}).get('login') == owner
                and any(e.get('name') == GATE_ENVIRONMENT for e in a.get('environments') or [])]
    if not approved:
        problems.append(f'this run has no approval from {owner} for {GATE_ENVIRONMENT}')
    return problems


def gate(args, api=deploy_check.gh):
    repo = os.environ.get('GITHUB_REPOSITORY') or sm_live.REPO
    environment = api(f'repos/{repo}/environments/{GATE_ENVIRONMENT}') or {}
    policies = (api(f'repos/{repo}/environments/{GATE_ENVIRONMENT}/deployment-branch-policies') or {}).get(
        'branch_policies', [])
    approvals = api(f'repos/{repo}/actions/runs/{args.run_id}/approvals') or []
    problems = gate_problems(environment, policies, approvals)
    for line in problems:
        print(f'::error::{line}')
    if problems:
        print('Nothing was uploaded. The gate must be the owner\'s tap (#4915).')
        return 1
    print(f'{deploy_check.OWNER_LOGIN} approved this run in {GATE_ENVIRONMENT}.')
    return 0


# ---- Archive ----------------------------------------------------------------------------------------------------

def archive_problems(plist, build, sha, share_links):
    problems = []
    if str(plist.get('CFBundleVersion')) != str(build):
        problems.append(f'CFBundleVersion is {plist.get("CFBundleVersion")!r}, not {build}')
    commit = plist.get('SMBuildCommit')
    if commit != sha:
        problems.append(f'SMBuildCommit is {commit!r}, not {sha}')
    if plist.get('SMPhoneBuild') != 'NO':
        problems.append(f'SMPhoneBuild is {plist.get("SMPhoneBuild")!r}; an upload is a plain Release build (NO)')
    on, problem = release_gate.share_links_on(plist)
    if problem:
        problems.append(problem)
    elif on != (share_links == 'on'):
        problems.append(f'share-link creation is {"on" if on else "off"}, but this run asked for {share_links}')
    return problems


def archive(args):
    try:
        plist = release_gate.read_plist(Path(args.archive))
    except release_gate.InputError as error:
        raise Failure(f'could not read the archive: {error}') from error
    problems = archive_problems(plist, args.build, args.sha, args.share_links)
    for line in problems:
        print(f'::error::{line}')
    if problems:
        return 1
    print(f'The archive is Build {args.build} from {args.sha[:9]}, Release, share-link creation {args.share_links}.')
    return 0


# ---- Tag --------------------------------------------------------------------------------------------------------

def tag_name(version, build):
    return f'testflight/{version}-build-{build}'


def create_tag(repo, name, sha, message, api=deploy_check.gh):
    """An annotated tag through the API, so it carries the archive's flags line. Never moves an existing tag."""
    existing = api(f'repos/{repo}/git/matching-refs/tags/{name}') or []
    if any(ref.get('ref') == f'refs/tags/{name}' for ref in existing):
        raise Failure(f'{name} already exists; not moving it')
    tag = api('-X', 'POST', '--input', '-', f'repos/{repo}/git/tags',
              payload={'tag': name, 'message': message, 'object': sha, 'type': 'commit'})
    api('-X', 'POST', '--input', '-', f'repos/{repo}/git/refs', payload={'ref': f'refs/tags/{name}', 'sha': tag['sha']})
    return name


def tag(args, api=deploy_check.gh):
    message = Path(args.message_file).read_text()
    if not re.search(rf'^Build {args.build} \(', message, re.M) or not re.search(r'^flags:', message, re.M):
        raise Failure(f'the tag message does not describe Build {args.build}: {message[:120]!r}')
    repo = os.environ.get('GITHUB_REPOSITORY') or sm_live.REPO
    name = create_tag(repo, tag_name(args.version, args.build), args.sha, message, api=api)
    print(f'Tagged {args.sha[:9]} as {name}.')
    return 0


# ---- Command line -----------------------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description='Checks around a gated TestFlight upload.')
    sub = parser.add_subparsers(dest='command', required=True)
    parts = {name: sub.add_parser(name)
             for name in ('plan', 'asc-check', 'notice', 'gate', 'archive', 'asc-wait', 'tag')}
    for name in ('plan', 'notice', 'archive', 'tag'):
        parts[name].add_argument('--sha', required=True)
    for name in ('plan', 'notice', 'archive'):
        parts[name].add_argument('--share-links', choices=('on', 'off'), required=True)
    for name in ('asc-check', 'notice', 'archive', 'asc-wait', 'tag'):
        parts[name].add_argument('--build', type=int, required=True)
    for name in ('notice', 'tag'):
        parts[name].add_argument('--version', required=True)
    parts['notice'].add_argument('--last-tag', default='')
    parts['notice'].add_argument('--run-url', required=True)
    parts['notice'].add_argument('--dry-run', action='store_true')
    parts['gate'].add_argument('--run-id', type=int, required=True)
    parts['archive'].add_argument('--archive', required=True)
    parts['asc-wait'].add_argument('--timeout', type=int, default=1200)
    parts['tag'].add_argument('--message-file', required=True)
    args = parser.parse_args(argv)
    if getattr(args, 'sha', None) is not None and not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        parser.error('--sha must be a full commit hash')
    commands = {'plan': plan, 'asc-check': asc_check, 'notice': notice, 'gate': gate, 'archive': archive,
                'asc-wait': asc_wait, 'tag': tag}
    try:
        return commands[args.command](args)
    except (Failure, deploy_check.Failure, sm_live.ReadError) as error:
        print(f'::error::{error}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
