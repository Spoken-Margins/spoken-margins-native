# Agent Rules

## Default Workflow

This repository uses a single-agent workflow by default. An agent should work end to end on the requested task unless the product owner explicitly asks for parallel agents.

Parallel-agent rules are archived in `docs/parallel-agent-workflow-archive.md`. Do not use that workflow unless the product owner explicitly names a steward, gate agents, allowed files, forbidden files, and merge order.

## Human Validation Rule

Only the product owner validates product flows.

Agents verify implementation claims with tests, builds, traces, static checks, and checklists. Agents must not call a flow validated because automated checks passed. Once the product owner validates a flow, agents may add focused regression coverage to preserve that behavior.

Use these states consistently:

- `implemented`: the app has a user path or runtime path.
- `verified`: automated checks or developer evidence support the implementation.
- `human_validated`: the product owner used the flow and accepted it.

## Test And Build Policy

Routine development should prefer fast checks:

```bash
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
swift build --build-tests --package-path Packages/SessionKit
```

Use app builds when app, Watch, widget, extension, project, signing, or package integration changes need verification:

```bash
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsAppDevice -destination 'generic/platform=iOS' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsWatch -destination 'generic/platform=watchOS' build | xcbeautify
```

Broad UI route automation is late-gate evidence. Run it before asking the product owner to close a gate, or after a human-validated flow needs regression protection. Do not require broad UI routes for every development iteration.

## Product Validation Handoff

Before asking for human validation, provide:

- build number and commit SHA
- supported devices and OS versions
- exact in-scope and out-of-scope flows
- known issues
- reset instructions
- seeded sample items
- diagnostics location or export
- verification summary
- product-owner checklist with pass/fail notes

Record human validation evidence under `artifacts/validation/gate-N/`.

## Specification Discipline

Contrast implementation work against the product/spec docs. If the product direction changes, update the relevant docs instead of preserving stale gate language.

Do not introduce new command ids, snapshot field ids, delegation modes, fixture families, or trace language unless the matching schema, validator, runtime, and tests are updated in the same intentional change.

## Working Tree Safety

The worktree may contain user or agent changes. Do not revert files you did not intentionally change. If unrelated dirty files exist, leave them alone. If existing changes affect the task, work with them and call out any residual risk in the handoff.
