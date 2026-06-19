# Track B Link Intake Notes

Track B defines contract-level share-sheet and paste URL intake for public podcast links without adding runtime trace language or provider clients.

## Contract deltas

- URL intake uses the steward-approved `importSourceLink` command only.
- The link intake surface may observe `linkResolutionStatus` and `linkResolutionFailureReason`, but those fields remain backend-request snapshot fields until the steward adds runtime output.
- Public RSS/audio-backed podcast links resolve to `Item.mediaType = "transcript_backed_media"` and `AudioRepresentation.sourceType = "remote_stream"`.
- Exclusive/private provider links must not synthesize playable audio. They remain `unsupported` unless a public RSS/audio enclosure is found.

## Backend requests

- Add share-extension and paste routing into `importSourceLink`.
- Add provider-independent lookup for public podcast episode pages and RSS/audio enclosures.
- Add queue UI/runtime persistence for resolving, playable, needs-review, and unsupported link states.
- Add runtime snapshot output for `linkResolutionStatus` and `linkResolutionFailureReason`.

## Trace status

No executable link-intake traces are added in this track. Link-resolution events are not replayable trace language until steward runtime and harness support lands.
