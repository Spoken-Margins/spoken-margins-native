# PKM implementation owner check

Candidate: local uncommitted changes on `codex/provisional-next`, based on `ac85375759f2533f320225affef9fb3296bbbf9e`. Development version 0.1 (27); **this is not the uploaded TestFlight Build 27**. No new distribution or commit is part of this task. Exact verification source hash and run records are in `verification.md` beside this file.

Supported app target: iPhone and iPad, iOS 18+. Model actions may require newer OS versions or eligible hardware/accounts. Keep the existing Library; this checklist never requires Reset and Seed on your real installation.

Quick smoke: steps 1–3 and 8–10 exercise the core workflow without an AI subscription or reading-service token. Use the remaining rows for replacement/conflict recovery, notifications, and live account acceptance. The earlier incomplete-feature audit remains in `artifacts/validation/pkm-audit-2026-09-12/owner-test-procedure.md`.

Setup instructions: `docs/pkm-workflows.md`. Seed item: `Contracts/fixtures/listening-editions/article.json`. Use a disposable folder within a test vault for the first export check. Keep your real saved Margins intact.

| Step | Expected experience | Owner pass/fail and notes |
| --- | --- | --- |
| 1. Sources → Import Listening Edition → choose the sample JSON → Preview | Original source and two supplied scene descriptions/summaries are represented; import is explicit | Pending |
| 2. Import Item and Map; return to Library/open item | One new item, no automatic playback; original source, scenes and summaries available | Pending |
| 3. Import the same file again | One item, existing sessions/Margins retained | Pending |
| 4. Change a summary in a copy of that file; import without replacement, then preview and permit replacement | First attempt reports conflict; explicit replacement changes the summary without losing source/session data | Pending |
| 5. Play source; Go to Scene; prepare full audio using the existing preparation control/policy | Native source playback and correct chapter anchor; distinct complete audio boundaries allow supplied summaries in Skim | Pending |
| 6. Enable Ready Notifications before preparing another copy with different source text; tap notification when audio is fully ready | Item opens; notification and actual audible preparation timing agree | Pending |
| 7. Build the recipe with your chosen model action and share a short Safari article | Model generates map response; assembly preserves the original article; file can be saved and imported without app-side model generation | Pending |
| 8. Settings → Margin Output → choose test-vault folder → Send Test Note | Markdown test note appears in Obsidian/Files | Pending |
| 9. Enable automatic output; create a written Margin; return/keep active for 15 seconds | One note with thought, source identity, position and bounded context; no full-source or audio payload | Pending |
| 10. Retry Delivery and relaunch | No duplicate notes; previously missing output retries | Pending |
| 11. Edit an exported file in Obsidian; create another Margin | Outside edit survives; conflict is visible; independent new Margin still exports | Pending |
| 12. Disable output; disconnect/reselect folder if needed | Delivery stops; exported files and canonical Margins remain | Pending |
| 13. Connect Reader with trial/account token; Add one Later article; repeat; paginate; disconnect | Correct readable copy, no duplicate, no service archive/progress mutation; token removed on disconnect | Pending |
| 14. Repeat with a free Raindrop account and personal test token | Original website text imported; inaccessible pages report a failure; no paid archive required | Pending |

Known limitations: no continuous background article analysis/map-generation proof; model action and service accounts untested live; startup audio prewarming does not imply full audio/Skim readiness; automatic Markdown export is active-app delivery with resume retry; external Markdown edits are preserved rather than merged; deleting a Margin does not delete the external note; Raindrop onboarding is a personal integration token, not production OAuth. No signed downloadable Shortcut is included; use the editable native-action recipe.

Diagnostics: use Settings → Developer tools → diagnostic recording/export for a failure, and include the item title and step. Relevant diagnostic keys are `listeningEditionAudio`, `localAudioSkim:<itemID>` and `textAudioPrewarm:<itemID>`. Folder and service errors appear on their respective screens; never include access tokens in a report.

Reset: turn off Automatically Save Margins, disconnect test services, delete only the disposable exported folder and sample item through the normal Library controls. Notification permissions are controlled in iOS Settings. Do not reset the whole Library. A repeated source retains identity; change only the sample text if you need a new notification identity.

In scope: portable full-text JSON editions, three model-independent App Intents, prepared-audio summary integration, ready notification routing, automatic Markdown output, read-only Reader/Raindrop selection and intake. Out of scope: release distribution, native background map generation guarantees, live model subscriptions, map-only files, bidirectional read-later synchronization, paid offerings, Watch/co-op, and other queued audit clusters.
