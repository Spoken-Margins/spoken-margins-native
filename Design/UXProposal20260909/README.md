# Spoken Margins — A Listening Notebook

A human-centered UX/UI audit and interactive HTML/CSS proposal book, authored September 9, 2026, with a task-focused second edition on September 10. This artifact does not implement a native redesign.

## Read and explore

Open `public/index.html` for the book or `public/try.html` for the working second edition, or run `npm run dev` and visit `http://127.0.0.1:4179`. The book needs no third-party scripts, fonts, external images, accounts or runtime services. It contains:

- 13 numbered chapters including the cover and evidence appendix;
- 24 findings with severity, evidence basis, user-impact inference, proposal and falsification task;
- 23 captured iPhone simulator states;
- 20 explorable concept states, including a connected listening/capture/review loop;
- static design plates, an adaptive iPad proposal, failure/empty/offline/permission states;
- an editable `public/experience-map.drawio` resource map;
- a phased proposal and product-owner acceptance criteria;
- print styles and a Print book control.

The JSON register is in `public/findings.json`. The human-readable evidence method is in `research/audit-method.md` and copied to `public/audit-method.md` for the book.

## Build and publication

Use Node 22+ (`24.19.0` was available in the bundled runtime). No dependency installation is required for the book. `npm run build` verifies local entry references and finding evidence, then copies public assets to `dist/`. `.openai/hosting.json` identifies the private Sites publication and static build output. The published source is prepared in an isolated temporary repository so the parent app repository is not committed or pushed by this task.

## Status and limits

- The visual model is `implemented`.
- Static build, syntax, source-link integrity and DOM-simulated core interactions are `verified`.
- Browser rendering and scoped interactions were checked at desktop and phone sizes; see `research/second-edition.md`. Print pagination and full accessibility conformance remain unverified.
- The native redesign is **proposed**, not implemented.
- `human_validated` remains pending product-owner use and acceptance.

The phone audit uses the freshly built 0.1 (26) candidate based on `d8766c43bb0ae54ec15b3254679bba0a9378cd6e` plus the pre-existing compact-presentation diff. This is not the distributed TestFlight 26 binary. While the audit was in progress, another operation advanced the parent checkout to `6325c6c9ddcc3c4d0e1b663e3b7265eda62c9ebb`; the audit did not create that commit or rewrite it. Some early book files were included by that operation; the product owner subsequently committed the completed first edition as `ec21557`. This second edition is a new design-only change.

The additional iPad simulator installed this build but its launch timed out after 300 seconds; no successful native iPad walkthrough is claimed. The iPad mockup is a proposed layout, backed by source review only. Full details of fixture behavior, permissions, source context, untested surfaces, and comparison/stopping rules are in the method document.

All titles, note content, people, progress and readiness inside the proposed phone screens are illustrative. The prototype does not play/record audio, access a microphone or clipboard, import real files, send packages or call AI services.

## Second edition

The first edition is retained at `public/edition-one.html` with isolated `book-v1.css` and `prototype-v1.js`. The current book and `try.html` share the revised `prototype.js`. All 20 proposed states were reworked. Four sample conditions cover everyday content, a long title, 50 notes, and an empty Library; larger web text can be combined with them. The editable experience map now includes a second page for task and viewport contracts.

See `research/second-edition.md` for the critique, decision model, exact browser comparisons, observed checks, limitations, and stopping rule.

## Native implementation proposal

The [supervised implementation plan](../../docs/second-edition-implementation-plan.md) maps the 20 reference states to native work, behavior requirements and verification. Its [execution packet](../../docs/second-edition-work-packets.md) names proposed file ownership and review roles. The [release decision](../../docs/second-edition-release-decision.md) is prepared for owner review; it has not changed the current release authorization or started native implementation.
