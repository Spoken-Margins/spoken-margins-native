# Final candidate review

All 36 identities in `inputs.json` matched before and after review.

## Recheck of imported-layer Listen

No defect recorded. `git diff HEAD` shows that the `hasVoice` **Listen** condition and the direct `listenToImportedCommentary` recording-preview path both predate this final candidate; this candidate only compacts/reorders the imported-layer card. The existing action plays the reviewed Margin recording and returns to the current source; it does not navigate or seek to the imported anchor.

That distinction matches [`docs/interjection-sharing-and-article-acquisition.md:54`](../../../../docs/interjection-sharing-and-article-acquisition.md:54) and [`docs/interjection-sharing-and-article-acquisition.md:79`](../../../../docs/interjection-sharing-and-article-acquisition.md:79): ambiguous or unresolved anchors are never navigable and must not cause an automatic recipient interruption. The model keeps resolution eligibility for automatic/prompt playback and anchor navigation ([`Gate1AppModel.swift:6616`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:6616), [`Gate1AppModel.swift:6695`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:6695)); the manual recording preview is a separate existing behavior. The source-backed contract therefore does not require gating this action, and the existing **Listen** label is contract terminology for the manual companion choice. A preview-specific label would be a product-language choice, not a source-backed repair for this candidate.

## Closure and omission check

The integration disposition's replay repair is present: `startItem` resumes only an unfinished continuation and otherwise starts a new session. Written media capture now persists unavailable context when no cached shoulders exist, while `MarginRow` suppresses retry/Needs Attention for a valid written Margin. The compact Item screen keeps one primary listening action, and the Library row has explicit accessibility actions for play, completion, offline preparation, and deletion.

The candidate contains code paths for the approved state inventory: Add; ready/Item; Sources/Following; share/received; offline/settings; first/finished; Skim/shared-playing; Timeline; Library; player; recording; and Margins. This is code-presence coverage only. I did not run a build, tests, simulator, or inspect native screenshots/accessibility trees in this pass, so final-candidate layout, Dynamic Type reachability, and runtime behavior remain unproven here.
