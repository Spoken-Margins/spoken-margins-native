"""How much silence sits between two rendered Supertonic chunks (#586).

Renders each chunk of a plan with the real model (the same Python port of the app's runtime that
`engines/supertonic.py` holds) and measures, per chunk, the silence the model leaves before and
after the speech, plus the pauses it puts between sentences inside one chunk. The gap a listener
hears at a boundary between chunks N and N+1 is

    trailing silence of N + the planned transition delay + leading silence of N+1

(plus, on the phone, the time the player takes to start the next item; the app reports that as
`longestChunkHandOverGap` in diagnostics).

Input is a chunk plan as JSON, in the order the app plays it:

    [{"text": "First chunk.", "boundary": "sentence"}, {"text": "Second chunk", "boundary": "comma"}, ...]

`boundary` is `RenderedSpeechChunkBoundary` (sentence, comma, whitespace, hard). Dump the plan with
the real planner: `RenderedSpeechChunker.sourceSlices(from:)` over the item's spoken text.

    research/C2/fetch_models.sh        # once; downloads the model into research/C2/models
    python3 research/C2/chunk_gap.py plan.json --speed 0.88 --out artifacts/chunk-gap.json

The silence rule mirrors `SpeechSilenceTrim` in SessionKit (10 ms RMS windows, floor 0.01, about
-40 dBFS), so the "after trimming" columns say what the app now plays.
"""
import argparse
import json
import re
import statistics
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from engines.supertonic import Engine  # noqa: E402

WINDOW_SECONDS = 0.010
SILENCE_FLOOR = 0.01
LEADING_PAD_SECONDS = 0.05
TRAILING_PAD_SECONDS = 0.12
# A quiet stretch this long inside speech counts as a pause between sentences or clauses.
PAUSE_SECONDS = 0.15
# `RenderedSpeechChunkBoundary.transitionDelay`.
TRANSITION_DELAY = {"sentence": 0.12, "comma": 0.05, "whitespace": 0.0, "hard": 0.0}


def voiced_windows(samples, sample_rate):
    size = max(1, int(sample_rate * WINDOW_SECONDS))
    count = len(samples) // size
    if count == 0:
        return np.zeros(0, dtype=bool), size
    rms = np.sqrt((samples[: count * size].reshape(count, size) ** 2).mean(axis=1))
    return rms > SILENCE_FLOOR, size


def measure_chunk(samples, sample_rate):
    voiced, size = voiced_windows(samples, sample_rate)
    if not voiced.any():
        return None
    first = int(np.argmax(voiced))
    last = len(voiced) - 1 - int(np.argmax(voiced[::-1]))
    inner = voiced[first : last + 1]
    pauses, run = [], 0
    for is_voiced in inner:
        if is_voiced:
            if run * WINDOW_SECONDS >= PAUSE_SECONDS:
                pauses.append(run * WINDOW_SECONDS)
            run = 0
        else:
            run += 1
    seconds = size / sample_rate
    leading = first * seconds
    trailing = (len(samples) - (last + 1) * size) / sample_rate
    return {
        "seconds": len(samples) / sample_rate,
        "leading": leading,
        "trailing": trailing,
        "pauses": pauses,
    }


def sentence_pairs(plan, count):
    """Adjacent comma-free sentences from the plan, joined into one text: the only pause the model
    puts inside such a text that is longer than the detector's floor is the one between the sentences."""
    sentences = []
    for item in plan:
        sentences += [t.strip() for t in re.split(r"(?<=[.!?])\s+", item["text"]) if t.strip()]
    usable = [t for t in sentences if "," not in t and 30 <= len(t) <= 110 and t[-1] in ".!?"]
    pairs = []
    for first, second in zip(sentences, sentences[1:]):
        if first in usable and second in usable and len(pairs) < count:
            pairs.append(f"{first} {second}")
    return pairs


def describe(values):
    if not values:
        return None
    ordered = sorted(values)
    return {
        "count": len(values),
        "min": ordered[0],
        "median": statistics.median(ordered),
        "mean": statistics.fmean(ordered),
        "p90": ordered[min(len(ordered) - 1, int(0.9 * len(ordered)))],
        "max": ordered[-1],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("plan", type=Path)
    parser.add_argument("--voice", default="M2")
    parser.add_argument("--speed", type=float, default=0.88)
    parser.add_argument("--steps", type=int, default=8)
    parser.add_argument("--limit", type=int, default=0, help="render only the first N chunks")
    parser.add_argument(
        "--sentence-pairs", type=int, default=0,
        help="also render N comma-free sentence pairs and measure the pause between the sentences",
    )
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    plan = json.loads(args.plan.read_text())
    pairs = sentence_pairs(plan, args.sentence_pairs)
    if args.limit:
        plan = plan[: args.limit]
    engine = Engine(voice=args.voice, steps=args.steps, speed=args.speed)
    engine.load()

    chunks = []
    for index, item in enumerate(plan):
        measured = measure_chunk(engine.synth(item["text"]), engine.sample_rate)
        if measured is None:
            print(f"chunk {index}: silent", file=sys.stderr)
            continue
        measured.update(index=index, boundary=item["boundary"], characters=len(item["text"]))
        chunks.append(measured)
        print(
            f"chunk {index:3d} {item['boundary']:<10} {measured['seconds']:6.2f}s  "
            f"lead {measured['leading']:.2f}  trail {measured['trailing']:.2f}  "
            f"in-chunk pauses {[round(p, 2) for p in measured['pauses']]}",
            file=sys.stderr,
        )

    sentence_pauses = []
    for text in pairs:
        measured = measure_chunk(engine.synth(text), engine.sample_rate)
        if measured and measured["pauses"]:
            sentence_pauses.append(max(measured["pauses"]))
            print(f"pair pause {sentence_pauses[-1]:.2f}s: {text[:60]}", file=sys.stderr)

    gaps_now, gaps_trimmed = [], []
    for before, after in zip(chunks, chunks[1:]):
        delay = TRANSITION_DELAY[before["boundary"]]
        gaps_now.append(before["trailing"] + delay + after["leading"])
        gaps_trimmed.append(
            min(before["trailing"], TRAILING_PAD_SECONDS)
            + delay
            + min(after["leading"], LEADING_PAD_SECONDS)
        )

    pauses = [pause for chunk in chunks for pause in chunk["pauses"]]
    report = {
        "voice": args.voice,
        "speed": args.speed,
        "steps": args.steps,
        "chunks": len(chunks),
        "boundaries": {kind: sum(1 for c in chunks[:-1] if c["boundary"] == kind) for kind in TRANSITION_DELAY},
        "leading_silence": describe([c["leading"] for c in chunks]),
        "trailing_silence": describe([c["trailing"] for c in chunks]),
        "in_chunk_pause": describe(pauses),
        "between_sentences_pause": describe(sentence_pauses),
        "gap_before_trimming": describe(gaps_now),
        "gap_after_trimming": describe(gaps_trimmed),
        "per_chunk": [
            {k: round(c[k], 3) for k in ("seconds", "leading", "trailing")} | {"index": c["index"], "boundary": c["boundary"]}
            for c in chunks
        ],
    }
    text = json.dumps(report, indent=2)
    print(text)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")


if __name__ == "__main__":
    main()
