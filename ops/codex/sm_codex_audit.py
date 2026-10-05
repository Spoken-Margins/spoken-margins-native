#!/usr/bin/env python3
"""Mechanical Codex (Astra) audit for Spoken Margins PRs into `next`.

Replaces the `sm-codex-audit` Claude scheduled task. The gating is plain code,
so an idle run makes a handful of `gh` calls and nothing else: no worktree, no
Codex, no Claude.

A PR is audited when all of these hold:
  * it is open, not a draft, and targets `next`;
  * no audit comment (starting "**Codex audit (Astra)" or "## Codex audit",
    the lane runner's own match) names its current head sha7;
  * the newest "Lane report ... — PASS/FAIL" comment is PASS for the current head;
  * its changed files touch a risky area (sharing/packets, persistence/SQLite/
    migrations/ledger, audio session/players/Supertonic, the lane: workflows,
    the runner and its helpers, owner rule 2026-10-01), or the lane runner's
    newest report says it won't merge the PR until it has a Codex audit (the
    runner classifies files with scripts/test-scope.py, which is wider than the
    list here: #402 and #439 waited on an audit this script never ran), or a
    comment on the PR or its linked issue asks for a Codex audit.

Small PRs are batched: one Codex call per batch, one comment per PR.

Re-arm: the runner merges an audio, persistence or packet PR only on a run
after a clean audit, and nothing starts that run. So after each audit batch,
and again at the end of every run, the script removes and re-adds `automerge`
on each PR that has the label, whose newest audit of the head opens "No
blocking findings" (the runner's own rule, #441), whose newest lane report is
a PASS on the head from before that audit, and that nobody has re-labelled
since the audit. The label event starts the lane's
automerge job, which tests and merges. Each audit re-arms at most once.

Usage:
  /usr/bin/python3 ops/codex/sm_codex_audit.py [--dry-run] [--pr N]

Install and switch-over steps are in ops/codex/README.md.

Python 3 stdlib only; `gh` and `git` must be on PATH.
"""

from __future__ import annotations

import argparse
import ast
import datetime as _dt
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO = "uncomposed/spoken-margins-native"
BASE_BRANCH = "next"
AUTOMERGE = "automerge"
HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]  # ops/codex/ -> repo root
OPS_DIR = REPO_ROOT / "artifacts" / "ops"
LOG_PATH = OPS_DIR / "codex-audit.log"
LOCK_PATH = OPS_DIR / "codex-audit.lock"
OUTPUT_KEEP_DIR = OPS_DIR / "codex-audit-outputs"
LIMITS_SCRIPT = HERE / "codex_limits.py"

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
CODEX_MODEL = "gpt-6-astra"
CODEX_TIMEOUT_S = 30 * 60
LIMITS_TIMEOUT_S = 60
EXHAUSTED_PERCENT = 100

SOLO_OVER_LINES = 400  # a PR with more changed lines than this is audited alone
BATCH_MAX_PRS = 5
BATCH_MAX_LINES = 600
BODY_CHARS = 6000  # cap on each PR body / issue section passed to Codex

INSTRUCTION = (
    "Review this change. Report only correctness bugs with a concrete failure "
    "scenario (inputs or state, then the wrong result), violations of the "
    "issue's Done when or Must not break, and violations of AGENTS.md's hard "
    "rules (packets and databases readable by Build 29, owner data, main). "
    "Rank the most severe first. For each: file and line, the scenario, and the "
    "smallest fix. No style notes. If you find nothing real, write "
    '"No blocking findings."'
)

FOOTER = (
    "Posted by the mechanical audit script; Codex ran read-only; findings are "
    "Codex's own, not re-checked by Claude."
)

