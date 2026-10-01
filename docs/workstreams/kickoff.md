# Starting and running a stream

## The kickoff prompt

Paste this into a new session, filling in the stream ID. Keep the prompt this short: the brief carries the goal, and `AGENTS.md` carries the rules.

```text
You own stream <ID> of Spoken Margins. Read AGENTS.md, docs/workstreams/README.md,
docs/workstreams/streams/<ID>-*.md, and only the seams in docs/workstreams/interfaces.md
that the brief names.

Branch: ws/<id>-<milestone> from origin/next, a new one for each PR, or from
origin/claude/project-planning-voice-notes-neoatx if next doesn't exist yet. Merge origin/next in at least daily once it exists. Cloud
research code and fixtures go under research/<id>/. Open a draft PR into next once it
exists, and put lane requests on that PR.

Work milestone by milestone. For each milestone:
1. Say in two or three sentences how you intend to reach it and what you will measure.
   For a choice the brief leaves open, or an owner decision it lists: if it's
   reversible, post it on the tracking issue under "Default taken" (options, your
   pick, why) and keep going on your pick. Stop and ask only when it touches the
   owner's data, packet or database compatibility, money, anything public, main or a
   release, or taste (design, voice).
2. Work until the milestone's "Done when" items hold, leaving out items marked (owner)
   or (Mac), and show the evidence for each one in the PR. A lane item holds once the
   PR is armed (docs/workstreams/README.md, "Done when"). Never stop mid-PR. If 40
   turns pass without progress, stop and report on the tracking issue.
3. When it is met: arm the PR (automerge, plus a /lane T3 request if the diff needs
   one), and comment on the tracking issue with what changed, the evidence, exact steps
   for any (owner) items, and what is next. Then start the next milestone on a new
   branch, or, above about 250,000 tokens of context, post a short note and stop so a
   fresh session takes it. No timers or check-ins on your PRs.

Use sub-agents for read-only exploration (never read Gate1AppModel.swift whole).
Before arming the PR, have a fresh sub-agent review the diff against the brief and
fix only real gaps.
```

Why it's shaped this way:

