# Gate 5 Agent Card: Browser Text

## Role

Advance the Gate 5 Browser Text contract and handoff shape without changing shared SessionKit implementation or Xcode project files.

## Allowed Files

- `validation/surface-contracts/gate5-browser-text.json`
- `validation/agent-cards/gate5-browser-text.md`
- `docs/gate5-browser-text-handoff.md`
- `traces/browser-text-session.json`
- `traces/browser-readable-text-session.json`
- `fixtures/items/browser-text-selected.json`
- `fixtures/items/browser-text-readable-page.json`
- Gate 5-specific notes under `docs/` if needed

## Forbidden Files

- `SpokenMarginsNative.xcodeproj/project.pbxproj`
- `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift`
- `Packages/SessionKit/Sources/SessionKit/Models.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift`
- `validation/contracts/command-matrix.json`
- `validation/contracts/snapshot-fields.json`
- `validation/contracts/delegation-modes.json`
- `schemas/surface-contract.schema.json`
- `scripts/validate-surface-contracts.py`

## Allowed Commands

```bash
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
```

## Deliverables

- Browser text surface contract deltas.
- Browser text handoff payload proposal.
- Trace or fixture gaps for `traces/browser-text-session.json`.
- Trace or fixture gaps for `traces/browser-readable-text-session.json`.
- Backend requests for `importBrowserText` and app continuation.
- Final handoff with changed files, contract deltas, backend requests, tests run, tests not run, and open risks.

## Out Of Scope

- Browser extension implementation.
- Browser media / YouTube work.
- Xcode project edits.
- SessionKit command or snapshot implementation.
