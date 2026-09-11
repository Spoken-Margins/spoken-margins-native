# iPad launch report — 2026-09-10

The pasted crash occurred at 16:46:29 during simulator startup, before the current UI runner installed its candidate. It names app container `DDA052C4-126A-4355-9EEF-3D99C01AA02B`, app debug UUID `1FB45048-5258-3E81-8EB4-DA581EE4B051`, and an unresolved old `SessionEngine.deleteInterjection(interjectionId:)` symbol expected in an external development SessionKit framework. This is a launch-time linker failure, before UI execution.

After the runner installed the candidate, its container is `F67A797B-1A0B-4835-89CA-E482F8427396`. Installed and built debug binaries both have UUID `C403B671-CC85-354D-BD65-656901B9BA95`. Both define the new session-qualified deletion method directly; the current binary does not depend on the old external SessionKit framework. See `binary-comparison.json` for the exact captured dependencies and symbol.

Inference supported by timestamp, differing container/UUID, and progressing current UI tests: simulator boot restored a stale development app against a replaced external framework. The test runner replaced that stale installation with its coherent candidate. No production compatibility method or test-cache bypass was added. This report is not evidence of a crash in the current candidate. The current candidate executed all 10 iPad UI cases; eight passed, and two failed because a wide Margin row did not respond to a center tap. There was no current-candidate launch crash. The row failures are tracked separately and not counted as passing evidence. Run: `artifacts/test-runs/20260910-164612-606783-ui/manifest.json`.

Preserved original: `reported-crash.txt`. A later launch failure with the current UUID would falsify this disposition and require fresh investigation.