# Risky areas, from the SKILL.md of the scheduled task this replaces.
# Matched case-insensitively against each changed path. Docs, research and
# test-only files never make a PR risky on their own (a test-only diff has
# been judged "no Codex audit due" by the threads, e.g. #418).
RISKY_PATTERNS = {
    "sharing": [
        r"(^|/)SessionKitSharing/",
        r"packet",
        r"^Contracts/fixtures/(sharing|interjection-packages)/",
    ],
    "persistence": [
        r"(^|/)SessionKitPersistence/",
        r"sqlite",
        r"migration",
        r"persist",
        r"ledger",
        r"(^|/)SessionEngine[^/]*\.swift$",
        r"^Contracts/fixtures/(persistence|prepared-audio)/",
    ],
    "audio": [
        r"(^|/)SessionKitAudio/",
        r"audio ?session",
        r"playbackcoordinator",
        r"player",
        r"supertonic",
        r"^Contracts/fixtures/audio/",
    ],
    # The lane itself (owner rule 2026-10-01): a copy of LANE_PREFIXES and
    # LANE_FILES in the repo's scripts/test-scope.py, which the runner uses
    # for its hold. Keep the two in step. scripts/tests/ stays off (tests).
    "lane": [
        r"^\.github/workflows/",
        r"^scripts/lane",
        r"^scripts/(xcodebuild-lane|host-test-lane|install-lane-guard\.py|test-scope\.py"
        r"|hot_file_ratchet\.py|merge_audit\.py|verify-tests\.py)$",
        r"^TestPlans/(AppBehavior|AudioAdapters)\.xctestplan$",
    ],
}
_RISKY_RE = {k: [re.compile(p, re.I) for p in v] for k, v in RISKY_PATTERNS.items()}
_NEVER_RISKY_RE = re.compile(
    r"(^|/)(docs|research|Design)/|(^|/)[^/]*Tests/|\.md$", re.I
)
_UNCOUNTED_RE = re.compile(r"(^|/)research/|(^|/)fixtures/", re.I)

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested in test_sm_codex_audit.py)
# ---------------------------------------------------------------------------

_HEX_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
_LANE_RE = re.compile(r"^\s*Lane report\b.*?(?:—|--|-)\s*(PASS|FAIL)\b")
_LANE_COMMIT_RE = re.compile(r"\bcommit\s+`?([0-9a-f]{7,40})\b")
_REQUEST_CMD_RE = re.compile(r"(?im)^\s*/codex[- ]audit\b")
_REQUEST_RE = re.compile(
    r"(?i)\b(please|request(?:s|ed|ing)?|asks?\s+for|asking\s+for|wants?|needs?)\b"
    r"[^.\n]{0,25}?\bcodex\s+audit\b"
)
_NEGATION_RE = re.compile(r"(?i)(\bno\b|\bnot\b|n't\b|\bwithout\b|\bnever\b)[^.\n]{0,20}$")
# The runner's hold line: 'not merged by the runner: it touches the audio session and has no
# "Codex audit (Astra)" comment yet' (next), or '... and has no Codex audit of its head: ...' (#495).
_RUNNER_WAITS_RE = re.compile(r"(?im)^not merged by the runner:.*\bhas no \"?Codex audit\b")
# The runner's clean-audit rule (#441, lane-runner.py CLEAN_AUDIT): the verdict line opens so.
_CLEAN_AUDIT_RE = re.compile(r"no (blocking )?findings\b", re.I)


def first_line(body: str | None) -> str:
    return (body or "").strip().splitlines()[0] if (body or "").strip() else ""


def comment_body(c: dict) -> str:
    return c.get("body") or ""


def comment_time(c: dict) -> str:
    return c.get("created_at") or c.get("createdAt") or ""


# How a real audit comment starts: this script's own heading (build_comment), or an older manual
# "## Codex audit". The same prefixes as AUDITS in scripts/lane-runner.py, so this script counts
# exactly the audits the runner merges on. A finisher's reply such as "**Codex audit on `a919a79`
# (P2): fixed in `d00dd82`" is not an audit of `d00dd82` (#812).
AUDIT_HEADINGS = ("**Codex audit (Astra)", "## Codex audit")


def is_audit_comment(c: dict) -> bool:
    return comment_body(c).lstrip().startswith(AUDIT_HEADINGS)


def names_sha(line: str, head_sha: str) -> bool:
    """True when `line` names `head_sha` by a 7+ character prefix."""
    head = head_sha.lower()
    if head[:7] in line.lower():
        return True
    return any(head.startswith(tok) for tok in _HEX_RE.findall(line.lower()))


def audited_on(comments: list[dict], head_sha: str) -> bool:
    """Any audit comment (AUDIT_HEADINGS) whose first line names the head sha7."""
    return any(
        is_audit_comment(c) and names_sha(first_line(comment_body(c)), head_sha)
        for c in comments
    )


def parse_lane_report(c: dict) -> tuple[str, str | None] | None:
    """(verdict, commit) for a lane report comment, else None."""
    body = comment_body(c)
    m = _LANE_RE.match(first_line(body))
    if not m:
        return None
    cm = _LANE_COMMIT_RE.search(body)
    return m.group(1), (cm.group(1).lower() if cm else None)


def newest_lane_comment(comments: list[dict]) -> dict | None:
    """The newest PASS/FAIL lane report comment, else None."""
    best = None
    for c in comments:
        if parse_lane_report(c) and (best is None or comment_time(c) >= comment_time(best)):
            best = c
    return best


