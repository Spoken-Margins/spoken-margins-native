# Scene-break bench results, 2026-10-18 (#2075)

Data: `results.json`. 18 episodes from 10 podcasts, 11 German and 7 English, 29 to 247 minutes. Model: `claude-haiku-5-5` through the Claude Code CLI.

`results.json` is a merge of three runs, all made after the first two bench fixes listed at the end:

- A and B, and C for 11 episodes, come from the second full run.
- C for 7 episodes comes from two fill-in runs, made after the third fix (`run.merged` lists them).
- C for `freakL-52f2c4` is incomplete. Its break picks are valid. Its scene and map checks are not, because the budget cap stopped stage 2.

Tables come from `summarize.py`. The extra breakdowns were computed from the same file and from the local cache. Only numbers, slugs and single flagged words are reported.

## The short answer

1. **Haiku picking from code's candidates (C) finds the best breaks.** Mean F1 at 30 seconds is 0.40 at medium effort and 0.37 at low. Code alone (B, topic shift) scores 0.33, and an even split 0.12. All four use one scene per 5 minutes.
2. **The gain over code alone is small, and mostly English.** At medium effort, C adds 0.13 in English and 0.03 in German. With 18 episodes, neither is distinguishable from noise.
3. **Today's server path (A) made a map for only 3 of 18 episodes, and none in German.** Two were refused before any call for being too long. The other 13 failed the name check or the title length. One of those had its second attempt blocked by a bench bug.
4. **The name check is the main blocker, and it is a German problem.** C's English summaries pass 97 to 98 percent of the time. German summaries pass 5 percent (8 of 159). About three quarters of the flagged German words are role nouns like "Sprecher" or "Gast", which German capitalises.
5. **C costs about twice what A costs per episode.** C is $0.025 to $0.027 per episode; A is $0.012 (or $0.013 per episode it attempted). That is under 2 cents per audio hour for C.
6. **Medium effort beat low in this run**, mostly in English (0.45 against 0.36), for 7 percent more cost.
7. **Recommendation:** use C at medium effort for breaks, one call per scene for text, and make the name check language-aware before German maps ship. Details and what would change this are at the end.

## Headline numbers

Mean F1 per episode, one scene per 5 minutes. A's failed maps count as 0.

| approach | all @30s | en @30s | de @30s | all @60s |
|---|---|---|---|---|
| even split | 0.12 | 0.11 | 0.13 | 0.26 |
| B, topic shift | 0.33 | 0.32 | 0.34 | 0.47 |
| A, server today | 0.09 | 0.22 | 0.00 | 0.10 |
| C, medium effort | 0.40 | 0.45 | 0.38 | 0.58 |
| C, low effort | 0.37 | 0.36 | 0.38 | 0.55 |

`freakL-52f2c4` counts in these F1 numbers, because its breaks are valid.

## Code only (B) and the even split

"Scenes vs chapters" is scenes made divided by publisher chapters.

| method | min/scene | all @30s | all @60s | en @30s | de @30s | scenes vs chapters |
|---|---|---|---|---|---|---|
| uniform | 3 | 0.26 | 0.41 | 0.27 | 0.25 | 1.78 |
| uniform | 5 | 0.12 | 0.26 | 0.11 | 0.13 | 1.24 |
| uniform | 6 | 0.19 | 0.30 | 0.18 | 0.19 | 1.07 |
| pause | 5 | 0.20 | 0.35 | 0.21 | 0.19 | 1.24 |
| both | 3 | 0.30 | 0.50 | 0.30 | 0.30 | 1.78 |
| both | 5 | 0.26 | 0.44 | 0.21 | 0.29 | 1.24 |
| topic | 3 | 0.34 | 0.52 | 0.36 | 0.34 | 1.78 |
| topic | 5 | 0.33 | 0.47 | 0.32 | 0.34 | 1.24 |
| topic | 8 | 0.26 | 0.38 | 0.25 | 0.27 | 0.80 |

- Topic shift is the best signal. Pause alone barely beats the even split, and adding pause to topic makes it worse.
- The even split is noisy: 0.12 at 5 minutes but 0.19 at 6. Compare B with the floor only at the same minutes per scene.
- B costs nothing and runs in milliseconds.
- B's scene length was chosen on these same episodes, so its best row is slightly optimistic.

