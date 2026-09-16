# Verification record

Base: `6432044bdc5ebff4691a69bee2699c309222ebac`, branch `codex/provisional-next`, dirty working candidate. No commit, physical install or distribution. No new human validation. Account remaining: 74% at audit start, 67% at closeout; 65% owner floor preserved.

## Final evidence

| Check | Result | Evidence |
|---|---|---|
| Runner self-tests / browser extraction | 10 / 12 passed | `artifacts/test-runs/project-audit-2026-09-15-complete/` |
| Contracts, surfaces, inventory, built bundle wiring | Passed | Same directory, individual logs and manifest |
| Complete package selection | 300 passed, 1 declared held-out-corpus skip, 0 missing | Same manifest, `package.log` |
| Complete release Xcode selection | 476 passed, 7 failed, 0 missing (483 expected/executed) | `xcode-tests.log`, finalized `tests.xcresult` |
| App-only rerun after fixture correction | 437 passed, 5 failed (442 expected/executed); preparation regression passed | `artifacts/test-runs/project-audit-2026-09-15-app-final/` |
| Focused retry after simulator restart | All 9 selected tests passed, exit 0 | `focused-final.log` in this audit directory |
| Working-tree whitespace | `git diff --check` passed | Closeout command |

Do not add counts across runs; cases overlap. The release run and app rerun are **failed gates**. Focused success does not retroactively make either green. Six UI failures remain unresolved; see `audit.md` for exact observed assertions, evidence corrections and next discriminators. The five app-rerun failures passed both in the broad run and the focused reboot retry; audio-service errors and a SQLite lock make them intermittent evidence, not proven repaired product failures.

The only source change after the complete release run was the new preparation test's fixture: it now uses `libraryStoreForTesting()` and does not unlink a live SQLite/WAL connection. Production runtime code did not change. The app rerun compiled that final fixture. The focused retry used its same built app/test product. XcodeGen normalized the checked-in app scheme; that generated output remains in the diff.

## Negative cases retained

- `speech-before.log`: one new test, four failed assertions for newline, CRLF, tab and the #111 defanged-domain excerpt. `speech-after.log`: six speech-projection tests pass.
- `preparation-counterexample.log`: readyOffline persisted, but row becomes onlineOnly. Earlier attempt stalled before tests; first executed fixture version hit a database lock. Neither counts as a product counterexample.
- First broad app attempt: three existing Follow/Margin retrieval tests failed. Production data-ownership fixes made all three pass without changed assertions or timing sleeps.
- Initial runner failure: obsolete package test-bundle path. Next package attempt: stale sharing policy assertion. Both retained in prior manifests/logs.

## Simulator boundaries

- Manual iOS 18.6 synthetic smoke: playback advancement, pause, Timeline, correct one-Margin session selection on Export; intermediate build, screenshots preserved.
- Automated iPhone 17 Pro / iOS 26.5: complete release selection, app retry, focused retry. Full emoji article speech/pause/resume canary passed in 214.113 seconds. No acoustic-quality judgment.
- Post-test `simctl diagnose` collection was interrupted after all tests ended to permit Xcode result finalization. This limits OS diagnostic dump completeness, not test execution counts.
- No physical AirPod, actual Lock Screen incident, neural-model output, jetsam/memory profile, frame-time comparison or live provider account validation. The user's exact incident is still unattributed.

## Focused retry selection

1. Final chunk cannot undo persisted offline completion.
2. Follow discovery rechecks subscriptions before publishing.
3. Late Follow discovery cannot publish under another item.
4. Global Margin search/stars/shared rows preserve session identity.
5. Exact local-audio package advances, supports Skim and survives reconstruction.
6. Feed-entry import preserves title/source without replacing active playback.
7. AirPod route-loss simulation publishes pause and permits remote resume during partial generation.
8. Generation token cancels stale render after replay.
9. Observed playback start stays pending while the player is paused.

All nine passed after reboot. `evidence-summary.json` records machine-readable run references and per-case focused results.
