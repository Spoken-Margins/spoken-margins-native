# Parallel Track Coordination

> Archive note: this document is reference-only. The active default workflow is `AGENTS.md`. Use this parallel-track process only when the product owner explicitly requests parallel agents with a named steward, named agents, allowed files, forbidden files, and merge order.

This document defines how steward and gate agents coordinate parallel work without creating incompatible contracts.

## Core Rule

Parallel tracks may extend their assigned surface contracts only inside vocabulary already accepted by the steward. If a track needs a new shared command, snapshot field, schema shape, fixture family, trace event, trace expectation key, runtime model, or validator behavior, the track records a backend request instead of inventing the shared vocabulary locally.

## Steward Packet

Before spawning parallel tracks, the steward publishes a short packet in the kickoff prompt or tracking issue.

The packet must include:

- base branch and expected target branch
- assigned track names and non-overlapping file ownership
- allowed files for each track
- forbidden files for each track
- canonical command ids from `validation/contracts/command-matrix.json`
- canonical snapshot field ids from `validation/contracts/snapshot-fields.json`
- allowed delegation modes from `validation/contracts/delegation-modes.json`
- allowed trace commands, events, and expectation keys
- fixture families that are schema-validated by `scripts/validate-contracts.py`
- explicit merge order
- expected final handoff format

If the steward packet omits a field, command, fixture family, or trace assertion, gate agents treat it as unavailable.

## Gate Track Rules

Gate tracks may:

- edit their assigned `validation/surface-contracts/*.json` file
- edit their assigned `validation/agent-cards/*.md` file
- add gate-specific notes under `docs/` when requested
- add backend requests for missing shared vocabulary or runtime behavior
- run the two contract validators allowed by `AGENTS.md`

Gate tracks may not:

- edit shared runtime or Xcode project files
- edit shared command, snapshot, delegation, schema, or validator files after kickoff
- add new command ids outside `command-matrix.json`
- add new snapshot field ids outside `snapshot-fields.json`
- add new delegation modes outside `delegation-modes.json`
- add new fixture directories unless the steward packet says the fixture family is schema-validated
- add executable trace expectations for keys that the trace harness does not already support
- treat validator success as proof that a trace is replayable or a runtime behavior exists

## Executable Trace Rule

Files under `traces/` are executable behavior contracts when they are listed in SessionKit trace replay. They are not narrative examples.

A gate agent may change a replayed trace only when every new command, event, and expectation key is already supported by the replay harness and runtime. Otherwise the agent must leave the trace unchanged and add a backend request describing the desired trace coverage.

Trace proposals that cannot replay yet belong in docs or backend requests, not in active trace files.

## Contract Proposal Rule

A proposed shape is not accepted vocabulary until the steward lands all required shared pieces:

- schema, if the shape is serialized
- validator rule, if the shape lives under `fixtures/`, `traces/`, or `validation/`
- command matrix entry, if it is invoked as a command
- snapshot field matrix entry, if a surface reads it from snapshots
- trace harness support, if a trace asserts it
- runtime model support, if SessionKit loads, persists, exports, or emits it

Until then, gate agents should describe the shape in a backend request with enough detail for the steward to implement it.

## Handoff Format

Every gate handoff must include:

- changed files
- contract deltas
- backend requests
- tests run
- tests not run
- open risks
- any shared vocabulary needed but not present in the steward packet
- whether the PR contains executable trace changes

## Merge Discipline

The steward reviews parallel PRs in this order:

1. duplicate PR cleanup
2. shared vocabulary requests
3. executable trace compatibility
4. gate-local surface contract changes
5. docs-only context

If two tracks modify the same file or introduce competing vocabulary, the steward pauses merge and either lands shared vocabulary first or asks the tracks to rebase onto a revised steward packet.
