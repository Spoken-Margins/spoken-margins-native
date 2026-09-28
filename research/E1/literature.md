# E1: dialogue-act and claim/question detection for short spoken notes

A time-boxed literature check (2026-09-28, cloud) for the next Mac session on kind views
(#200, "Decision: which uses of structure matter"). The question is what is likely to beat the
current rules on the owner's Margins without a large model, and what it would cost. Nothing
here was measured on owner data. The expected gains are estimates from the literature, so
the practice set and the frozen 100 still decide.

## What the owner-set results imply

- Margins are **monologues** (median 103 words, 6 sentences), not dialogue turns. Every
  dialogue-act corpus below labels short segments, so a classifier should only ever see
  segments. The Mac session already found the gold kind in some sentence of the Margin 84% of
  the time, which matches how the field works: segment first, then tag.
- The failure was **precision on rare kinds** (to-do 0.07, question 0.33), not coverage. Most
  papers report accuracy over all segments, which flatters the majority class, just as
  always-`claim` scores 0.69 here. So measure **precision at a stated coverage**, and let the
  producer abstain.

## Methods, cheapest first

### 1. Get punctuation from the recognizer, then segment (cost: under one session)
- Question and sentence-boundary rules depend on `?` and `.`. Apple's Speech framework adds
  punctuation on request (`addsPunctuation` on `SFSpeechRecognitionRequest` since iOS 16).
  The iOS 26 `SpeechTranscriber` path in `SessionKitAudio/AudioAdapters.swift` uses
  `transcriptionOptions: []`.
- **Check on the Mac which recognizer produces Margin transcripts, and whether their
  punctuation is on.** If it's off, turning it on is the cheapest fix in this whole list.
- If punctuation can't be had from the recognizer, lightweight punctuation-restoration models
  exist (a fine-tuned ELECTRA-small with a small head, a few words of latency; Polacek et al.
  2023). That's a ~14M-parameter model to bundle, so use it only as a last resort.

### 2. Segment-level rules that abstain (cost: the planned Mac session)
- **Question:** a trailing `?`, or a wh-word or auxiliary opening a *segment*. The same cue
  fires far less wrongly per segment than per 100-word Margin.
- **To-do:** a first-person obligation ("I need to", "gotta", "remind me") or a
  sentence-initial imperative, in a *segment*.
- Abstain on anything else.
- This is the classic lexical-cue approach. In Stolcke et al. (2000) on Switchboard,
  word-based cues alone carried most of the signal for questions; statements and opinions
  were what got confused.
- **Expected:** a large precision gain on to-dos and questions, because a passing phrase in a
  long claim now marks one segment, not the whole Margin. It won't separate claim from
  reaction.

### 3. Apple's contextual embedding plus a tiny trained head (cost: 1–2 sessions)
- **The model.** `NLContextualEmbedding` (iOS 17+) is an OS-provided BERT-style encoder with
  512-dimensional outputs. The OS downloads it on demand (reported under 100 MB, shared by
  every app), and it **does not need Apple Intelligence**, which meets the owner's hardware
  constraint.
- **Create ML's route.** Create ML's text classifier can train on top of these embeddings
  ("BERT embeddings", WWDC23). The shipped classifier is then only the head: kilobytes, not
  megabytes.
- **Same idea as SetFit.** This is what SetFit does with sentence-transformers: embed, then fit
  a logistic-regression head. SetFit reports being competitive with full fine-tuning at
  **8 examples per class** on sentiment tasks (Tunstall et al. 2022). Our kinds are harder
  than sentiment, so budget 20–50 labeled segments per kind.
- **Why it could beat rules:** embeddings generalize over paraphrase ("I kind of want to
  know whether…", "this is me with linear algebra"). That's exactly the long tail the rules
  missed on the held-out and owner sets.
- **Why the earlier textcat result doesn't rule it out:** that textcat was a bag-of-n-grams
  model trained on 175 synthetic one-liners, with no pretrained representation.
- **Cost:**
  1. A Swift tool to dump segment embeddings. It's analogous to `swift/NLTagDump.swift`.
  2. A Python head trained with cross-validation.
  3. About 200–400 labeled segments, from the owner's practice-set review plus the mapped
     public data below.

  The app would carry the head plus an asset request, and inference runs on the Neural
  Engine in the background after capture.
- **Risk:** calibration. Pick each kind's abstention threshold on the practice set, then
  report precision and coverage once on the frozen 100.

### 4. A bundled small sentence encoder (cost: +25–45 MB of app size)
- A MiniLM-class model (~22M parameters) converted to Core ML with the same head would do
  the same job. That's worth it only if Apple's embedding underperforms, for example on
  English informal speech, or if its asset download proves unreliable.
- Keep it as the fallback for method 3, not a first step.

### Not recommended
- **fastText or bag-of-n-grams models.** They're tiny (under 100 KB when quantized; Joulin
  et al. 2016), but they need thousands of in-domain examples, and they behave like the
  textcat that scored 0.39.
- **Zero-shot NLI models.** They're too big for the benefit.
- **Dialogue-act models that use previous turns.** Previous-turn context adds ~5 points on
  Switchboard (73.7% utterance-only vs 79.1% with 3 prior labels; Ribeiro et al. 2015), but
  Margins have no previous turn.

## Public labeled data for segments

| Dataset | What it labels | Size | License | Use for us |
|---|---|---|---|---|
| **AMI Meeting Corpus** dialogue acts | 15 acts in spontaneous meeting speech: Inform 28%, Assess 19%, Suggest 8%, Elicit-Inform 4%, Offer, Be-Positive/Negative, Backchannel, Stall, Fragment… | ~100 h of meetings | **CC BY 4.0** | **Training a shippable head.** Assess ≈ reaction or opinion, Elicit-* ≈ question, Suggest/Offer ≈ to-do-like, Inform ≈ claim. Spoken and disfluent, like Margins. |
| Switchboard Dialog Act Corpus (SwDA) | 42 DAMSL tags on telephone speech, including statement vs opinion (sd/sv), wh/yes-no/declarative/rhetorical questions, appreciation, **quotation** (q), commit | ~200k utterances | CC BY-NC-SA 3.0 | Evaluation and research only. The NC license makes a shipped model trained on it risky. It's the only corpus with a quote and a rhetorical-question tag. |
| ICSI MRDA | Meeting dialogue acts; 5 coarse classes (statement, question, floor-grabber, backchannel, disruption) | ~180k tags, 72 h | Free for research, © ICSI | Evaluation only. |
| DailyDialog | 4 acts: inform, question, directive, commissive | 13k dialogues (written, textbook-like) | CC BY-NC-SA 4.0 | Evaluation only, and a weak match: it's written, not spoken. |
| ClaimBuster | Check-worthy factual claim vs unimportant fact vs non-factual, on US presidential debates | 23.5k sentences | CC BY 4.0 | Claim vs opinion/reaction, if we ever split `claim`. Spoken debate style. |
| IBM Debater claim sentences | Sentences containing a claim about a topic (Wikipedia) | 2.5k labeled test set | CC BY-SA 3.0 | Weak match (encyclopedic text). Low priority. |
| MIDAS | Hierarchical multi-label acts for open-domain human–machine talk | 24k utterances | Not stated; ask the authors | Not until the license is known. |
| Enron/Avocado commitment and request data | Sentence-level request and commitment labels in email | Varies | Enron text is public, but annotation licenses vary; Avocado is LDC | To-do detection. Written, so a weak match. Low priority. |

Mapping any of these to our six kinds loses things. None has `connection`, and only SwDA
has `quote`. So public data can pretrain or sanity-check `question`, `todo`-like,
`reaction`-like and `claim`, but `connection` and `quote` need owner practice labels, or rules.

## What's likely to beat the current rules, and what it costs

| Option | Likely effect on kind views | Cost |
|---|---|---|
| Recognizer punctuation on, then sentence segments (1, 2) | Biggest, cheapest gain in question and to-do precision; the Mac session is already planning it | Under one session; no app-size cost |
| Abstention thresholds on segment rules (2) | Turns a wrong guess into an empty field. That's what makes "my open questions" trustworthy | Included above |
| `NLContextualEmbedding` + logistic head, trained on AMI (CC BY) + owner practice labels (3) | Probably the only no-Apple-Intelligence option that handles paraphrase; could lift claim vs reaction and connection | 1–2 Mac sessions; ~200–400 labeled segments; KB-sized head; OS asset download |
| Bundled MiniLM Core ML encoder (4) | Same as 3, with no OS dependency | +25–45 MB app size; only if 3 fails |

**Recommended order:**
1. Do 1 and 2 in the planned session, as decided.
2. If kind views still miss the owner's precision bar, try 3 next, trained only on
   CC-BY/CC-BY-SA data plus owner labels.
3. Use SwDA and MRDA only to evaluate.
4. Hold 4 in reserve.

## Sources

- AMI corpus license (CC BY 4.0): https://groups.inf.ed.ac.uk/ami/corpus/license.shtml
- AMI dialogue act guidelines: https://groups.inf.ed.ac.uk/ami/corpus/Guidelines/dialogue_acts_manual_1.0.pdf
- SwDA and its license: https://github.com/cgpotts/swda, https://huggingface.co/datasets/cgpotts/swda
- MRDA: https://github.com/NathanDuran/MRDA-Corpus, https://aclanthology.org/W04-2319/
- DailyDialog: https://huggingface.co/datasets/li2017dailydialog/daily_dialog
- SILICONE benchmark (packages SwDA, MRDA, DailyDialog acts): https://huggingface.co/datasets/silicone
- ClaimBuster (CC BY 4.0): https://zenodo.org/records/3609356
- IBM Debater datasets: https://developer.ibm.com/technologies/artificial-intelligence/data/claim-sentences-search/
- MIDAS: https://aclanthology.org/2021.eacl-main.94/
- Stolcke et al. 2000, Dialogue act modeling: https://aclanthology.org/J00-3003.pdf
- Ribeiro et al. 2015, Influence of context on dialogue act recognition: https://arxiv.org/pdf/1506.00839
- SetFit: https://huggingface.co/docs/setfit/en/index
- fastText.zip (compressed classifiers): https://arxiv.org/pdf/1612.03651
- `NLContextualEmbedding`: https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding
- Create ML with BERT embeddings (WWDC23): https://developer.apple.com/videos/play/wwdc2023/10044/
- `addsPunctuation`: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/addspunctuation
- Lightweight punctuation restoration (ELECTRA-small, Interspeech 2023): https://www.isca-archive.org/interspeech_2023/polacek23_interspeech.html
