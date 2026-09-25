# Gate 5 Agent Card: Browser Text

## Role

Advance the Gate 5 Browser Text contract and handoff shape without changing shared SessionKit implementation or Xcode project files.

## Allowed Files

- `validation/surface-contracts/gate5-browser-text.json`
- `validation/agent-cards/gate5-browser-text.md`
- Gate 5-specific notes under `docs/` if needed

Gate 5 must also follow `docs/archive/parallel-track-coordination.md`, `docs/surface-contract-governance.md`, and the steward packet for the active branch.

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
- Backend requests for `importBrowserText` and app continuation.
- Final handoff with changed files, contract deltas, backend requests, tests run, tests not run, and open risks.

## Contract-First Limits

- Use only command ids already listed in `validation/contracts/command-matrix.json`.
- Use only snapshot fields already listed in `validation/contracts/snapshot-fields.json`.
- Use only delegation modes already listed in `validation/contracts/delegation-modes.json`.
- Do not add new fixture families unless the steward packet says they are schema-validated.
- Do not change replayed traces unless every new command, event, and expectation key is already supported by the SessionKit trace harness.
- If Gate 5 needs a new handoff field, command payload, trace expectation, schema, validator, or runtime behavior, record a backend request instead of changing shared vocabulary.
- Validator success is not runtime or trace-replay proof.

## Out Of Scope

- Browser extension implementation.
- Browser media / YouTube work.
- Xcode project edits.
- SessionKit command or snapshot implementation.
