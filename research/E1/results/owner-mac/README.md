# Owner set, scored on a Mac with Apple's NaturalLanguage tagger

Produced 2026-09-28 on macOS 26.6.2, arm64, with spaCy 3.8.16 / en_core_web_md 3.8.0:

```sh
python scripts/export_nl_inputs.py --owner <export> > <private>/nl-in.json
swift swift/NLTagDump.swift <private>/nl-in.json > <private>/nl-tags.json
python scripts/run_eval.py --nl-tags <private>/nl-tags.json --owner <export> --out <private>/results
```

- **Set:** 100 of the owner's Margins, labeled in `../../data/labels_owner.psv` before any
  baseline was run on them. A seeded random sample (seed 20260928) of the owner's export
  (Margin notes plus session exports, 497 Margins after de-duplication), at most 3 per source,
  drawn only from the 434 Margins that came with source context. 63 sources. One labeler (the E1
  agent), so there is no agreement figure.
- **Shape:** 496 spoken and 1 written in the whole export; median 103 words per sampled Margin,
  against one line in the public and held-out sets. Many sources are articles and AI-assistant
  replies read aloud, not only podcasts.
- **Portable** uses Apple's recorded `NLTagger` output; **spaCy** is the upper bound, as in
  `../mac-nltagger/`.
- Only scores are here. `run_eval.py` writes no predictions for the owner set, because they quote
  the owner's words. The tag file and the export stay outside git.
- `summary.md` also carries the public and held-out sections; they are byte-identical to
  `../mac-nltagger/`, so those JSON files aren't repeated.
- Rules were not changed after seeing these results, so this is a clean test. Known cheap fixes
  (to be tried on dev data, then re-scored here) are listed on #200.