def newest_lane_report(comments: list[dict]) -> tuple[str, str | None, str] | None:
    """(verdict, commit, created_at) of the newest lane report, else None."""
    c = newest_lane_comment(comments)
    if c is None:
        return None
    verdict, commit = parse_lane_report(c)
    return verdict, commit, comment_time(c)


def lane_pass_for_head(comments: list[dict], head_sha: str) -> tuple[bool, str]:
    rep = newest_lane_report(comments)
    if rep is None:
        return False, "no lane report"
    verdict, commit, _ = rep
    if not commit or not head_sha.lower().startswith(commit):
        return False, f"newest lane report is on {commit or '?'}, not the head"
    if verdict != "PASS":
        return False, "newest lane report on the head is FAIL"
    return True, "lane PASS on head"


def runner_waits_on_audit(comments: list[dict]) -> bool:
    """The newest lane report says the runner won't merge until a Codex audit exists."""
    c = newest_lane_comment(comments)
    return c is not None and bool(_RUNNER_WAITS_RE.search(comment_body(c)))


def head_audit(comments: list[dict], head_sha: str) -> tuple[str, str] | None:
    """(created_at, verdict line) of the newest audit whose heading names the head.

    The verdict line is the first non-empty line after the heading, as the
    runner reads it (#441).
    """
    best = None
    for c in comments:
        if not is_audit_comment(c):
            continue
        heading, _, rest = comment_body(c).lstrip().partition("\n")
        if not names_sha(heading, head_sha):
            continue
        verdict = next((line.strip() for line in rest.splitlines() if line.strip()), "")
        if best is None or comment_time(c) >= best[0]:
            best = (comment_time(c), verdict)
    return best


def rearm_decision(pr: dict, comments: list[dict],
                   label_events: list[dict] | None) -> tuple[bool, str]:
    """Whether to remove and re-add automerge so the runner merges after a clean audit.

    `label_events` (the PR's issue events) may be None until every other check
    passes; the result is then (False, "need events").
    """
    head = pr["headRefOid"]
    if pr.get("isDraft"):
        return False, "draft"
    if AUTOMERGE not in [lab.get("name") for lab in pr.get("labels") or []]:
        return False, "no automerge label"
    audit = head_audit(comments, head)
    if audit is None:
        return False, "no audit of the head"
    audited_at, verdict = audit
    if not _CLEAN_AUDIT_RE.match(verdict):
        return False, "audit of the head has findings"
    ok, why = lane_pass_for_head(comments, head)
    if not ok:
        return False, why
    if newest_lane_report(comments)[2] > audited_at:
        return False, "the lane ran after the audit"
    if label_events is None:
        return False, "need events"
    for e in label_events:
        if e.get("event") == "labeled" and (e.get("label") or {}).get("name") == AUTOMERGE \
                and (e.get("created_at") or "") > audited_at:
            return False, "automerge re-added after the audit already"
    return True, "clean audit of the head, lane not run since"


def risky_areas(paths: list[str]) -> list[str]:
    areas = []
    for area, pats in _RISKY_RE.items():
        for p in paths:
            if _NEVER_RISKY_RE.search(p):
                continue
            if any(r.search(p) for r in pats):
                areas.append(area)
                break
    return areas


def counted_lines(files: list[dict]) -> int:
    """Additions + deletions, leaving out research/ and fixtures."""
    total = 0
    for f in files:
        path = f.get("filename") or f.get("path") or ""
        if _UNCOUNTED_RE.search(path):
            continue
        total += int(f.get("additions", 0)) + int(f.get("deletions", 0))
    return total


def asks_for_audit(text: str) -> bool:
    if _REQUEST_CMD_RE.search(text):
        return True
    for m in _REQUEST_RE.finditer(text):
        before = text[max(0, m.start() - 25): m.start()]
        inside = m.group(0)
        if _NEGATION_RE.search(before) or re.search(r"(?i)\b(no|not)\b|n't\b", inside):
            continue
        return True
    return False


def audit_requested(comments: list[dict]) -> bool:
    """A comment asks for a Codex audit, newer than the newest audit comment."""
    audits = [comment_time(c) for c in comments if is_audit_comment(c)]
    since = max(audits) if audits else ""
    for c in comments:
        if is_audit_comment(c) or parse_lane_report(c):
            continue
        if comment_time(c) > since and asks_for_audit(comment_body(c)):
            return True
    return False


