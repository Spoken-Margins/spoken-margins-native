# Mac run with Apple's NaturalLanguage tagger

Produced 2026-09-28 on macOS 26.6.2, arm64, with the commands in `../../README.md` (Run → "On a Mac"):

```sh
python scripts/export_nl_inputs.py > in.json
swift swift/NLTagDump.swift in.json > nl-tags.json
python scripts/run_eval.py --nl-tags nl-tags.json
```

- **Portable** columns use Apple's real `NLTagger` output (`nl-tags.json`), not the spaCy stand-in the cloud used.
- **spaCy** columns come from spaCy / en_core_web_md 3.8.16 3.8.0 as installed on this Mac. They differ from the cloud's spaCy columns in `../summary.md`, so compare portable here against spaCy here, and don't read spaCy differences between the two runs as a tagger effect.
- The cloud's results in `../` are left unchanged.
- Setup note: pip rejects the Hugging Face `en_core_web_md-any-py3-none-any.whl` filename in the README ("invalid version"). On the Mac, `python -m spacy download en_core_web_md` worked instead.
