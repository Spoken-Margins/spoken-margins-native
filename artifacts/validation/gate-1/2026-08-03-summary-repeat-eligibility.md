# Repeat Interjection Summary Eligibility

- Date reported: 2026-08-03
- Reporter: product owner
- Remediation build: 12
- Branch: `codex/mvp-local-foundation-models`
- Base commit at verification: `b4bd7f2` plus the documented working-tree changes
- State: `verified`; awaiting product-owner revalidation

## Product-owner report

The first on-device interjection summary completed successfully, but the Summarize Notes button remained disabled. Adding another interjection did not re-enable the action.

## Diagnosis

The UI combined three different states into one busy predicate:

- an unfinished summary model job;
- a completed summary waiting in the playback queue;
- a completed summary that was the current playback target.

Only the first state means summary generation is in progress. The latter two caused a stale disabled button even after a new unsummarized interjection became eligible.

## Remediation

`isSummarizingInterjections` now represents only an unfinished summary job. A completed summary may remain queued or may be playing without blocking another summary once a new eligible interjection exists. With no new interjection, the existing unsummarized-interjection eligibility rule continues to keep the button disabled and prevents duplicate work.

## Automated evidence

The focused app-model regression performs this sequence:

1. create an interjection;
2. complete its local summary while that summary remains queued;
3. verify that generation is no longer busy but duplicate summarization remains unavailable;
4. add a second interjection;
5. verify Summarize Notes becomes available;
6. summarize again and verify the completed summary covers both interjections;
7. verify completed summary playback state does not restore the stale busy flag.

Focused result: 1 passed, 0 failed. Product-owner use is required before the flow becomes `human_validated`.
