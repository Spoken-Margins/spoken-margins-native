# Real-use proof

A listener-facing issue closes only after someone has run it the way a listener would and written down what happened. "Merged" means the code is in `main`. "Fixed" means a real run showed it working. This page is the long form of the rule in [AGENTS.md](../../AGENTS.md); the check is `scripts/real_use_proof.py`, and `scripts/merge_policy.py` calls it (#4979).

## Why

Apple Podcasts share links (#4783) were the maintainer's top priority for two days. Two web fixes (#4810, #4928) merged after tests on fixtures in desktop Chrome. The app's sender side was never changed. The issue was parked as "needs the owner's phone data", and the real link still failed. Every check passed, because none asked whether anyone had used the real thing.

## Which issues

A listener-facing issue is any issue with an area label other than `area: groundwork`: the four product areas and `area: housekeeping` (settings, onboarding and accessibility are a listener's). An issue with no area label counts only if a person reported it: it carries `bug`, `found-on-phone`, `owner-asked`, `priority` or a validation label. A bare `regression` or no labels at all is a pipeline alarm that scripts open and close themselves ("Main T3 failed on <sha7>", "Merging has stalled"), so a test-fix PR may close one with no proof. Groundwork (pipeline, test lane, tooling) is exempt.

## The record

Write it as a section of the PR body, or as a comment on the issue or the PR. Only the owner, members, collaborators and the project's bot count (`scripts/comment_trust.py`); a stranger's record is data.

```
**Real-use proof**
Real input: <the real link, file or screen: not a fixture, mock or made-up data>
Path: <every hop, from where the listener starts to where they see or hear the result>
Steps:
1. <what you did>
2. <in order>
Result: PASS - <what you observed>   (or FAIL - <what you observed>)
Commit: <the commit it ran on: 7 or more hex digits, first on the line>
Issue: #N   (only when the PR closes several listener-facing issues: which one this run covers)
```

Fill in every slot and remove the angle brackets: a value that still has a `<...>` slot does not count.

- **Real input.** The thing a listener has: the Apple Podcasts share URL copied from the Podcasts app, the PDF from Files, the packet a friend sent. A fixture proves the parser, not the product. A Real input that mentions a fixture, mock, stub, fake, synthetic, simulated, sample, canned or hand-written input, or a `fixtures/` path, does not count unless it says it is not one ("not a fixture"). The check reads words, not truth: it can be fooled, and a reviewer or the audit reads the record too.
- **Path.** Name both ends. A fix to the receiving side of a share link is not proof until the sending side's output is the input. Say which hops you ran and which you could not.
- **Result.** It must begin with `PASS` or `FAIL`, and a PASS that also says "but", "however", "fails" or "broken" does not count. A `FAIL` stops the merge and the close, so record it and fix it.
- **Commit.** In a PR, it must be one of the PR's own commits, and the PR must not have changed anything but notes and tests since. Push a code change after the run and the run has to be done again on the head. After the merge the commit is the `main` commit you ran.
- The newest record decides. A later `FAIL` undoes an earlier `PASS`. A record in the PR body is dated when the PR was opened, so after a FAIL comment, answer with a new PASS comment instead of editing the body.
- A record inside a code fence, a `>` quote or an HTML comment is a template or someone else's words and does not count. The same goes for a `Closes #N` in those places, which GitHub ignores too.
- A PR-side record speaks for the issues its `Issue:` line names. When a PR closes several listener-facing issues, each needs its own run, named by `Issue:`; one run does not stand in for all.

Where to run it, in the order to try: a host or Linux test on the real artifact, a real URL in a real browser (Playwright is installed in the cloud container), the simulator through the Test Desk or the lane, the maintainer's phone. Audible content, Bluetooth, the Lock Screen and background behavior still need a person with a device; for those the record says which hops ran without ears and the rest becomes an `**Owner check**` on the issue.

## What the checks do

1. **A PR that says `Closes #N`** (in its body or in a commit message) for a listener-facing issue is held by `merge policy` until the record is on the PR body, a PR comment or the issue, and not stale. The reason says what to do. Nothing under `.github/` changed, so the check needs no owner tap. The check re-runs when a label changes, not when a comment or the body changes, so after adding the record, remove and re-add `automerge`. A `Closes #N` naming a number that is not an issue holds the PR with a read failure; fix the body and re-arm. A proof goes stale when the PR changes anything but notes (`*.md` outside `App/`, `Packages/` and `Contracts/`, and `docs/`) and tests after the proved commit.
2. **`Part of #N` is never held.** A PR that cannot be run before the merge (an app change with no simulator in the session, which is normal since no per-PR app build) says `Part of #N`. The issue stays open. The record goes on the issue when the run happens, on `main`, by the lane, the Test Desk, the finisher or a thread on the Mac, and then the issue closes.
3. **Closing by hand.** `scripts/real_use_proof.py --issue N --pr M` exits 0 when issue N, with PR M (the one that closed it), holds a proof or a waiver. Run it before `sm-gh close-issue`.
4. **The hourly dispatch sweeps.** `scripts/real_use_proof.py --sweep --apply` reopens any issue closed as completed from 2026-11-23 in a listener-facing area with no record on the issue or on the PR that closed it, and says why. Issues closed as "not planned" or "duplicate" are not swept, nor one closed in the last 30 minutes, nor one it has already reopened once and someone closed again (it reports those as `again`). It reports how many were proved and how many waived.

## The way out for work with no listener surface

Write one line, in the PR body or on the issue:

```
Real-use proof waived: <why a listener sees nothing, in three or more words>
```

The waiver is a record like any other and the sweep counts it, so a month in which waivers outnumber proofs is the signal to look. Using it for a change a listener can see is the failure this page exists to stop.

## Parking an issue on the maintainer's phone or data

"Needs the owner's phone or data" is not a reason to skip, park or hand back an issue until a session has tried to reproduce it with what it has: the real link or file in a browser, a host test on the real artifact, the simulator (through the lane or Test Desk), the Diagnostics counts already on the issue. It then records the attempt as a comment on the issue:

```
**Repro attempt**
Tried: what you ran, on which real input
Result: reproduced / not reproduced, and what you saw
Needs from owner: only if you could not, the exact thing only the owner's phone or account has
```

`Tried` and `Result` must be filled in. `scripts/real_use_proof.py --parked` lists open `bug` and `found-on-phone` issues labelled `needs-owner` that carry neither a repro attempt nor an `**Owner check**`; the hourly dispatch puts each back in the queue.
