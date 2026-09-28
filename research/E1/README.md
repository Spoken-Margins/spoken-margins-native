# E1 structure: evaluation set and baselines (M1)

The taxonomy, results and conclusions are on the tracking issue (#200). This folder holds the
data and code needed to reproduce them.

## Data

- `data/contexts.jsonl`: 47 source-context windows, each 7 sentences before the anchor, the
  anchor sentence (index 7) and 3 after. They come from 12 NASA *Houston We Have a Podcast*
  transcripts (US government works, public domain) and 4 Wikipedia articles (CC BY-SA 4.0).
  Each row carries its URL and license. `scripts/fetch_sources.py` and
  `scripts/build_contexts.py` rebuild the file.
- `data/margins_public.psv`: 175 Margins, written and labeled by the E1 agent. The sources are
  split into `dev` (ai, a2, a3, wf, ch), whose errors were the only ones looked at while
  tuning rules, and `test`, which is everything else.
- `data/margins_heldout.psv`: 75 Margins, written and labeled by an independent sub-agent that
  never saw the rules or the public Margins. They're deliberately messier: fillers, questions
  without question marks, quotes without quotation marks. Rules were frozen before this set
  was scored. **Treat these numbers as the realistic ones.**
- `data/labels_owner.psv`: labels for the owner's own export, keyed by Margin ID, stored as
  character offsets. No Margin or source text is committed.

Line format for the `.psv` sets:
`id | ctx | capture (s/w) | kind | referent (sN/item/none) | text | entities (text:type;…) | topics | follows_up`

## Baselines

- **Portable** (`e1eval/portable.py`) uses only what the phone can reproduce without a model:
  NaturalLanguage-shaped tags (`e1eval/tagger.py`: lexical class, lemma, and person/place/org
  names; no proper-noun class, no parse, no vectors), plus word lists and regexes
  (`e1eval/wordlists.py`). In the cloud the tags come from spaCy squeezed into that shape. On a
  Mac, `swift/NLTagDump.swift` records the real NLTagger output and `--nl-tags` re-scores with it.
- **spaCy upper bound** (`e1eval/spacy_full.py`) is a superset of portable. It adds the
  dependency parse, the full NER label set, noun chunks and `en_core_web_md` vectors.
- **Trained textcat** (`e1eval/textcat.py`) is a bag-of-n-grams statement-kind classifier. It
  gives the "small bundled model" data point: cross-validated by source on the public set, and
  trained on public then tested on held-out.

## Run

```bash
python3 -m venv .venv-e1 && . .venv-e1/bin/activate
pip install spacy click
pip install https://huggingface.co/spacy/en_core_web_md/resolve/main/en_core_web_md-any-py3-none-any.whl
python scripts/run_eval.py                      # writes results/*.json and results/summary.md
python scripts/run_eval.py --owner <unzipped export folder>   # adds the owner set
```

On a Mac, to re-score portable with Apple's tagger:

```bash
python scripts/export_nl_inputs.py > /tmp/in.json
swift swift/NLTagDump.swift /tmp/in.json > /tmp/nl.json
python scripts/run_eval.py --nl-tags /tmp/nl.json
```
