# Starting and running a stream

## The kickoff prompt

Paste this into a new session, filling in the stream ID. Keep the prompt this short: the brief carries the goal, and `AGENTS.md` carries the rules.

```text
You own stream <ID> of Spoken Margins. Read AGENTS.md, docs/workstreams/README.md,
docs/workstreams/streams/<ID>-*.md, and only the seams in docs/workstreams/interfaces.md
that the brief names.

Branch: ws/<id> from origin/next, or from origin/claude/project-planning-voice-notes-neoatx
if next doesn't exist yet. Merge origin/next in at least daily once it exists. Cloud
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
   or (Mac), and show the evidence for each one. If 40 turns pass without progress,
   stop and report on the tracking issue.
3. When it is met: comment on the tracking issue with what changed, the evidence
   (test output, lane report link), exact steps for any (owner) items, and what is next.

Use sub-agents for read-only exploration (never read Gate1AppModel.swift whole).
Before asking for a T4 lane run, have a fresh sub-agent review the diff against the
brief and fix only real gaps.
```

Why it's shaped this way:

- **`/goal` holds the agent to the endpoint.** It's a command the person who started the session types, not something the agent can run. After the agent posts its approach, send `/goal <the milestone's "Done when", minus (owner) and (Mac) items>` as the next message. After each turn, a separate evaluator checks the condition against what the agent has shown in the transcript, and the agent keeps working until it's met ([docs](https://code.claude.com/docs/en/goal)). Without it, the agent still works toward the same list; `/goal` just stops it from declaring victory early. That's why every "Done when" in the briefs is written as something the agent can *demonstrate* (a test output, a measured number, a tap count, a lane report), not something it can merely assert.
- **Items marked (owner) stay out of the goal.** Listening by ear, measurements on the owner's phone, and data only the owner has can't be demonstrated by an agent. The agent prepares them (a build, exact steps, what to look for) and the milestone waits on the owner.
- **Stating the approach first** gives the owner a moment to redirect from the phone before hours go into the wrong idea. It isn't a request for approval; the agent continues unless redirected.
- **Defaults instead of waits.** On 2026-09-28 about 15 owner decisions reached the owner one at a time, and several were reversible: which simulator the lane uses, C3's pause behavior, whether author names are read aloud. Streams now take a default for those, post it on their tracking issue as "Default taken", and keep going. The lead session does not relay them to the owner. On 2026-09-29 the owner asked of one "how is that a decision for me?"
- **A turn cap** stops a stuck stream from burning a day. Blocked is a legitimate outcome if it's reported.
- **A fresh-context review** before a milestone catches the "looks done" failure without an auditor agent chain ([best practices](https://code.claude.com/docs/en/best-practices#add-an-adversarial-review-step)). Tell the reviewer to flag only gaps against the brief's "Done when" and "Must not break", or it will invent work.

## The lead session

One session a day coordinates the streams: it batches decisions for the owner, relays answers, and merges on green. It writes no feature code. Start it fresh each morning, because a long coordinating session degrades, and the issues and PRs carry the state. Paste:

```text
You are today's lead session for Spoken Margins' parallel streams. You coordinate;
you don't write feature code. Read AGENTS.md, docs/workstreams/README.md,
docs/workstreams/test-lane.md, and "The lead session" in docs/workstreams/kickoff.md.

1. Survey, read-only: open PRs into next and their latest lane reports; the latest
   comment on each stream tracking issue (label stream:*); local sessions and
   `git worktree list`; booted simulators; free disk (`df -h /`).
   Check open `merge-audit` labels (`gh pr list --state merged --label merge-audit`
   and `gh issue list --label merge-audit`); push the owner only for ones the owner
   didn't do.
2. Give the owner one digest, short and written for the ear:
   - Decisions only the owner can make, numbered, each with your recommendation
     and what it blocks. Describe every item in plain words: the owner listens to
     replies and won't leave the chat to open a link, so an issue number alone
     means nothing. Put numbers and links in a list at the end.
   - Leave "Default taken" items out. They are the streams' own calls and stay on
     the tracking issues.
   - What merged, what's waiting on the lane, and what's stuck and why.
3. Merge on green (the owner allows this). When a PR's lane report is PASS for its
   current head, merge current next into a temporary worktree of it and re-run the
   tests for what it touches, plus anything on next that uses it. Add T2 through
   scripts/xcodebuild-lane for App/ changes. Before merging, post the merge check as
   a PR comment whose first line starts with **Merge check (triage desk) on `<sha7>`
   (the head you're merging), then what you ran and the results. Then `gh pr ready`
   and `gh pr merge --merge --match-head-commit <full sha>`. A conflict or a failing
   combination goes back to the owning session with the exact failing test. Squash
   only where the PR says so.
   A FAIL counts as passed for that PR only when the failing step is in code the PR
   doesn't change: the report shows the files aren't in its diff, or the same step
   fails on a control build without the PR. File the failure as its own issue and link
   it from the PR (owner's standing rule, 2026-09-28).
4. Keep streams moving. Relay owner answers to the stream as a message, and quote
   them on its tracking issue. Wake idle cloud streams whose gate has opened. Tell
   the Test Desk your session's name, and ask it to message "PASS #<pr> <sha>"
   after each PASS.
5. Guardrails: without an explicit owner yes in this session, never touch the
   owner's phone, Library, main, the VPS, or simulators. Use one temporary worktree
   per job and remove it afterwards.

Repeat the digest mid-afternoon, or whenever the owner asks what's waiting on them.
```

## Model and effort

- **Default:** Opus 5.5 at high effort for every stream.
- **Go higher (xhigh or max)** for A2 `seams` (both milestones), the first milestone of F1 `coop`, and B4 `bridge` M1 and E3 `maps` M2, which set the server and privacy shape. Mistakes there are expensive for everyone downstream.
- **Research streams** (A3, D1, G2, and the research milestones of B3, C1, C2 and E1) can use the `deep-research` skill for literature and market scans.
- **Codex (OpenAI plan)** works from the same briefs, since it reads `AGENTS.md` too. Good uses: a second implementation attempt on a research question (for example the C1 scorer or B3 matcher), or an independent review of a gate stream's PR. Don't put two agents on the same milestone at once.

## Where each kind of stream runs

**Cloud streams** (A3, D1, G2, and the research and server milestones of B3, B4, C1, C2, E1 and E3):

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

- **Fresh session per milestone.** Start each milestone in a new session with the kickoff prompt. The tracking issue and git history carry state between sessions. A long session full of corrections performs worse than a fresh one with a sharper prompt.
- **Never read `Gate1AppModel.swift` whole.** Use a search or an Explore sub-agent to find the handful of functions you need.
- **Two failed corrections means start over**: clear the session and write a better prompt with what you learned.

## When a stream is done

A stream is done when every milestone's "Done when" holds. The owner then marks the tracking issue `human_validated` or reopens a milestone with what's wrong. Agents never set `human_validated` (`AGENTS.md`).