def linked_issue_numbers(pr: dict) -> list[int]:
    nums: list[int] = []
    for ref in pr.get("closingIssuesReferences") or []:
        if ref.get("number"):
            nums.append(int(ref["number"]))
    body = pr.get("body") or ""
    for m in re.finditer(r"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", body):
        nums.append(int(m.group(1)))
    for m in re.finditer(r"\(#(\d+)", pr.get("title") or ""):
        nums.append(int(m.group(1)))
    out: list[int] = []
    for n in nums:
        if n not in out and n != pr.get("number"):
            out.append(n)
    return out[:3]


def evaluate_pr(pr: dict, comments: list[dict], files: list[dict] | None,
                issue_comments: list[dict] | None = None) -> tuple[bool, str]:
    """Decide whether one PR is a candidate. Returns (candidate, reason).

    `files` may be None when the caller hasn't fetched them yet (the earlier
    gates don't need them); the result is then (False, "need files").
    """
    head = pr["headRefOid"]
    if pr.get("isDraft"):
        return False, "draft"
    if pr.get("baseRefName", BASE_BRANCH) != BASE_BRANCH:
        return False, f"base is {pr.get('baseRefName')}"
    if audited_on(comments, head):
        return False, "already audited on head"
    ok, why = lane_pass_for_head(comments, head)
    if not ok:
        return False, why
    if files is None:
        return False, "need files"
    areas = risky_areas([f.get("filename") or f.get("path") or "" for f in files])
    if areas:
        return True, "risky: " + ",".join(areas)
    if runner_waits_on_audit(comments):
        return True, "runner waits on an audit"
    if audit_requested(comments + (issue_comments or [])):
        return True, "audit requested"
    return False, "not risky, no request"


def make_batches(prs: list[tuple[int, int]]) -> list[list[int]]:
    """Group (number, lines) into batches, keeping the given order.

    A PR over SOLO_OVER_LINES is alone. Others fill batches of up to
    BATCH_MAX_PRS PRs and BATCH_MAX_LINES lines, first fit in order.
    """
    batches: list[list[int]] = []
    cur: list[int] = []
    cur_lines = 0
    for num, lines in prs:
        if lines > SOLO_OVER_LINES:
            batches.append([num])
            continue
        if cur and (len(cur) >= BATCH_MAX_PRS or cur_lines + lines > BATCH_MAX_LINES):
            batches.append(cur)
            cur, cur_lines = [], 0
        cur.append(num)
        cur_lines += lines
    if cur:
        batches.append(cur)
    return batches


_ISSUE_LABEL_RE = re.compile(
    r"^\s*(?:#{1,6}\s*)?(?:\*\*)?\s*(Done when|Must not break)\s*[:.]?\s*(?:\*\*)?\s*[:.]?\s*(.*)$",
    re.I,
)
_SECTION_END_RE = re.compile(r"^\s*(\*\*[^*]+\*\*|#{1,6}\s|---|___)")


def issue_sections(body: str) -> dict[str, str]:
    """Pull "Done when" and "Must not break" out of an issue body."""
    out: dict[str, str] = {}
    lines = (body or "").splitlines()
    i = 0
    while i < len(lines):
        m = _ISSUE_LABEL_RE.match(lines[i])
        if not m:
            i += 1
            continue
        key = "Done when" if m.group(1).lower().startswith("done") else "Must not break"
        chunk = [m.group(2).strip()] if m.group(2).strip() else []
        i += 1
        while i < len(lines) and not _SECTION_END_RE.match(lines[i]) \
                and not _ISSUE_LABEL_RE.match(lines[i]):
            chunk.append(lines[i].rstrip())
            i += 1
        text = "\n".join(chunk).strip()
        if text and key not in out:
            out[key] = text[:BODY_CHARS]
    return out


_PR_HEADING_RE = re.compile(r"(?im)^\s*#{1,6}\s*\**\s*PR\s*#(\d+)\b.*$")


def split_sections(output: str, numbers: list[int]) -> dict[int, str]:
    """Split Codex's answer into {pr_number: section text} by "### PR #N"."""
    marks = [(m.start(), m.end(), int(m.group(1))) for m in _PR_HEADING_RE.finditer(output or "")]
    out: dict[int, str] = {}
    for idx, (_, end, num) in enumerate(marks):
        stop = marks[idx + 1][0] if idx + 1 < len(marks) else len(output)
        text = output[end:stop].strip()
        if num in numbers and text and num not in out:
            out[num] = text
    return out


