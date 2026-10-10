# D3 offline ranking evaluation

This is the M2 rehearsal requested in #176: it compares a transparent,
source-level affinity score with the existing newest-first inbox. It is stdlib
Python 3.9+ and makes no network requests. The input contract is the published
I4 ([`Contracts/schemas/i4-engagement.schema.json`](../../Contracts/schemas/i4-engagement.schema.json));
[`i4-draft.md`](i4-draft.md) lists how it differs from the draft the rehearsal was built on.

## Run the synthetic rehearsal

From the repository root:

```sh
python3 research/D3/synth.py artifacts/d3-synthetic.jsonl
python3 research/D3/evaluate.py artifacts/d3-synthetic.jsonl
python3 -m unittest discover -s research/D3/tests -v
```

The generator's default seed is fixed, covers 60 synthetic sources over seven
weeks, and includes loved, ignored, and dismissed sources, clustered/binge
listening, and engagement several days after publication. Change the seed with
`--seed`, but record it when comparing experiments.

## Run it on the owner's export later

1. Export the I4 JSON Lines file from the owner's device (Settings › Support &
   Privacy › Export Listening Signals) once at least two weeks have accumulated. Keep the file on the
   device or the owner's Mac. Do not upload it or add it to Git; `artifacts/` is
   the intended local location.
2. The loader accepts `i4-engagement.1` as exported. If a later I4 version
   differs, adapt the loader. Do not silently rewrite the evidence.
3. Copy `policy.json` to a local file if testing weights, then run:

   ```sh
   python3 research/D3/evaluate.py /local/path/engagement.jsonl \
     --policy /local/path/candidate-policy.json
   ```

The replay takes a snapshot at the start of each UTC day. Only events strictly
before that instant contribute ranking signals. Eligible items were published
before it and have not yet been listened to, Margined, dismissed, or finished.
An item is a positive if the listener subsequently finishes it or makes a
Margin on it. This makes the temporal boundary explicit and prevents future
behavior from leaking into the score.

## Reading the report

* **NDCG@10** rewards placing later-positive items near the very top; 1 is an
  ideal first ten and 0 means none appears there.
* **Precision@5** is the fraction of the first five that later become positive.
  Its maximum can be below 1 on days with fewer than five positives.
* **Mean positive rank** is the average position of all positives in that day's
  inbox; unlike the other two, lower is better.
* **Delta** is score minus newest-first. Thus positive is good for NDCG and
  precision, while negative is good for mean rank. The 95% bootstrap interval
  resamples eligible days and describes uncertainty in that paired delta; it is
  not a guarantee about future behavior.

The score is deliberately inspectable: recency decays by a policy half-life,
and weighted source history covers listened share, finish rate, Margin count,
share count, and dismissal rate. Every result has one reason corresponding to
the largest absolute source-signal contribution. With no source signals,
recency preserves newest-first ordering.

## Limits

Synthetic success only proves that the evaluator can recover the preference
planted by its generator. It does not show that these weights help the owner,
that a finish/Margin captures every valuable item, or that daily repeated
snapshots are independent observations. Sparse sources, changing interests,
unknown durations, multiple actions on one item, and the chosen observation
window can all bias results. Use the real local export to decide whether the
simple score beats chronology; treat the bootstrap interval as a diagnostic,
not as product validation. Time-of-day modeling remains intentionally out of
scope for M2.
