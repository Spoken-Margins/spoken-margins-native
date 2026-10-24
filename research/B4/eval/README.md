# Scene-break bench for community maps (#2075)

This bench measures how well community listening maps find scene breaks, using publisher chapters as the answer key. It only measures: the live server path is unchanged, and nothing here deploys or calls the VPS.

## What it compares

- **A, today's single call.** The server's own worker (`internal/maps`, after #2072) runs unchanged, with only the model call swapped out. Its prompt, checks, retry and repairs are the server's.
- **B, code only.** Every segment start is scored with a TextTiling-style topic-shift depth (word overlap across two minutes each side), the pause before it, or both. The top K are taken with a minimum gap, where K comes from the episode's length. A uniform split is the floor B must beat.
- **C, code plus Haiku.** Stage 1 sends the transcript and B's top 3×K candidates with scores. Haiku is asked for K−1 of them through structured output, with an `enum` of candidate ids, so it can't invent a break. The count itself isn't enforced. In stage 2, one small call per scene gets only that scene's text and writes the title and summary. Each answer goes through the server's length, name and copy checks; a failing scene gets one retry that names the broken rule. The assembled map then goes through the server's whole-answer check.

## How the model is called

There is no Anthropic API key on the Mac, so calls go to `claude-haiku-5-5` through the Claude Code CLI on the owner's plan. The CLI's system prompt is replaced by the request's own, tools are off, and the answer comes back through `--json-schema`. Each call carries about 800 tokens of CLI wrapping that the server's direct API call wouldn't. Costs are computed from the reported token usage at the server's prices ($0.10 in and $0.50 out per million tokens), so they slightly overstate what the server would pay.

The server sets no effort, and Haiku 5.5 defaults to medium, so A runs at `--effort medium`. C runs at both medium and low.

Structured output can't cap string length (`maxLength` isn't supported), so lengths can only come from the prompt.

## Data

The data is 18 public episodes from 10 podcasts that publish both Podcasting 2.0 chapters and a timed transcript (SRT, VTT or JSON). 11 of them are German, because English shows that publish both are scarce. Lengths run from 29 to 247 minutes.

Transcripts live in `~/Library/Caches/spoken-margins-mapbench/` and are never committed. The results files hold only feed URLs, GUIDs, chapter start times and numbers. Model-written titles and summaries go to the cache's `generated/` folder.

Published cues are a few seconds long. They are joined into segments of 15 to 30 seconds, ending at a sentence end or a speaker change, to resemble a phone's upload and stay under the server's 3,000-segment limit.

## Running it

From `research/B4/server`:

```
go run -tags mapbench ./cmd/mapbench -approaches B
go run -tags mapbench ./cmd/mapbench -approaches A,B,C -c-variant topic -c-minutes 5 -efforts-c medium,low -budget 3
python3 -I ../eval/summarize.py ../eval/results.json
```

Each run writes `results-<approaches>-<time>.json` next to this file. `-only <slugs>` re-runs some episodes. `results.json` is the merged data the report uses: one full run, plus C for 7 episodes from later fill-in runs (its `run.merged` lists them).

`-budget` is in dollars at the server's prices. A call reserves its estimated cost only after it gets a CLI slot, so queued calls don't block each other. When the cap is reached mid-episode, that episode's C stage 2 is incomplete; `summarize.py` marks it and leaves it out of pass counts and cost.

To see which word the name check flagged in each failing scene, without any model call:

```
go run -tags mapbench ./cmd/mapbench -explain C-low
```

It reads the cache and prints to the terminal only.

The `mapbench` build tag keeps the bench and its hooks (`internal/maps/bench_hooks.go`) out of `smserver`.

## Scoring

A predicted break is a hit when it falls within 30 seconds of a chapter start (60 seconds is also reported). Each chapter start counts once. Breaks in the first 15 seconds are ignored on both sides. Precision, recall and F1 are per episode, then averaged.

The scene length for B was chosen on these same episodes, so B's best row is slightly optimistic.