def build_comment(number: int, sha: str, section: str, batch: list[int]) -> str:
    lines = [f"**Codex audit (Astra) on `{sha[:7]}`**", "", section.strip(), "", "---"]
    footer = FOOTER
    others = [n for n in batch if n != number]
    if others:
        footer += " Batched with " + ", ".join(f"#{n}" for n in others) + "."
    lines.append(footer)
    return "\n".join(lines) + "\n"


def parse_limits(stdout: str, returncode: int) -> tuple[bool, str]:
    """Read codex_limits.py output. Returns (ok_to_run, reason)."""
    if returncode != 0:
        tail = (stdout or "").strip().splitlines()[-1:] or ["no output"]
        return False, f"limits unavailable ({tail[0][:120]})"
    worst = None
    for line in (stdout or "").splitlines():
        m = re.match(r"\s*(primary|secondary):\s*(.*)$", line)
        if not m or m.group(2).strip() == "None":
            continue
        try:
            win = ast.literal_eval(m.group(2).strip())
        except (ValueError, SyntaxError):
            continue
        used = win.get("usedPercent") if isinstance(win, dict) else None
        if used is None:
            continue
        if worst is None or used > worst[0]:
            worst = (used, m.group(1), win.get("resetsAt"))
    if worst is None:
        return False, "limits unavailable (no usage windows in output)"
    used, name, resets = worst
    if used >= EXHAUSTED_PERCENT:
        when = ""
        if resets:
            when = " until " + _dt.datetime.fromtimestamp(int(resets)).strftime("%Y-%m-%d %H:%M")
        return False, f"codex {name} limit used up ({used}%){when}"
    return True, f"codex {name} limit at {used}%"


# ---------------------------------------------------------------------------
# Side-effecting parts
# ---------------------------------------------------------------------------


def now() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg: str, echo: bool = True) -> None:
    OPS_DIR.mkdir(parents=True, exist_ok=True)
    line = f"{now()} {msg}"
    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    if echo:
        print(line, flush=True)


def run(cmd: list[str], *, cwd: Path | None = None, check: bool = True,
        timeout: float | None = 300, stdin=subprocess.DEVNULL) -> subprocess.CompletedProcess:
    res = subprocess.run(cmd, cwd=cwd, stdin=stdin, capture_output=True, text=True, timeout=timeout)
    if check and res.returncode != 0:
        raise RuntimeError(f"{cmd[0]} {' '.join(cmd[1:4])}… failed: {res.stderr.strip()[:300]}")
    return res


def gh_json_lines(path: str) -> list[dict]:
    res = run(["gh", "api", "--paginate", path, "--jq", ".[]"], cwd=REPO_ROOT)
    return [json.loads(line) for line in res.stdout.splitlines() if line.strip()]


def fetch_open_prs(only: int | None) -> list[dict]:
    fields = "number,title,body,isDraft,headRefOid,baseRefName,closingIssuesReferences,url,labels"
    if only is not None:
        res = run(["gh", "pr", "view", str(only), "--repo", REPO, "--json", fields + ",state"], cwd=REPO_ROOT)
        pr = json.loads(res.stdout)
        return [pr] if pr.get("state") == "OPEN" else []
    res = run(["gh", "pr", "list", "--repo", REPO, "--base", BASE_BRANCH, "--state", "open",
               "--limit", "200", "--json", fields], cwd=REPO_ROOT)
    return json.loads(res.stdout)


def fetch_comments(number: int) -> list[dict]:
    return gh_json_lines(f"repos/{REPO}/issues/{number}/comments?per_page=100")


def fetch_files(number: int) -> list[dict]:
    return gh_json_lines(f"repos/{REPO}/pulls/{number}/files?per_page=100")


def fetch_label_events(number: int) -> list[dict]:
    return gh_json_lines(f"repos/{REPO}/issues/{number}/events?per_page=100")


REARMED: set[int] = set()  # PRs this process re-armed, so the end-of-run pass skips them


