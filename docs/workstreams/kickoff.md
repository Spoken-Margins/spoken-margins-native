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
   If the brief lists an owner decision this milestone needs, stop and ask on the
   stream's tracking issue instead of guessing.
2. /goal <the milestone's "Done when" text, copied from the brief, leaving out items
   marked (owner)>, or stop and report on the tracking issue after 40 turns without
   progress.
3. When it is met: comment on the tracking issue with what changed, the evidence
   (test output, lane report link), exact steps for any (owner) items, and what is next.

Use sub-agents for read-only exploration (never read Gate1AppModel.swift whole).
Before asking for a T4 lane run, have a fresh sub-agent review the diff against the
brief and fix only real gaps.
```

Why it's shaped this way:

- **`/goal` holds the agent to the endpoint.** After each turn, a separate evaluator checks the condition against what the agent has shown in the transcript, and the agent keeps working until it's met ([docs](https://code.claude.com/docs/en/goal)). That's why every "Done when" in the briefs is written as something the agent can *demonstrate* (a test output, a measured number, a tap count, a lane report), not something it can merely assert.
- **Items marked (owner) stay out of the goal.** Listening by ear, measurements on the owner's phone, and data only the owner has can't be demonstrated by an agent. The agent prepares them (a build, exact steps, what to look for) and the milestone waits on the owner.
- **Stating the approach first** gives the owner a moment to redirect from the phone before hours go into the wrong idea. It isn't a request for approval; the agent continues unless redirected.
- **A turn cap** stops a stuck stream from burning a day. Blocked is a legitimate outcome if it's reported.
- **A fresh-context review** before a milestone catches the "looks done" failure without an auditor agent chain ([best practices](https://code.claude.com/docs/en/best-practices#add-an-adversarial-review-step)). Tell the reviewer to flag only gaps against the brief's "Done when" and "Must not break", or it will invent work.

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
