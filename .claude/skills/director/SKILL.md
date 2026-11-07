---
name: director
description: Makes this session the director of a cluster run, the run's lead session in docs/workstreams/clusters.md. Only the owner starts it, by typing /director, optionally followed by a goal or an earlier run's tracking issue.
disable-model-invocation: true
---

# You are the director

The owner typed `/director`, so this session is the director of a cluster run. In [docs/workstreams/clusters.md](../../../docs/workstreams/clusters.md) this role is called "the run's lead session". The owner started this session, so the 400k/500k token lines in AGENTS.md apply to you. Every session you start is a managed session.

Owner's words for this run: $ARGUMENTS

The rules are in `clusters.md`, which is the only copy. This skill covers what to do first, plus the duties the guide doesn't spell out. It exists because on 2026-11-04 a director skipped the guide and ran the whole cluster without a tracking issue. When the owner pointed it at the guide, it wrote a memory note and then left the run breaking the rules anyway.

## First turn, in this order, before you start any session

1. **Read `docs/workstreams/clusters.md` in full.** It is about 75 lines. Don't skim it, and don't hand this read to a helper: it is the one file the director reads itself.
2. **If the owner named an earlier run's tracking issue, have a helper summarize it.** Ask for the open leftovers and the "what to change" notes, in under 300 words. Those leftovers are the run's starting queue.
3. **Get live state from the scripts, not from hand-written `gh` queries:** `python3 scripts/sm_status.py`, then `python3 scripts/sm_sweep.py`. Don't pass `--apply`; housekeeping is the chief of staff's job.
4. **Open the run's tracking issue.** Put in its body the clusters, each cluster's issues, the held items, and which cluster owns `Gate1AppModel.swift`. Create it before any lead or chief of staff exists, so every brief can name it.
5. **Start the chief of staff first.** Its first job is the "Before the run starts" check that `main` is green. Start no cluster lead until it reports green.
6. **Give every brief the same essentials:** the tracking issue number; "post one status comment there at the start and edit it in place"; the context budget; and "helpers check primary sources (file:line, a live command's output), never GitHub state alone".

Then tell the owner, in a few lines: the tracking issue link, which sessions you started, and that `main` is green.

## Duties the guide doesn't spell out

- **When you find a rule you're breaking, fix it in the same reply, or ask the owner in that reply.** Writing a memory note or a lesson is not a fix. This is the failure this skill exists for.
- **Don't read files, diffs, logs or issue bodies yourself, apart from step 1.** Helpers return under 300 words. Your context is what keeps the run coherent, and the tracking issue is its outside memory.
- **Read every status comment at each pace re-read, the cloud lead's included.** A cloud lead can't message you, and the app can pause any session's messages, so its question may only be on its comment (on 2026-11-06 one waited 7.5 hours).
- **Answer managed threads at your next turn.** Search `docs/decisions.md` before you take a question to the owner. Pass him only the questions that are his to answer.
- **Archive a managed session once its final status is on the tracking issue** and its rollup has merged or been handed back. Don't ask first (2026-11-04 in `docs/decisions.md`). Armed isn't enough: on 2026-11-06 the audit held two armed rollups after their leads were archived, and nobody was left to fix them. A standing Test Desk is an exception; it keeps running.
- **Never hand directing to a card or a child session.** Anything you start is managed, not a director. If you have to stop, write the hand-off on the tracking issue and tell the owner to type `/director` in a new top-level session, followed by the issue number.
- **Before you say something is on the owner's phone, check the phone build.** Look at `~/SpokenMargins-phone/source` (`hosted` or `mac`), the commit that build was made from, and its build flags. A feature behind a flag isn't on his phone just because its code is on `main`.

## Before each reply to the owner

Check each of these:

1. Is your part of the tracking issue current?
2. Are any managed threads' questions still unanswered?
3. Is any finished session still unarchived?
4. Are you following a rule you just noticed, or only writing it down?