## A: the server's worker today

One call per attempt, up to two attempts, at medium effort.

| | all | en | de |
|---|---|---|---|
| episodes | 18 | 7 | 11 |
| refused before any call (too long) | 2 | 0 | 2 |
| maps made | 3 | 3 | 0 |
| made on the first try | 1 | 1 | 0 |
| mean F1@30, failures as 0 | 0.09 | 0.22 | 0.00 |
| calls per attempted episode | 1.9 | 1.7 | 2.0 |
| cost per episode, all | $0.0115 | $0.0107 | $0.0121 |
| cost per attempted episode | $0.013 | $0.011 | $0.015 |
| cost per audio hour, attempted | $0.010 | $0.007 | $0.014 |
| mean wall time, attempted | 354 s | 301 s | 396 s |

Why the 15 failures happened:

1. **Too long (2 German):** `creL-9f35f0` (217 min) and `freakL-52f2c4` (247 min) are over the server's 180,000-byte prompt limit. The 177 and 192 minute English episodes fit.
2. **Name check (9 German):** every attempted German episode failed "names someone the scene doesn't mention" at least once. Five failed it on both attempts. Four failed title length on one attempt and the name check on the other.
3. **Title length (3 English):** `lupM-338e53` failed title length twice. `pc20-70060e` and `noagenda-bfd147` failed title length once and the name check once.
4. **Bench bug (1 English):** `noagenda-167977` failed title length on attempt 1. Its attempt 2 was blocked by the budget guard bug (fixed since, see the end). A wasn't re-run, so this episode had only one real attempt. English A could be 4 of 7, not 3.

A's three maps score 0.52 at 30 seconds, but they make about 2.1 scenes per chapter (15 to 28 scenes for 8 to 14 chapters). More scenes buy recall at the cost of precision, so this isn't comparable with B or C. On the same three episodes, B topic scores 0.40, C medium 0.45 and C low 0.32.

## C: Haiku picks breaks, then writes each scene

Stage 1: one pick call with 3×K of B's topic candidates. Stage 2: one call per scene, with one retry naming the broken rule.

Pass counts and costs here leave out `freakL-52f2c4`.

| | medium, en | medium, de | low, en | low, de |
|---|---|---|---|---|
| mean F1@30 | 0.45 | 0.38 | 0.36 | 0.38 |
| scenes passing after retry | 130/132 | 8/159 | 128/132 | 8/159 |
| scenes passing first try | 128/132 | 4/159 | 116/132 | 3/159 |
| whole map passed | 6 of 7 | 0 of 10 | 5 of 7 | 0 of 10 |
| whole map repaired | 1 | 0 | 1 | 0 |
| cost per episode | $0.019 | $0.032 | $0.018 | $0.030 |
| cost per audio hour | $0.012 | $0.024 | $0.011 | $0.022 |
| calls per episode | 20 | 32 | 22 | 33 |

Across both languages: medium costs $0.027 per episode and $0.018 per audio hour; low costs $0.025 and $0.017.

Notes:

- The pick call is 16 to 26 percent of C's cost. German costs more because nearly every scene is retried.
- Every failing scene failed on the name check. No scene failed title length, which was A's main English failure.
- The whole-map check reads a scene plus its neighbours, and can swap a failing summary for its title. So one English low-effort map (`noagenda-bfd147`) was refused whole although 34 of 35 scenes passed alone.
- The pick never invented an id (the `enum` held). All 36 picks returned exactly K−1 breaks. The bench doesn't enforce that, though (see the end).
- Mean wall time was 505 s at medium and 593 s at low. *Inference:* this mostly measures waiting for the bench's 6 shared call slots, not how long a server would take. The summed model time per episode was 160 s at medium and 148 s at low.

## Does Haiku beat code alone?

C and B topic at 5 minutes use the same K on every episode, so this tests the pick step alone.

