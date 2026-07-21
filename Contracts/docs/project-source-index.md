# Project Source Index

## Purpose

Use this file as the stable entry point when Spoken Margins repository context is added to an external project, assistant, review, or planning workspace.

The repository changes frequently. Consumers should load sources by semantic role and canonical path, not by copied line ranges or a permanent assumption about the current file set.

## Drift Contract

1. Read from the repository default branch unless the task is explicitly about a historical commit or release.
2. Record the resolved commit SHA whenever repository context is used in a decision, report, or generated artifact.
3. Re-read this index at the start of each substantial task. Do not assume a previously captured source bundle is current.
4. Treat `Contracts/` as canonical. Top-level `docs/`, `schemas/`, `fixtures/`, and `traces/` are migration-era mirrors unless a canonical file explicitly delegates to them.
5. Do not use line numbers as durable source identity. Cite repository path plus resolved commit SHA.
6. When sources conflict, apply this precedence:
   1. `Contracts/docs/recovery-mvp.md`
   2. canonical schemas, fixtures, and traces under `Contracts/`
   3. `Packages/SessionKit/` behavior and tests
   4. app and extension implementation under `App/`
   5. historical plans and legacy mirrors
7. Capability and historical planning documents may describe surfaces outside the active release. Constrain them with `Contracts/docs/recovery-mvp.md`.
8. If a canonical path moves or its role changes, update this index in the same pull request.

## Primary Source Set

| Role | Canonical path | Use |
| --- | --- | --- |
| Repository entry point | `README.md` | Current purpose, repository map, and canonical-directory guidance |
| Active product authority | `Contracts/docs/recovery-mvp.md` | Product promise, active boundary, evidence gates, and stopping rules |
| Agent and verification rules | `AGENTS.md` | Working rules, verification language, build policy, and validation handoff |
| Runtime architecture model | `Contracts/docs/runtime-capability-model.md` | Capability-based interface and runtime reasoning; subordinate to the active recovery boundary |
| Package topology | `Packages/SessionKit/Package.swift` | Canonical domain, persistence, audio, and AI package boundaries |
| Item data contract | `Contracts/schemas/item.schema.json` | Source-item representation and compatibility constraints |
| Export data contract | `Contracts/schemas/session-export.schema.json` | Session export and assistant-handoff representation |
| Browser intake evidence | `Contracts/traces/browser-readable-text-session.json` | Expected readable-page intake and session behavior |
| External assistant evidence | `Contracts/traces/external-assistant-response-import.json` | Expected assistant-response import behavior |
| Mapless export evidence | `Contracts/traces/mapless-session-export.json` | Expected export behavior without a Listening Map |
| Discussion fixture | `Contracts/fixtures/exports/discussion-session.json` | Representative discussion-session export |
| Mapless fixture | `Contracts/fixtures/exports/mapless-session.json` | Representative mapless-session export |

## Loading Profiles

Load only the smallest profile that supports the task.

### Product or scope work

- `README.md`
- `Contracts/docs/recovery-mvp.md`
- `Contracts/docs/runtime-capability-model.md` when interface or runtime capabilities matter

### Implementation or review work

- product or scope profile
- `AGENTS.md`
- `Packages/SessionKit/Package.swift`
- the relevant canonical schema, fixture, and trace
- implementation files only for the affected subsystem

### Intake work

- `Contracts/docs/recovery-mvp.md`
- `Contracts/schemas/item.schema.json`
- the relevant intake trace or fixture
- affected parser, resolver, extension, and SessionKit files

### Export or assistant-handoff work

- `Contracts/docs/recovery-mvp.md`
- `Contracts/schemas/session-export.schema.json`
- `Contracts/fixtures/exports/discussion-session.json`
- `Contracts/fixtures/exports/mapless-session.json`
- `Contracts/traces/mapless-session-export.json`
- `Contracts/traces/external-assistant-response-import.json`

## Historical Sources

Historical plans can explain why the repository has a particular shape, but they must not silently redefine current scope. Files that identify themselves as historical or archived should be loaded only when the task requires project history.

In particular, `Contracts/docs/product-validation-plan.md` is historical. The active release boundary and current validation checks are in `Contracts/docs/recovery-mvp.md`.

## Exclusions

Do not add these as general project sources:

- `artifacts/`, archives, screenshots, dSYMs, generated bundles, or temporary files
- generated Xcode project content when `project.yml` or package manifests answer the question
- top-level legacy mirrors when a canonical `Contracts/` path exists
- broad application source snapshots without a task-specific subsystem boundary
- secrets, signing material, user data, API keys, or privacy-sensitive diagnostics

## Refresh Procedure

1. Resolve the default branch head SHA.
2. Read this index from that SHA.
3. Confirm the required canonical paths still exist and retain the documented semantic roles.
4. Load the smallest applicable profile.
5. Compare the newly resolved SHA and source roles with the previous capture.
6. Report added, removed, moved, or authority-changing sources before relying on them.
7. If the index is stale, update it before expanding the source bundle.

A consuming project should retain metadata in this form:

```yaml
repository: uncomposed/spoken-margins-native
ref: main
resolved_commit: <sha>
source_index: Contracts/docs/project-source-index.md
captured_at: <iso-8601 timestamp>
loading_profile: <product|implementation|intake|export>
```
