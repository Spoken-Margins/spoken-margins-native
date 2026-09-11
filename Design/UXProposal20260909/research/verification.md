# Artifact verification

## Passed

- Fresh native simulator build of the inspected candidate, using SpokenMarginsApp on iPhone 17 Pro / iOS 26.5. Build completed successfully; existing deprecation warnings were recorded by XcodeBuildMCP.
- Interactive traversal of the phone states listed in the method and 23 retained screenshots.
- JavaScript syntax checks for prototype.js and audit.js.
- Static asset build and local reference validation for the book.
- DOM simulation with LinkeDOM 0.18.12: all 20 concept screens render; buttons have text or accessible names; document IDs and chapter anchors are unique/valid; 24 findings render.
- Main loop: Library → listen → record → save/resume → Timeline → note.
- State preservation: starring, selected export voice representation, explicit add after follow, non-autoplay after import, and imported title in playback.
- Distinct text/audio control semantics and distinct recipient source/position checks.
- Findings severity filtering, expansion and dynamically inserted screenshot reference integrity.
- Authored draw.io XML parses successfully (21 cells). Optional CLI edge routing did not complete and was stopped; the valid authored graph remains intact.

## Contrast review

Sample semantic foreground/background pairs were calculated using the sRGB relative-luminance formula. Body/paper 11.04:1; muted/paper 4.79:1; white/primary green 9.14:1; player text/background 11.18:1; player metadata/background 7.78:1; source-note text/yellow 11.10:1. Four initially weaker proposed metadata pairs (ready, search, timeline positions, and mini-player metadata) were darkened. This is a token-pair review, not full rendered-state conformance.

## Not established

Print pagination and a complete rendered accessibility audit remain unverified. CSS includes reduced-motion handling, focus styles and print rules, but their presence is not proof of conformance. No app tests were rerun for this design-only artifact. The repository's prior app gates remain separate evidence.

The iPad launch timeout, microphone-denial test, test-only recording client, generated-turn fixtures, non-pristine onboarding state and physical-device limitations are recorded in the audit method. No native product flow is declared human_validated by this task.

## Browser QA follow-up · 9 September 2026

The user reported missing images in the published book. Reproduced in the Codex in-app browser: `prototype.js` failed at startup because its global `top` function conflicts with the browser’s `window.top`. All 10 static phone plates, the iPad composition, and the interactive scene chooser were consequently empty. The simulator JPEG files were present; off-screen lazy images had not yet loaded.

Renamed the prototype header helper and its 12 calls to `phoneTop`. No native app code or visual direction changed.

Verified the repaired source in the actual browser:

- All 10 static phone plates contain rendered screens; the iPad composition contains content.
- Every one of the 20 scene buttons renders its phone state.
- Continue → Add a Margin → Save & resume → Timeline displays the expected recording, saved, and review states.
- All 28 screenshot placements load, representing 23 distinct JPEGs, each with a decoded natural width of 368 pixels.
- Desktop cover and evidence gallery visually reviewed at 1440 × 1000; mobile arrival and Library plate reviewed at 390 × 844. Document width matches viewport at both sizes.
- No new browser script errors during the repaired-source pass.

These are web artifact checks, not native product-flow validation.

## Second edition · September 10

Superseding browser and interaction evidence for the redesigned web concept is in [second-edition.md](second-edition.md). The original native app audit remains historical evidence from September 9. The product owner's subsequent rejection of the first proposal's use of space is documented there; the first design must not be described as human-validated.