| | mean F1@30 gain over B | wins / losses / ties | sign test p |
|---|---|---|---|
| C medium, all | +0.07 | 9 / 6 / 3 | 0.61 |
| C medium, en | +0.13 | 5 / 1 / 1 | 0.22 |
| C medium, de | +0.03 | 4 / 5 / 2 | 1.00 |
| C low, all | +0.04 | 8 / 4 / 6 | 0.39 |
| C low, en | +0.04 | 3 / 1 / 3 | 0.62 |
| C low, de | +0.04 | 5 / 3 / 3 | 0.73 |

- The per-episode spread (standard deviation 0.13 to 0.17) is two to four times the mean gain. 18 episodes can't show the gain is real.
- C is ahead at the 60 second window too: 0.58 at medium against 0.47 for B.
- B topic at 3 minutes (0.34, with 1.4 times the scenes) closes part of the gap.
- Leaving out `lnpS-3e28ae` (partial transcript, below) moves German C medium's gain to about zero (−0.004, 3 / 5 / 2).

## Do stage-2 summaries pass the name check?

**In English, yes.** 128 to 130 of 132 scenes pass after one retry. The flagged English words were "American", "Democratic", "Europe", "MP" and "AI".

**In German, no.** 8 of 159 pass at either effort. By a common-word count, 152 to 154 of 159 summaries are in German, so the model isn't answering in the wrong language.

I sorted the flagged word in each failing German summary (`mapbench -explain`, 151 failing scenes at each effort):

| kind of flagged word | medium | low |
|---|---|---|
| role or format noun ("Sprecher", "Gast", "Gesprächspartner", "Runde", "Moderator", "Host") | 116 | 115 |
| other common noun, often a compound | 35 | 33 |
| English word in a German summary, besides "Host" | 0 | 3 |
| real proper name not in the scene | 0 | 0 |

Why this happens:

- German capitalises every noun. The check treats any mid-sentence capitalised word as a name, and requires it to appear in the scene. In English "the host" is lowercase and never checked; in German "der Gast" is.
- The model calls speakers by role, and those role words rarely appear in what is said.
- A failing German summary has a median of 3 flagged words (mean 3.2 to 3.4). So allowing one word list doesn't clear it.
- The title has a flagged word too in 104 to 105 of the 151. Then the whole-map repair, which puts the title in place of the summary, can't help.

I re-ran the rule in Python on the cached output to see what a change would do. My copy agrees with the bench's verdict on all 291 checked scenes at each effort. German scenes passing, of 159:

| rule | medium | low |
|---|---|---|
| today's rule | 8 | 8 |
| allow about 30 role and format nouns | 15 | 17 |
| also accept words from the other German transcripts | 26 | 28 |
| both of those | 31 | 34 |
| check only all-capital acronyms | 159 | 158 |

Word lists help little, because the summaries paraphrase with many different nouns. Only a rule that stops treating German capitalised words as names gets German to the English pass rate. The cost is that an invented German name would pass. In this data, none of the flagged German words was a real name.

The earlier draft reported 194 of 199 for the acronym rule. That count included `freakL-52f2c4`, whose cached output is stale (see the end). Without it, the result is 158 to 159 of 159.

## Spend

These runs used the owner's plan through the CLI, not API dollars. All figures are at the server's prices ($0.10 in and $0.50 out per million tokens).

| run | spend |
|---|---|
| first full run (discarded for its bugs) | $1.2414 |
| smoke tests | about $0.06 |
| second full run | $0.9291 |
| fill-in 1 | $0.4264 |
| fill-in 2 | $0.2938 |
| total | about $2.95 |

The bench's counters agree: `spentMicroUSDAllRuns` is 1,649,279 for the last three, and `spentMicroUSDEarlierDiscardedRuns` is 1,301,400 for the first two lines.

**The data kept in `results.json` cost $1.2067:** A $0.208, C medium $0.506, C low $0.492. That is $0.44 less than the $1.65 the last three runs spent. The difference is work that was paid for and then replaced:

1. $0.686 of the kept calls come from the second run. So about $0.243 of it went to C for the 7 episodes that were filled in later.
2. $0.520 of the kept calls come from the fill-ins, which spent $0.720. So about $0.200 went to fill-in work that the other fill-in replaced.

The split between those two is inferred from the totals. The file doesn't itemise the replaced calls.

## What couldn't be verified