def rearm_pass(prs: list[dict], dry_run: bool) -> None:
    """Remove and re-add automerge where rearm_decision says so (see the module docstring).

    Runs after each audit batch for that batch's PRs, then once for every PR
    at the end of the run. Reads each PR afresh, since this run may have just
    posted its audit.
    """
    for listed in sorted(prs, key=lambda p: p["number"]):
        n = listed["number"]
        if n in REARMED or AUTOMERGE not in [lab.get("name") for lab in listed.get("labels") or []]:
            continue
        try:
            fresh = fetch_open_prs(n)
            if not fresh:
                continue
            pr = fresh[0]
            comments = fetch_comments(n)
            ok, why = rearm_decision(pr, comments, None)
            if why == "need events":
                ok, why = rearm_decision(pr, comments, fetch_label_events(n))
            if not ok:
                if dry_run:
                    print(f"  re-arm #{n}: no ({why})")
                continue
            if dry_run:
                log(f"dry-run: would re-arm #{n} on {pr['headRefOid'][:7]} ({why})")
                continue
            edit = ["gh", "pr", "edit", str(n), "--repo", REPO]
            removed = run(edit + ["--remove-label", AUTOMERGE], cwd=REPO_ROOT, check=False)
            if removed.returncode != 0:
                log(f"re-arm #{n} failed: couldn't remove {AUTOMERGE}: {removed.stderr.strip()[:160]}")
                continue
            for _ in range(3):  # never leave the PR without the label it had
                added = run(edit + ["--add-label", AUTOMERGE], cwd=REPO_ROOT, check=False)
                if added.returncode == 0:
                    break
                time.sleep(5)
            REARMED.add(n)  # the label was removed, so don't touch this PR again this run
            if added.returncode == 0:
                log(f"re-armed #{n} on {pr['headRefOid'][:7]}: removed and re-added {AUTOMERGE} ({why})")
            else:
                log(f"re-arm #{n} FAILED: {AUTOMERGE} removed but not re-added after 3 tries; "
                    f"add it back by hand: {added.stderr.strip()[:160]}")
        except Exception as exc:  # log and move on to the next PR
            log(f"re-arm #{n}: error: {exc}")


def fetch_issue(number: int) -> dict | None:
    res = run(["gh", "api", f"repos/{REPO}/issues/{number}"], cwd=REPO_ROOT, check=False)
    if res.returncode != 0:
        return None
    return json.loads(res.stdout)


def find_candidates(prs: list[dict]) -> tuple[list[dict], dict[str, int], list[tuple[int, str]]]:
    """Returns (candidates, skip-reason counts, per-PR decisions)."""
    cands: list[dict] = []
    skips: dict[str, int] = {}
    decisions: list[tuple[int, str]] = []
    for pr in sorted(prs, key=lambda p: p["number"]):
        n = pr["number"]
        if pr.get("isDraft"):
            ok, why = False, "draft"
            comments: list[dict] = []
        else:
            comments = fetch_comments(n)
            ok, why = evaluate_pr(pr, comments, None)
            if why == "need files":
                files = fetch_files(n)
                ok, why = evaluate_pr(pr, comments, files)
                issue_comments: list[dict] = []
                issues = linked_issue_numbers(pr)
                if not ok and why == "not risky, no request":
                    for inum in issues:
                        issue_comments += fetch_comments(inum)
                    ok, why = evaluate_pr(pr, comments, files, issue_comments)
                if ok:
                    rep = newest_lane_report(comments)
                    cands.append({
                        **pr,
                        "comments": comments,
                        "files": files,
                        "lines": counted_lines(files),
                        "ready_at": rep[2] if rep else "",
                        "issues": issues,
                        "reason": why,
                    })
        decisions.append((n, why))
        if not ok:
            key = {
                "already audited on head": "audited",
                "no lane report": "no lane report",
                "newest lane report on the head is FAIL": "lane FAIL",
                "not risky, no request": "not risky",
            }.get(why, "lane report not on head" if why.startswith("newest lane report is on") else why)
            skips[key] = skips.get(key, 0) + 1
    cands.sort(key=lambda c: (c["ready_at"], c["number"]))  # oldest ready first
    return cands, skips, decisions


