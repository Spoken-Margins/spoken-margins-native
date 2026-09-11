# Chapter navigation follow-up — September 11, 2026

Owner report: scrolling the Item page after generating 24 scenes with summaries for a Dwarkesh Patel episode is laggy; generated scenes are missing from Timeline. Exact installed build and episode URL were not supplied.

## Changes

- Item scene rows are lazy and the scene section compares its scene values and model identity before rebuilding. It does not observe the broad playback model. Projected scene timestamps are sorted when item detail is loaded instead of during rendering. Titles, summaries, stable IDs and existing scene seek actions are preserved.
- Timeline now includes generated scenes with Listening map provenance, generated-scene labels, summary excerpts, and the existing timestamp-based scene seek action. Publisher chapters remain separate.
- Description chapter parsing accepts linked visible timestamps, parentheses/brackets, MM:SS and HH:MM:SS, fractional seconds, HTML block breaks, Markdown links, numeric entities and common spacing/dash entities. Title colons are retained. Numeric components are validated, duplicate times removed, and at least two distinct chapters required. Arbitrary URL parameters are not interpreted as chapter times. Document and chapter counts are bounded.
- RSS parsing keeps the richest usable description chapter list even when a brief summary arrives first. Existing structured chapter-source precedence is preserved. This applies when episode metadata is resolved; it does not backfill the owner's installed library or replace generated scenes.

## Evidence and limits

- The old parser returned no chapters for a linked, parenthesized two-chapter example; the changed parser returned 0 and 942000 ms with the expected titles.
- App verification: 409 passed, zero failed/skipped, including four added regressions. iPhone 17 Pro Simulator, iOS 26.5. Manifest: `artifacts/test-runs/20260911-135318-245516-app/manifest.json`.
- Final fast verification: `artifacts/test-runs/20260911-135613-484880-fast/manifest.json` — verified.
- Both final manifests identify source input `006441495be3da2a5f030204bf144b0ef3e26b4f1a06e71f006f2ad8ffdf1c2f`. Base commit remains `ec2155707b3f416932123c4bf56d939fb209d4ba`; changes are uncommitted.
- Initial app compilation failed because Swift actor isolation prevented the view's Equatable conformance. The comparison was made nonisolated; the subsequent build and executed suite passed. Original failure retained at `artifacts/test-runs/20260911-135244-103322-app/manifest.json`.
- The eager layout and broad invalidation are code-backed performance risks, not a measured device root cause. No before/after frame-time trace or product-owner acceptance exists yet.
- No upload, install, archive replacement or release handoff was performed. The earlier Build 27 IPA predates these changes. The next distribution candidate needs a new release gate, device-matrix checks and archive/export.
