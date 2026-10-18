# Surface Contract Governance

Surface contracts describe what a UI surface may display, command, or delegate. They are not a place to invent shared runtime vocabulary.

## Authoritative Vocabularies

- Commands: `validation/contracts/command-matrix.json`
- Snapshot fields: `validation/contracts/snapshot-fields.json`
- Delegation modes: `validation/contracts/delegation-modes.json`
- Surface contract shape: `schemas/surface-contract.schema.json`
- Trace shape: `Contracts/schemas/session-trace.schema.json`
- Fixture/schema validation: `scripts/validate-contracts.py`
- Surface reference validation: `scripts/validate-surface-contracts.py`

Gate agents may reference these vocabularies. The steward owns changes to them unless a gate has explicit steward assignment.

## Backend Requests

A backend request is required when a surface needs any of the following:

- a new command id
- a new snapshot field id
- a new delegation mode
- a new command payload shape
- a new trace event or expectation key
- a new fixture directory or schema
- a new SessionKit model field
- a new app, Watch, widget, Live Activity, or Xcode runtime path

Backend requests should be specific enough for the steward to implement, but they should not assert the new shape as already executable.

## Snapshot Fields

Surface contracts must use canonical snapshot field names. Do not use shortened aliases in contracts or traces.

If runtime code exposes `currentMediaTimeMs`, a contract must not assert `mediaTimeMs` unless `mediaTimeMs` is separately registered in `snapshot-fields.json`.

## Executable Traces

When a surface contract lists a trace under `traces`, that trace may be replayed by SessionKit tests. Adding a new expectation key can break the test suite even if JSON validation passes.

Before changing a trace, confirm the replay harness supports:

- the command or event name
- every argument key used by the step
- every expectation key used by the step
- any nested payload structure

If support is missing, leave the trace unchanged and add a backend request for steward trace-harness work.

## Validator Limits

`scripts/validate-contracts.py` and `scripts/validate-surface-contracts.py` are necessary but not sufficient. They do not prove that:

- a trace replays
- a runtime emits a field
- a widget or Watch app can consume a field
- a new fixture family is schema-covered unless the validator includes it
- an Xcode build passes

Steward verification must run the relevant Swift tests and builds before promoting a contract from proposal to implemented behavior.
