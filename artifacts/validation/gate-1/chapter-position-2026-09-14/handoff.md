# Chapter-position investigation — September 14

Base commit ad533d6604dbacf892df85dc06f36d63c2f97a08, local uncommitted candidate; build number unchanged. No phone install, stop/relaunch, reset or distribution. Full app testing deferred. Owner validation pending.

## Observed evidence

Xcode remained attached to Slaw’s iPhone (iPhone 17 Pro), PID 2723, at inspection. Console shows repeated single-sheet presentation warnings and a gesture timeout, without chapter command/position history. The on-device DeveloperDiagnostics/latest.json was copied read-only; its 1,200-event ring buffer ends at 2026-09-14T20:12:52.254Z. It cannot establish later navigation. Do not equate console media warnings with the chapter bug.

A local copy of the device SQLite database and WAL was queried for this PDF only. This is a best-effort live copy, not an atomic backup. Its chapter map has starts 0, 21, 174 and 185 for chapters 1–4, all at rounded 0%. The existing currentChapter getter selected the LAST chapter whose rounded percentage was <= progress. Thus an exact position in chapter 1, 2 or 3 could be inferred as chapter 4. This is a confirmed label-resolution defect, not proof that the reported skip rewound audio.

## Repair

Current native-text chapter inference now uses snapshot.currentTextStart and source boundaries before identity/title/percentage fallbacks. Regression reproduces the phone’s four colliding boundaries and asserts every exact chapter start plus an interior position. Existing PDFs benefit without reimport; no text, chapter map, prepared audio, source offsets or Margins rewritten.

Canonical chapter-forward calculation selects a start strictly greater than its baseline. The unproven alternatives are a stale transport baseline, delayed callback, Skim origin restoration, or an incorrect displayed chapter. The saved recording has no command-level evidence to discriminate these for the reported event. Fresh diagnostics with recording enabled around reproduction are needed if audible regression persists.

## Owner check

After a future authorized install, use the existing NASA PDF (no reset needed), verify the early chapter labels, then skip forward repeatedly and check both spoken text and displayed chapter advance. Pass/fail pending. Also check a normal article and backward navigation. iOS 18+ supported app; focused verification on iOS 18.6 simulator, not physical flow acceptance.

Verified: three focused tests passed, zero failures; app compilation succeeded. See focused.log and focused.xcresult.