def check_limits() -> tuple[bool, str]:
    if not LIMITS_SCRIPT.exists():
        return False, "limits unavailable (codex_limits.py missing)"
    try:
        res = subprocess.run(["/usr/bin/python3", str(LIMITS_SCRIPT)], cwd=REPO_ROOT,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             timeout=LIMITS_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return False, "limits unavailable (codex_limits.py timed out)"
    return parse_limits(res.stdout, res.returncode)


def pr_context_block(c: dict, issue_texts: dict[int, dict[str, str]], diff_rel: str,
                     base_sha: str, merge_base: str) -> str:
    parts = [
        f"## PR #{c['number']}: {c['title']}",
        f"Head commit: {c['headRefOid']} (merge base with next: {merge_base}).",
        f"Diff file: {diff_rel} ({c['lines']} changed lines, research/ left out).",
        f"Read its code at the head with `git show {c['headRefOid'][:12]}:<path>`.",
        "",
        "PR description:",
        (c.get("body") or "(none)").strip()[:BODY_CHARS],
    ]
    for inum in c["issues"]:
        secs = issue_texts.get(inum) or {}
        if not secs:
            continue
        parts.append("")
        parts.append(f"Linked issue #{inum}:")
        for key in ("Done when", "Must not break"):
            if key in secs:
                parts.append(f"{key}:\n{secs[key]}")
    return "\n".join(parts)


def build_prompt(batch: list[dict], blocks: list[str], base_sha: str) -> str:
    nums = ", ".join(f"#{c['number']}" for c in batch)
    head = [
        f"You are auditing {'this pull request' if len(batch) == 1 else 'these pull requests'} "
        f"({nums}) into `next` of Spoken Margins, read-only.",
        f"The working directory is a checkout of origin/next at {base_sha}. Each PR's head "
        "commit is fetched into this repository, and each PR's diff is in the file named "
        "below. Read AGENTS.md first; its hard rules apply.",
        "Do not build, run tests, boot simulators or run xcodebuild. Review each PR on its own.",
        "",
    ]
    tail = [
        "",
        "Instruction for each PR: " + INSTRUCTION,
        "",
        "Answer format: one section per PR, in the order given, each starting with a heading "
        "line exactly `### PR #<number>`. Nothing before the first heading. Every PR gets a "
        'section, even if it only says "No blocking findings."',
    ]
    return "\n".join(head + blocks + tail)


def kill_tree(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=20)
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass


def run_codex(worktree: Path, out_file: Path, prompt: str, transcript: Path) -> tuple[bool, str]:
    cmd = [
        CODEX, "exec",
        "-m", CODEX_MODEL,
        "-c", 'model_reasoning_effort="high"',
        "-s", "read-only",
        "-C", str(worktree),
        "-o", str(out_file),
        prompt,
    ]
    with open(os.devnull, "rb") as devnull, open(transcript, "wb") as tfh:
        proc = subprocess.Popen(cmd, stdin=devnull, stdout=tfh, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=CODEX_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            return False, f"timed out after {CODEX_TIMEOUT_S // 60} min"
    if rc != 0:
        tail = transcript.read_text(errors="replace").strip().splitlines()[-1:] or [""]
        return False, f"codex exit {rc}: {tail[0][:160]}"
    if not out_file.exists() or not out_file.read_text(errors="replace").strip():
        return False, "codex wrote no answer"
    return True, "ok"


def audit_batch(batch: list[dict]) -> None:
    nums = [c["number"] for c in batch]
    label = ",".join(f"#{n}" for n in nums)
    tmp = Path(tempfile.mkdtemp(prefix="sm-audit-"))
    worktree = tmp / "wt"
    added = False
    t0 = time.time()
    try:
        run(["git", "fetch", "--quiet", "origin", BASE_BRANCH], cwd=REPO_ROOT, timeout=600)
        base_sha = run(["git", "rev-parse", f"origin/{BASE_BRANCH}"], cwd=REPO_ROOT).stdout.strip()
        live: list[dict] = []
        for c in batch:
            run(["git", "fetch", "--quiet", "origin", f"pull/{c['number']}/head"], cwd=REPO_ROOT, timeout=600)
            fetched = run(["git", "rev-parse", "FETCH_HEAD"], cwd=REPO_ROOT).stdout.strip()
            if fetched != c["headRefOid"]:
                log(f"batch {label}: #{c['number']} head moved to {fetched[:7]} since listing; left for the next run")
                continue
            live.append(c)
        if not live:
            return
        run(["git", "worktree", "add", "--detach", "--quiet", str(worktree), base_sha], cwd=REPO_ROOT)
        added = True
        diff_dir = worktree / ".sm-audit"
        diff_dir.mkdir()
        blocks = []
        for c in live:
            head = c["headRefOid"]
            mb = run(["git", "merge-base", base_sha, head], cwd=REPO_ROOT).stdout.strip()
            diff = run(["git", "diff", "--no-color", mb, head, "--", ".",
                        ":(exclude)research/**", ":(exclude)**/research/**"],
                       cwd=REPO_ROOT, timeout=300).stdout
            rel = f".sm-audit/pr-{c['number']}.diff"
            (worktree / rel).write_text(diff, encoding="utf-8")
            issue_texts: dict[int, dict[str, str]] = {}
            for inum in c["issues"]:
                issue = fetch_issue(inum)
                if issue and not issue.get("pull_request"):
                    issue_texts[inum] = issue_sections(issue.get("body") or "")
            blocks.append(pr_context_block(c, issue_texts, rel, base_sha, mb))
            blocks.append("")
        prompt = build_prompt(live, blocks, base_sha)
        out_file = tmp / "answer.md"
        transcript = tmp / "transcript.txt"
        ok, why = run_codex(worktree, out_file, prompt, transcript)
        took = int(time.time() - t0)
        if not ok:
            log(f"batch {','.join('#' + str(c['number']) for c in live)}: codex failed after {took}s ({why}); nothing posted")
            return
        answer = out_file.read_text(encoding="utf-8", errors="replace")
        OUTPUT_KEEP_DIR.mkdir(parents=True, exist_ok=True)
        stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        (OUTPUT_KEEP_DIR / f"{stamp}-{'-'.join(str(c['number']) for c in live)}.md").write_text(answer, encoding="utf-8")
        live_nums = [c["number"] for c in live]
        sections = split_sections(answer, live_nums)
        results = []
        for c in live:
            n, head = c["number"], c["headRefOid"]
            if n not in sections:
                results.append(f"#{n} no section in Codex's answer, nothing posted")
                continue
            if audited_on(fetch_comments(n), head):
                results.append(f"#{n} audited by someone else meanwhile, nothing posted")
                continue
            body_file = tmp / f"comment-{n}.md"
            body_file.write_text(build_comment(n, head, sections[n], live_nums), encoding="utf-8")
            res = run(["gh", "pr", "comment", str(n), "--repo", REPO, "--body-file", str(body_file)],
                      cwd=REPO_ROOT, check=False)
            results.append(f"#{n} posted" if res.returncode == 0 else f"#{n} post failed: {res.stderr.strip()[:120]}")
        log(f"batch {','.join('#' + str(x) for x in live_nums)}: codex {took}s ok; " + "; ".join(results))
    except Exception as exc:  # log and move on to the next batch
        log(f"batch {label}: error after {int(time.time() - t0)}s: {exc}")
    finally:
        if added:
            subprocess.run(["git", "worktree", "remove", "--force", str(worktree)], cwd=REPO_ROOT,
                           capture_output=True, text=True)
            subprocess.run(["git", "worktree", "prune"], cwd=REPO_ROOT, capture_output=True, text=True)
        shutil.rmtree(tmp, ignore_errors=True)


def describe(cands: list[dict], batches: list[list[int]]) -> tuple[str, str]:
    by_num = {c["number"]: c for c in cands}
    cand_s = " ".join(f"#{c['number']}({c['lines']}L,{c['reason']})" for c in cands)
    batch_s = " ".join(
        "[" + ",".join(f"#{n}" for n in b) + f" {sum(by_num[n]['lines'] for n in b)}L]" for b in batches
    )
    return cand_s, batch_s


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="print candidates and batches; no Codex, no posting")
    ap.add_argument("--pr", type=int, help="consider only this PR")
    args = ap.parse_args(argv)
    tag = "dry-run " if args.dry_run else ""

    OPS_DIR.mkdir(parents=True, exist_ok=True)
    lock_fh = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log(f"{tag}skipped: another run holds the lock")
        return 0
    lock_fh.write(str(os.getpid()))
    lock_fh.flush()

    t0 = time.time()
    try:
        prs = fetch_open_prs(args.pr)
    except Exception as exc:
        log(f"{tag}error listing PRs: {exc}")
        return 1
    try:
        return audit_prs(prs, args.dry_run, tag, t0)
    finally:
        rearm_pass(prs, args.dry_run)


def audit_prs(prs: list[dict], dry_run: bool, tag: str, t0: float) -> int:
    try:
        cands, skips, decisions = find_candidates(prs)
    except Exception as exc:
        log(f"{tag}error listing PRs: {exc}")
        return 1

    if dry_run:
        print("Per-PR decisions:")
        for n, why in decisions:
            print(f"  #{n}: {why}")

    if not cands:
        skip_s = "; ".join(f"{k}: {v}" for k, v in sorted(skips.items()))
        log(f"{tag}idle: {len(prs)} open PRs into {BASE_BRANCH}, 0 candidates ({skip_s}) in {time.time() - t0:.1f}s")
        return 0

    batches = make_batches([(c["number"], c["lines"]) for c in cands])
    cand_s, batch_s = describe(cands, batches)

    if dry_run:
        log(f"dry-run: candidates {cand_s}; batches {batch_s}; no Codex, nothing posted")
        return 0

    ok, why = check_limits()
    if not ok:
        log(f"paused: {why}; candidates {cand_s} not audited")
        return 0
    log(f"run: {why}; candidates {cand_s}; batches {batch_s}")

    by_num = {c["number"]: c for c in cands}
    for b in batches:
        audit_batch([by_num[n] for n in b])
        rearm_pass([by_num[n] for n in b], False)
    log(f"done in {int(time.time() - t0)}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
