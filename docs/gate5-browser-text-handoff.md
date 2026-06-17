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

For short app-side Gate 5 validation, the same payload may still be encoded inline:

```text
spokenmargins://browser-text?captureMode=selected_text&title=Example&url=https%3A%2F%2Fexample.com&text=Captured%20text&startSession=1
```

For real browser capture, full page text is not encoded into the URL. The Safari Web Extension writes the payload JSON into the shared App Group container under `BrowserTextHandoffs/<payloadId>.json`, then opens:

```text
spokenmargins://browser-text?payloadId=<payloadId>
```

The native app reads the payload, imports it through `importBrowserText`, and deletes the payload after a successful import.

## Runtime Behavior

- `importBrowserText` creates a normal `item.v1` record with `mediaType: text`, `externalReferenceType: url`, and `externalReference` set to the source URL.
- Selected text and readable-page text use the same import command. `captureMode` only describes where the text came from.
- For this Gate 5 validation slice, Safari owns capture/extraction/metadata and delegates playback plus interjections to the native app.
- Browser-owned TTS and browser recording remain follow-up work.
- Summary and discussion continue in the app for Gate 5.

## Failure Cases

- If the native app is unavailable, the extension keeps the App Group payload so the same `payloadId` can be retried.
- If microphone permission is missing, interjection commands are unavailable but text capture and handoff remain valid.
- If readable extraction fails, selected-text capture remains valid.
- If no title is available, the browser should derive a title from the URL host or first text heading before handoff.

## Backend Requests

- `importBrowserText` is the app-side import command for Gate 5 validation.
- Durable payload loading is implemented with the `payloadId` URL path.
- Publish `availableCommands` so browser UI can hide recording and playback controls when permission or runtime capability is absent.
