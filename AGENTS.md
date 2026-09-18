# Agent Rules

## Default Workflow

This repository uses a single-agent workflow by default. An agent should work end to end on the requested task unless the product owner explicitly asks for parallel agents.

Parallel-agent rules are archived in `docs/parallel-agent-workflow-archive.md`. Do not use that workflow unless the product owner explicitly names a steward, gate agents, allowed files, forbidden files, and merge order.

## Working agreements

- Treat a request for action as authorization to complete the work within its stated scope. Make reasonable assumptions for routine, reversible decisions and continue independent work while resolving material questions.
- Follow explicit user direction over skill guidelines and historical task notes, within system/tool constraints. Preserve product and release boundaries unless the user changes them. Do not ask again for authorization already given.
- Before requesting a decision, prepare the authorized work needed to make it concrete and reviewable. If a skill blocks progress, identify the file and exact rule, explain its application, and distinguish that rule from your interpretation.
- Keep updates and handoffs concise: outcome, evidence, and any remaining blocker. State assumptions and do not equate a passing build with product validation.
- Preserve unrelated working-tree changes. Stop broadening verification once required checks pass; rerun only for a changed input, a failure diagnosis, or an unresolved concern. If an unchanged failure persists after diagnosis and a justified retry, report the blocker and continue independent authorized work instead of repeating the same check.
- Treat model usage and user attention as limited resources, separate from machine execution time. Long-running checks can require substantial execution without requiring repeated agent analysis. Before inspecting progress again, identify what new evidence could change the next action; if none is expected, prefer tool-managed waiting and compact status reporting within platform constraints. Repeated unchanged results are a signal to simplify supervision. Preserve required verification and investigate failures; optimize the overhead around the work.

### Simulator crash incidents

If simulator system processes start producing crash dialogs, stop the active test and shut down the affected simulator. Do not repeat unchanged tests, reboot repeatedly, or switch devices to bypass the incident. Preserve crash evidence, diagnose the failing system state, and apply an evidence-backed repair before a bounded recovery check. A successful recovery check is distinct from app verification. Honor an explicit owner stop before any further simulator boot.

### Second-edition status

The September 10 redesign implementation and verification are complete; all delegated leases are returned. The single-agent default applies to subsequent tasks. The task-specific agent names, Terra assignments, and usage budget in `docs/second-edition-release-decision.md` and `docs/second-edition-work-packets.md` are historical authorization, not standing assignments for new work.

See `artifacts/validation/gate-1/second-edition/handoff.md` for the exact candidate and pending owner validation. This closeout does not reverse the approved redesign or authorize distribution, a commit, merge, or baseline advancement. Follow the current release lane for subsequent work.

## Release Lane Routing

Before creating a branch or changing implementation code, read `docs/release-lanes.md`. It is the authoritative source for active branch purposes, authorized issue scope, merge direction, and queued work.

- Work only on an issue authorized for the current release lane.
- Do not create an issue-specific or dependency-specific branch when the work belongs to an existing release lane.
- Treat branches not listed as active in `docs/release-lanes.md` as historical and read-only unless the product owner explicitly reactivates one.
- If a request conflicts with the recorded lane, issue scope, or merge direction, state the conflict and ask whether the product owner intends to change the release plan. Do not silently reinterpret the request or invent another branch.
- An explicit product-owner change to the release plan is authoritative. Update `docs/release-lanes.md` before implementation so later human and agent work sees the same decision.

## Human Validation Rule

Only the product owner validates product flows.

Agents verify implementation claims with tests, builds, traces, static checks, and checklists. Agents must not call a flow validated because automated checks passed. Once the product owner validates a flow, agents may add focused regression coverage to preserve that behavior.

Use these states consistently:

- `implemented`: the app has a user path or runtime path.
- `verified`: automated checks or developer evidence support the implementation.
- `human_validated`: the product owner used the flow and accepted it.

## Test And Build Policy

For documentation-only changes, check instruction consistency, referenced paths and commands, and the diff; run code checks only when the documentation change affects an executable contract or required gate. Do not add tests that merely restate documentation or mirror a low-impact implementation. For behavior changes, add meaningful regression coverage at the affected boundary.

For code changes, routine development should prefer fast checks:

```bash
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/verify-tests.py --plan fast
```

The fast plan executes the complete package and browser suites, validators, and
test-inventory checks. Compilation alone is not test execution. For app changes,
also run `--plan app`; for OS audio/inference changes run `--plan adapters` and,
when speech input or playback changes, `--plan speech-canary`. Use `--plan ui`
for the scoped UI seams and `--plan release` before release handoff. See
`docs/testing.md` for exact selections, build reuse, device selection, timeout
behavior and machine-readable evidence. Missing tests or unexpected skips fail
the gate; never count an interrupted run as passed.

Use app builds when app, Watch, widget, extension, project, signing, or package integration changes need verification:

```bash
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsWatch -destination 'generic/platform=watchOS' build | xcbeautify
```

`SpokenMarginsAppDevice` is the optional Kokoro/MLX device scheme. Run it only when validating Kokoro-specific work and only after Xcode's Metal Toolchain component is installed:

```bash
xcodebuild -downloadComponent MetalToolchain
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsAppDevice -destination 'generic/platform=iOS' build | xcbeautify
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
