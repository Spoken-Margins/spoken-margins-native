#!/usr/bin/env python3
"""Give an uploaded TestFlight build to its testers after the owner's tap (.github/workflows/testflight-testers.yml,
#5447). Stdlib, 3.9+.

Uploads (from GitHub or the Mac) stop at App Store Connect: someone still had to sign in, add the build to the
internal group and the friends beta, and send it to beta review. Build 38 waited a day for that (2026-11-26). The
owner's call, 2026-11-27: do it with the team API key already stored, but only after he taps Approve, like a deploy.

  plan    Before the tap, GET requests only. Refuses a run the owner's own login started (he could not approve it).
          Waits until App Store Connect has processed the build, reads the share-link flag from the upload tag
          `testflight/<version>-build-N`, runs the external release gate (scripts/release_gate.py, #2236), picks the
          groups and lists what is missing. Writes the run summary and `needed=`, `expect=`, `sha=` step outputs.
          A build already in every group and past review submission needs nothing, and then no one is asked.
  notice  As github-actions[bot]: one comment that @mentions the owner on the PR behind the uploaded commit, saying
          what would change and linking the run where he taps Approve.
  assign  After the tap: reads everything again, refuses if the groups differ from the plan he approved or the gate
          now refuses, then adds the build to the internal groups, sets "What to Test" when it is empty, adds it to
          the friends beta and submits it for beta review. Each step is skipped when already done, so a re-run is safe.

The approval itself is `testflight_upload.py gate`, the same environment (`testflight-upload`) and the same checks
as the upload.

Which groups: every internal group that does not already get every build, and the one external group with a public
link (the friends beta behind spokenmargins.com/join). Zero or several public external groups is refused rather than
guessed. The log is public, so groups are named by role and counted, never by name, and tester data is never read.

  python3 scripts/testflight_testers.py plan --build 39 --started-by LOGIN [--timeout 2700]
  python3 scripts/testflight_testers.py notice --build 39 --sha SHA --run-url URL
  python3 scripts/testflight_testers.py assign --build 39 --expect GROUP_IDS
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
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy_check  # noqa: E402
import release_gate  # noqa: E402
import sm_live  # noqa: E402
import testflight_upload as upload  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
NOTICE_TARGET = 'testers'
LOCALE = 'en-US'
WHAT_TO_TEST = ('Build {build} of Spoken Margins. Please try listening, recording Margins and sharing them, and send '
                'feedback from TestFlight.')
# externalBuildState values after which the build needs no new review submission.
SUBMITTED = {'WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW', 'BETA_APPROVED', 'READY_FOR_BETA_TESTING', 'IN_BETA_TESTING',
             'IN_EXPORT_COMPLIANCE_REVIEW'}
READY_TO_SUBMIT = 'READY_FOR_BETA_SUBMISSION'


class Failure(Exception):
    """A reason to change nothing; printed as an error and the step fails."""


# ---- App Store Connect ------------------------------------------------------------------------------------------

def asc_send(method, path, token, payload):
    """POST or PATCH to App Store Connect. Apple's error titles are printed; they name fields, never secrets."""
    request = urllib.request.Request(sm_live.ASC_API + path, method=method, data=json.dumps(payload).encode(),
                                     headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=60) as reply:
            body = reply.read()
            return json.loads(body) if body.strip() else None
    except urllib.error.HTTPError as error:
        try:
            titles = '; '.join(e.get('detail') or e.get('title') or '' for e in json.load(error).get('errors', []))
        except (ValueError, AttributeError):
            titles = ''
        raise Failure(f'App Store Connect answered {error.code} to {method} {path.split("?")[0]}: {titles[:300]}') \
            from error
    except (urllib.error.URLError, OSError) as error:
        raise Failure(f'could not reach App Store Connect ({type(error).__name__})') from error