1. **`lnpS-3e28ae`'s transcript is partial.** It has 33 words a minute where the others have 118 to 198. Its cues span the whole 36 minutes but cover only about 8 of them, with gaps of 2 to 3 minutes. Four of its 5 chapters fall in the first 3.4 minutes. **Exclude it** from the next run's break scores. Without it, B topic is 0.35, C medium 0.41 and C low 0.38; German C medium then gains nothing over B.
2. **C's pick count isn't enforced.** The prompt asks for K−1 breaks, and the code takes whatever comes back. In this data the count differed 0 times in 36 picks. The first, buggy run had one pick that returned K.
3. **German-heavy set.** 11 of 18 episodes are German, and 3 come from one show. English rests on 7 episodes from 4 shows.
4. **B was tuned on the test set.** The scene length and scorer were chosen on these episodes, and C uses B's candidates, so C inherits some of that.
5. **CLI, not the direct API.** Each call carries about 800 tokens of CLI wrapping that a direct API call wouldn't. C's scene calls average about 3,600 input tokens, so about a fifth of their input is wrapping. *Inference:* C's cost is overstated by about 8 percent, and A's (32,000 input tokens a call) by under 1 percent. Answers through `--json-schema` may also differ from the server's own call.
6. **Chapters are a subjective answer key.** Publishers mark chapters for their own reasons, such as ads, segments or guests. A listener's "scene" may differ. The 60 second window is kinder to near misses.
7. **No listener judged the titles or summaries.** The checks measure rule compliance, not whether the text is good.
8. **The German rule change is simulated in Python**, not run through the Go check.

## Bench faults

Fixed before the data in `results.json`:

1. `joinCues` now clamps a cue end that comes before the segment start. This let A run on `forM-69e844` and `forscherA-f48ef1`.
2. C's wall time is now recorded.
3. A call queued for a CLI slot no longer reserves budget while it waits (`cli.go`: take the slot, then reserve). Before this, the guard blocked calls without spending. The 7 C fill-ins ran after this fix; the second full run did not.

Still open:

1. **A for `noagenda-167977` ran under fault 3.** Its second attempt was blocked. Re-running A on it (about $0.01) would settle whether English A makes 3 or 4 maps.
2. **C's stage 2 loses work on an error.** When a scene call errors, `runC` returns before counting the finished scenes, and doesn't write the generated file. So `freakL-52f2c4` shows no pass counts, and its cached output is still from the first run. `-explain` on it reads that stale output.
3. **The pick count isn't checked** (above).
4. `summarize.py` now marks a C result whose whole-map check never ran as "stage 2 incomplete". It leaves that episode out of pass counts and cost, but keeps it in F1.

## Recommendation

1. **Breaks: use C at medium effort**, falling back to B topic when the pick fails. C is ahead of B on average, and Haiku can't invent a break. Medium is the server's default, and it beat low in English for 7 percent more cost. *Inference:* the medium-versus-low gap may be noise, and so may the gain over B.
2. **Titles and summaries: one call per scene.** No C scene failed title length, A's main English failure. *Inference:* this alone would clear most of A's English failures.
3. **Name check: make it language-aware before German maps ship.** For German, stop treating a capitalised word as a name just because it is capitalised. Two ways, in order of preference:
   - Ask the model for its names. Add a `names` list to the stage-2 schema, and check each listed name appears in the scene. This works the same in every language. *Inference:* not tested here.
   - Or, for German only, check only acronyms and words the model marks as names. The simulation puts German at 158 to 159 of 159.
   - A role-noun allow list isn't enough (15 to 17 of 159).
   - *Inference:* the phone's `ListeningMapSummaryValidator` uses the same rule, so maps made on the phone in German probably fail the same way.
4. **Raise or chunk the size limit** only if three-hour German episodes matter. Two of 18 were over 180,000 bytes.

What would change this:

- If a re-run on a larger English set shows C no better than B topic at the same K, drop the pick call. Use B with stage 2 only.
- If C's German breaks stay level with B's (as they are without `lnpS-3e28ae`), use B for German.
- If low effort matches medium on a larger set, use low.
- If listeners prefer A's denser maps, the chapter key is the wrong target, and F1 against chapters shouldn't decide this.
- If a `names` list lets invented names through in a spot check, keep a German capitalisation check with a proper German word list instead.