- **`/goal` holds the agent to the endpoint.** It's a command the person who started the session types, not something the agent can run. After the agent posts its approach, send `/goal <the milestone's "Done when", minus (owner) and (Mac) items, with lane items read as "the PR is armed">` as the next message. After each turn, a separate evaluator checks the condition against what the agent has shown in the transcript, and the agent keeps working until it's met ([docs](https://code.claude.com/docs/en/goal)). Without it, the agent still works toward the same list; `/goal` just stops it from declaring victory early. That's why every "Done when" in the briefs is written as something the agent can *demonstrate* (a test output, a measured number, a tap count, an armed PR), not something it can merely assert.
- **Items marked (owner) stay out of the goal.** Listening by ear, measurements on the owner's phone, and data only the owner has can't be demonstrated by an agent. The agent prepares them (a build, exact steps, what to look for) and the milestone waits on the owner.
- **Stating the approach first** gives the owner a moment to redirect from the phone before hours go into the wrong idea. It isn't a request for approval; the agent continues unless redirected.
- **Defaults instead of waits.** On 2026-09-28 about 15 owner decisions reached the owner one at a time, and several were reversible: which simulator the lane uses, C3's pause behavior, whether author names are read aloud. Streams now take a default for those and keep going. The project's daily routine lists the last day's "Default taken" posts so the owner can veto in one batch.
- **A turn cap** stops a stuck stream from burning a day. Blocked is a legitimate outcome if it's reported.
- **A fresh-context review** before a milestone catches the "looks done" failure without an auditor agent chain ([best practices](https://code.claude.com/docs/en/best-practices#add-an-adversarial-review-step)). Tell the reviewer to flag only gaps against the brief's "Done when" and "Must not break", or it will invent work.

## The lead session

Retired on 2026-09-29. A long-lived triage desk re-read a large context on every turn and took most of the owner's messages, so its jobs moved to owners that start fresh:

| Job | Who does it now |
| --- | --- |
| Hand out work: one thread per `ready` issue, in the order the project's instructions give | The owner's Claude Code project |
| Triage new and `critic:*` issues daily: `ready`, `needs-owner`, `deferred`, or closed as a duplicate | The project, in its daily routine (21:30 Eastern) |
| Decisions, defaults the streams took, and phone candidates, for the owner | The project conversation |
| Pace, runner queue, disk, memory, the main checkout, and the daily scorecard | The `SM Mac tick` scheduled task, every two hours, posting on #337. It doesn't merge. |
| Merge finished work | The lane runner merges `automerge` PRs it passes. After a T3 PASS on a PR held for T3, it re-runs the automerge checks on a fresh merge commit and merges on PASS (#421). It never merges `.github/` or `scripts/lane*` changes (those wait for the owner), or an audio, persistence, packet or lane diff without a clean Codex audit of its head commit. |
| Lane FAILs on armed PRs | The project's hourly dispatcher. A FAIL on the PR's own code goes to whoever is free. A lane fault gets one more run (a new `/lane T3` comment with the same `tests:` line plus `lane:queued` for an INCONCLUSIVE T3, or `automerge` removed and re-added for a host-test or build fault), and becomes an issue labelled `ready` and `regression` only if it fails the same way again. After a clean Codex audit on a held PR, it removes and re-adds `automerge`, because a comment starts no run. The thread that armed the PR has already moved on. |
| Codex audits of sharing, persistence, audio and lane changes | A scheduled script on the Mac (launchd, no Claude session), posting **Codex audit (Astra) on `<sha7>`** on the PR |
| Test next's tip | The standing Test Desk, in a loop: on each new tip, the app tests, then the screen tour and the journeys, reported on #184. On a real FAIL it reverts the culprit merge and files the re-land issue. The scheduled `SM integration run` is its understudy and runs only when the desk has posted nothing on #184 for three hours ([test-lane.md](test-lane.md), Starting the Test Desk). |
| Check that the scheduled tasks ran | The project's daily routine reads #337 for a missing or stalled tick. The owner starts an ops desk session only when something is wrong. |

The merge-check comment keeps its old first line, **Merge check (triage desk) on `<sha7>`**. The lane runner writes it and `scripts/merge_audit.py` looks for that exact text, so don't reword it.

## Model and effort

- **Default:** Opus 5.5 at high effort for every stream.
- **Go higher (xhigh or max)** for A2 `seams` (both milestones), the first milestone of F1 `coop`, and B4 `bridge` M1 and E3 `maps` M2, which set the server and privacy shape. Mistakes there are expensive for everyone downstream.
- **Research streams** (A3, G2, and the research milestones of B3, C1, C2 and E1) can use the `deep-research` skill for literature and market scans.
- **Codex (OpenAI plan)** works from the same briefs, since it reads `AGENTS.md` too. Good uses: a second implementation attempt on a research question (for example the C1 scorer or B3 matcher), or an independent review of a gate stream's PR. Don't put two agents on the same milestone at once.

## Where each kind of stream runs

**Cloud streams** (A3, G2, and the research and server milestones of B3, B4, C1, C2, E1 and E3):

- Start from the Claude app → Code → new session on `uncomposed/spoken-margins-native` (add `uncomposed/digest` for D3). Paste the kickoff.
- Cloud sessions can't reach the Mac's simulators, and can't build the iOS app. A brief marks any step that needs a Mac with **(Mac)**. That step runs in a Mac session, or through the lane as a request on the PR. The cloud agent finishes everything else and says what's waiting.

**Mac streams**:

- Run one Remote Control server on the Mac so the owner can start and steer sessions from the phone:

  ```bash
  cd ~/path/to/spoken-margins-native
  claude remote-control --spawn worktree --capacity 4 --name "SM Mac"
  ```

  Each session started from the phone gets its own git worktree ([docs](https://code.claude.com/docs/en/remote-control)). Capacity 4 is three streams plus the Test Desk. The Mac must stay awake (for example `caffeinate -dims` in another terminal).
- Worktrees are created under `.claude/worktrees/`. By default they start from `main`. With the Mac's main checkout on `next` and `"worktree": {"baseRef": "head"}` in `~/.claude/settings.json` (README → Owner setup), they start from `next`. The kickoff's first step then creates `ws/<id>`.
- Each worktree uses its own DerivedData (`-derivedDataPath .build/dd` inside the worktree). A1 `lane` makes this the default through its build wrapper.

**Talking between sessions**:

- Durable things go on GitHub: requests, reports, decisions, "this seam changed". The owner reads GitHub on the phone.
- Same-Mac sessions can also message each other directly ([cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging)). Use that as a doorbell ("lane request posted on PR #212"), never as the only copy of something another stream needs.

## Repo tooling the streams should have

A1 `lane` ships these in its first milestone, because every Mac stream benefits from day one:

- **A simulator guard hook** in the Mac's user-level `~/.claude/settings.json` (a `PreToolUse` hook): stream sessions can't boot simulators or run simulator test plans; only the Test Desk can. User level, because hooks load when a session starts, and a session that started on a branch without the hook would otherwise run unguarded. This makes the crash-flood risk structural rather than a rule agents must remember.
- **A build wrapper** that limits `xcodebuild` to two concurrent runs Mac-wide and gives each worktree its own DerivedData.
- **`scripts/test-scope.py`**: given a diff, prints the minimum tier from [test-lane.md](test-lane.md) and suggested test filters.
- **Skills** in `.claude/skills/`: `lane-request` (how to ask for a T2–T5 run and read the report) and `journey` (how the Test Desk runs a journey, including the simulator pitfalls in `docs/journeys.md`).
- **`.claude/worktrees/` in `.gitignore`**, and a `.worktreeinclude` for any git-ignored local config a build needs.

Other streams may add a skill when they find a workflow worth reusing, such as C1's corpus scorer or G1's guide regenerator. Keep `CLAUDE.md` and `AGENTS.md` short; per-task knowledge belongs in skills, which load only when relevant ([best practices](https://code.claude.com/docs/en/best-practices#write-an-effective-claude-md)).

## Keeping context clean

- **Fresh session when the context is big.** A session that arms a milestone's PR below about 250,000 tokens goes on to the next milestone; above that, a new session starts it with the kickoff prompt. The tracking issue and git history carry state between sessions. A long session full of corrections performs worse than a fresh one with a sharper prompt.
- **Never read `Gate1AppModel.swift` whole.** Use a search or an Explore sub-agent to find the handful of functions you need.
- **Two failed corrections means start over**: clear the session and write a better prompt with what you learned.

## When a stream is done

A stream is done when every milestone's "Done when" holds. The owner then marks the tracking issue `human_validated` or reopens a milestone with what's wrong. Agents never set `human_validated` (`AGENTS.md`).