class Asc:
    """App Store Connect with one token, made again once it is 8 minutes old (tokens last 10)."""

    def __init__(self, env=os.environ, mint=sm_live.asc_token, fetch=sm_live.asc_get, send=asc_send,
                 now=lambda: dt.datetime.now(dt.timezone.utc)):
        missing = [k for k in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8') if not env.get(k)]
        if missing:
            raise Failure('the environment is missing ' + ', '.join(missing))
        self.env, self.mint, self.fetch, self._send, self.now = env, mint, fetch, send, now
        self.made = None
        self.token = None

    def _token(self):
        moment = self.now()
        if self.made is None or (moment - self.made).total_seconds() >= upload.TOKEN_REFRESH_SECONDS:
            self.token = self.mint(self.env['ASC_KEY_ID'], self.env['ASC_ISSUER_ID'], self.env['ASC_KEY_P8'], moment)
            self.made = moment
        return self.token

    def get(self, path):
        return self.fetch(path, self._token())

    def send(self, method, path, payload):
        return self._send(method, path, self._token(), payload)


def one_build(get, app, build):
    rows = upload.asc_builds(get, app, build)
    if len(rows) != 1:
        raise Failure(f'expected one App Store Connect build numbered {build}, found {len(rows)}')
    return rows[0]


def wait_until_processed(get, app, build, timeout, sleep=time.sleep, clock=time.monotonic):
    deadline = clock() + timeout
    while True:
        rows = upload.asc_builds(get, app, build)
        state = rows[0].get('attributes', {}).get('processingState') if len(rows) == 1 else None
        if state == 'VALID':
            return rows[0]
        if state in ('FAILED', 'INVALID'):
            raise Failure(f'App Store Connect marked Build {build} {state}; read the email Apple sent')
        if clock() >= deadline:
            raise Failure(f'Build {build} was not processed within {timeout} s (state: {state or "not listed"})')
        sleep(60)


def all_groups(get, app):
    query = urllib.parse.urlencode({'filter[app]': app, 'limit': 200})
    return get(f'/v1/betaGroups?{query}').get('data', [])


def pick_groups(groups):
    """(internal groups to add, the friends beta). Refuses rather than guesses."""
    internal = [g for g in groups if g.get('attributes', {}).get('isInternalGroup')
                and not g.get('attributes', {}).get('hasAccessToAllBuilds')]
    public = [g for g in groups if not g.get('attributes', {}).get('isInternalGroup')
              and g.get('attributes', {}).get('publicLinkEnabled')]
    if len(public) != 1:
        raise Failure(f'expected one external group with a public link (the friends beta), found {len(public)}')
    if not internal and not any(g.get('attributes', {}).get('isInternalGroup') for g in groups):
        raise Failure('App Store Connect has no internal tester group')
    return internal, public[0]


def role(group):
    """How a group is named in the log: by its role, never its name (the log is public, as in sm_live's summary)."""
    return 'the internal group' if group.get('attributes', {}).get('isInternalGroup') else 'the friends beta'


def group_has_build(get, app, group_id, build):
    query = urllib.parse.urlencode({'filter[app]': app, 'filter[betaGroups]': group_id, 'filter[version]': str(build),
                                    'limit': 10})
    rows = get(f'/v1/builds?{query}').get('data', [])
    return any(str(r.get('attributes', {}).get('version')) == str(build) for r in rows)


def what_to_test(get, build_id):
    """(localization id or None, its current text) for LOCALE."""
    rows = get(f'/v1/builds/{build_id}/betaBuildLocalizations?limit=50').get('data', [])
    for row in rows:
        if row.get('attributes', {}).get('locale') == LOCALE:
            return row['id'], (row['attributes'].get('whatsNew') or '').strip()
    return None, ''


def external_state(get, build_id):
    detail = get(f'/v1/builds/{build_id}/buildBetaDetail').get('data') or {}
    return detail.get('attributes', {}).get('externalBuildState') or 'unknown'


# ---- The upload tag and the release gate ------------------------------------------------------------------------

def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def upload_tag(build, run=git):
    """(tag name, its commit, its message) for Build `build`, or a Failure: no tag means no flags to gate on."""
    names = [n for n in run('tag', '-l', 'testflight/*').split()
             if (m := upload.TAG_RE.match(n)) and int(m.group(2)) == build]
    if len(names) != 1:
        raise Failure(f'expected one upload tag testflight/<version>-build-{build}, found {len(names)}; '
                      'every upload is tagged, and the tag carries the share-link flag the release gate needs')
    tag = names[0]
    commit = run('rev-list', '-n', '1', tag).strip()
    # A lightweight tag has no message of its own: git prints the commit's, which a PR title can fill. As in sm_live,
    # only an annotated tag records flags.
    if run('for-each-ref', '--format=%(objecttype)', f'refs/tags/{tag}').strip() != 'tag':
        return tag, commit, ''
    return tag, commit, run('tag', '-l', '--format=%(contents)', tag)


def gate_verdict(build, message, today=None):
    """(allowed, reasons) from release_gate for the external group. A tag without the flag counts as share links on.

    Only the archive's own `flags:` line counts: a sentence typed into a tag can say off and on at once, and a wrong
    read sends share links to the friends beta."""
    flags, how = sm_live.flags_from_message(message)
    if how != 'read from the archive':
        flags = None
    plist = {'CFBundleVersion': str(build)}
    if flags and 'SMShareLinkCreation' in flags:
        plist[release_gate.PLIST_KEY] = flags['SMShareLinkCreation']
    record = release_gate.read_record(release_gate.DEFAULT_RECORD)
    today = today or dt.date.fromisoformat(os.environ.get('SM_RELEASE_GATE_TODAY') or dt.date.today().isoformat())
    return release_gate.decide('external', plist, record, today)


# ---- Plan -------------------------------------------------------------------------------------------------------

def survey(get, build, processed):
    """Everything assign needs, read fresh. `processed` is the build row (VALID)."""
    app = upload.app_id(get)
    build_id = processed['id']
    internal, friends = pick_groups(all_groups(get, app))
    todo = []
    for group in internal:
        if not group_has_build(get, app, group['id'], build):
            todo.append(('group', group))
    loc_id, text = what_to_test(get, build_id)
    if not text:
        todo.append(('what-to-test', loc_id))
    if not group_has_build(get, app, friends['id'], build):
        todo.append(('group', friends))
    state = external_state(get, build_id)
    if state == READY_TO_SUBMIT:
        todo.append(('review', None))
    elif state not in SUBMITTED:
        raise Failure(f'Build {build} cannot go to beta review now (App Store Connect says {state})')
    expect = ','.join(sorted(g['id'] for g in internal + [friends]))
    return {'app': app, 'build_id': build_id, 'internal': internal, 'friends': friends, 'todo': todo,
            'state': state, 'expect': expect}


def describe(build, facts):
    lines = []
    for kind, item in facts['todo']:
        if kind == 'group':
            lines.append(f'- Add Build {build} to {role(item)}.')
        elif kind == 'what-to-test':
            lines.append(f'- Set "What to Test" to: {WHAT_TO_TEST.format(build=build)}')
        else:
            lines.append(f'- Submit Build {build} for beta review (needed before the friends beta can install it).')
    return lines


def write_outputs(**values):
    out = os.environ.get('GITHUB_OUTPUT')
    if out:
        with open(out, 'a') as handle:
            for key, value in values.items():
                handle.write(f'{key}={value}\n')


def summary(lines):
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a') as handle:
            handle.write('\n'.join(lines) + '\n')
    print('\n'.join(lines))


def plan(args, get=None, run=git, sleep=time.sleep, today=None):
    if args.started_by == deploy_check.OWNER_LOGIN:
        raise Failure(f'GitHub prevents self-review in {upload.GATE_ENVIRONMENT}, so {args.started_by} cannot approve a '
                      'run his own login started. testflight-testers-request.yml starts these runs as the App.')
    tag, sha, message = upload_tag(args.build, run)
    allowed, reasons = gate_verdict(args.build, message, today)
    if not allowed:
        raise Failure(f'release gate refused Build {args.build} for the external group: ' + ' '.join(reasons))
    get = get or Asc().get
    app = upload.app_id(get)
    processed = wait_until_processed(get, app, args.build, args.timeout, sleep=sleep)
    facts = survey(get, args.build, processed)
    head = [f'Build {args.build} ({tag}, {sha[:9]}). Release gate: allowed, {reasons[0]}.',
            f'Groups: {len(facts["internal"])} internal to add to (internal groups that get every build are left alone),'
            f' and the friends beta. Beta review: {facts["state"]}.']
    if not facts['todo']:
        summary(head + [f'Nothing to do: Build {args.build} is already with its testers. No approval is asked.'])
        write_outputs(needed='false', expect=facts['expect'], sha=sha)
        return 0
    summary(head + ['', 'After the owner approves, this run will:'] + describe(args.build, facts))
    write_outputs(needed='true', expect=facts['expect'], sha=sha)
    return 0


# ---- Notice -----------------------------------------------------------------------------------------------------

def notice_body(build, sha, run_url):
    body = [f'@{deploy_check.OWNER_LOGIN} Build {build} is processed and ready for its testers, and it is waiting for '
            'your OK.', '',
            'After you approve, the run adds it to the internal group, sets "What to Test" if it is empty, adds it to '
            'the friends beta (the spokenmargins.com/join group) and submits it for beta review. The run page lists '
            'exactly which steps are left. The external release gate already passed.',
            f'To do it, open the run and tap "Review deployments", then Approve: {run_url}',
            'If you do nothing, nothing changes.', '', deploy_check.marker(NOTICE_TARGET, sha)]
    return '\n'.join(body) + '\n'


def notice(args, api=deploy_check.gh):
    body = notice_body(args.build, args.sha, args.run_url)
    repo = os.environ.get('GITHUB_REPOSITORY') or sm_live.REPO
    print(f'Posted the testers notice on {deploy_check.post_notice(repo, args.sha, body, NOTICE_TARGET, api=api)}.')
    return 0


# ---- Assign -----------------------------------------------------------------------------------------------------

def assign(args, asc=None, run=git, today=None, sleep=time.sleep):
    _tag, _sha, message = upload_tag(args.build, run)
    allowed, reasons = gate_verdict(args.build, message, today)
    if not allowed:
        raise Failure(f'release gate now refuses Build {args.build}: ' + ' '.join(reasons))
    asc = asc or Asc()
    get = asc.get
    app = upload.app_id(get)
    facts = survey(get, args.build, one_build(get, app, args.build))
    if facts['expect'] != args.expect:
        raise Failure('the tester groups changed since the plan the owner approved; start a new run')
    build_id = facts['build_id']
    ref = {'data': [{'type': 'builds', 'id': build_id}]}
    for kind, item in facts['todo']:
        if kind == 'group':
            asc.send('POST', f'/v1/betaGroups/{item["id"]}/relationships/builds', ref)
            print(f'Added Build {args.build} to {role(item)}.')
        elif kind == 'what-to-test':
            text = WHAT_TO_TEST.format(build=args.build)
            if item:
                asc.send('PATCH', f'/v1/betaBuildLocalizations/{item}',
                         {'data': {'type': 'betaBuildLocalizations', 'id': item, 'attributes': {'whatsNew': text}}})
            else:
                asc.send('POST', '/v1/betaBuildLocalizations',
                         {'data': {'type': 'betaBuildLocalizations', 'attributes': {'locale': LOCALE, 'whatsNew': text},
                                   'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})
            print('Set "What to Test".')
        else:
            asc.send('POST', '/v1/betaAppReviewSubmissions',
                     {'data': {'type': 'betaAppReviewSubmissions',
                               'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})
            print(f'Submitted Build {args.build} for beta review.')
    # App Store Connect can take a moment to show its own writes; read again a few times before calling it a failure.
    for attempt in range(6):
        after = survey(get, args.build, one_build(get, app, args.build))
        if not after['todo']:
            break
        if attempt < 5:
            sleep(20)
    else:
        raise Failure('App Store Connect still shows steps left: ' + ' '.join(describe(args.build, after)))
    summary([f'Build {args.build} is with its testers. Beta review: {after["state"]}.'])
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description='Give an uploaded TestFlight build to its testers after the tap.')
    sub = parser.add_subparsers(dest='command', required=True)
    parts = {n: sub.add_parser(n) for n in ('plan', 'notice', 'assign')}
    for part in parts.values():
        part.add_argument('--build', type=int, required=True)
    parts['plan'].add_argument('--started-by', required=True, help='github.triggering_actor')
    parts['plan'].add_argument('--timeout', type=int, default=2700)
    parts['notice'].add_argument('--sha', required=True)
    parts['notice'].add_argument('--run-url', required=True)
    parts['assign'].add_argument('--expect', required=True, help="the plan's group ids, comma-separated")
    args = parser.parse_args(argv)
    if getattr(args, 'sha', None) is not None and not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        parser.error('--sha must be a full commit hash')
    commands = {'plan': plan, 'notice': notice, 'assign': assign}
    try:
        return commands[args.command](args)
    except (Failure, upload.Failure, deploy_check.Failure, sm_live.ReadError, release_gate.InputError,
            subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f'::error::{error}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
