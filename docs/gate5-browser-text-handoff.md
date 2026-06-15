# Gate 5 Browser Text Handoff

## Purpose

Gate 5 validates browser text capture as an intake path into Spoken Margins. Browser text is separate from browser media: it creates text-backed items and text anchors, not media-time or transcript-backed sessions.

## Handoff Payload

The browser extension should hand off one text capture payload to the canonical phone/tablet runtime:

```json
{
  "schemaVersion": "browser-text-handoff.v1",
  "captureMode": "selected_text",
  "source": {
    "url": "https://example.com/pill",
    "title": "You Can't Inspect the Pill",
    "author": null,
    "publishedAt": null
  },
  "text": "Opening distrust is reasonable. Maybe their diet changed.",
  "selection": {
    "textStart": 0,
    "textEnd": 62,
    "prefix": "",
    "suffix": " Maybe their sleep changed."
  },
  "requestedContinuation": {
    "startSession": true,
    "preferredPlaybackOwner": "browser_or_app"
  }
}
```

Required fields:

- `schemaVersion`
- `captureMode`: `selected_text` or `readable_page`
- `source.url`
- `source.title`
- `text`

Optional fields:

- `source.author`
- `source.publishedAt`
- `selection`
- `requestedContinuation`

## Runtime Behavior

- `importBrowserText` creates a normal `item.v1` record with `mediaType: text`, `externalReferenceType: url`, and `externalReference` set to the source URL.
- Selected text and readable-page text use the same import command. `captureMode` only describes where the text came from.
- If the browser profile owns TTS and recording, it may start playback and capture text-anchored interjections locally.
- If the app owns playback or the browser lacks microphone permission, the browser hands off the item/session and the app continues.
- Summary and discussion continue in the app for Gate 5.

## Failure Cases

- If the native app is unavailable, the extension should keep the payload exportable and retry handoff later.
- If microphone permission is missing, interjection commands are unavailable but text capture and handoff remain valid.
- If readable extraction fails, selected-text capture remains valid.
- If no title is available, the browser should derive a title from the URL host or first text heading before handoff.

## Backend Requests

- Implement or route `importBrowserText`.
- Add a durable browser text handoff/package schema if the browser extension moves beyond this Gate 5 contract.
- Publish `availableCommands` so browser UI can hide recording and playback controls when permission or runtime capability is absent.
