# Gate 5 Browser Text Handoff

## Purpose

Gate 5 validates browser text capture as an intake path into Spoken Margins. Browser text is separate from browser media: it creates text-backed items and text anchors, not media-time or transcript-backed sessions.

## Handoff Payload

The browser extension should hand off one text capture payload to the canonical phone/tablet runtime:

```json
{
  "schemaVersion": "browser-text-handoff.v1",
  "captureMode": "selected_text",
  "contentFormat": "plain_text",
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
- `captureMode`: `selected_text`, `readable_page`, `markdown_file`, or `plain_text_file`
- `contentFormat`: `plain_text` or `markdown` for new payloads; omitted legacy payloads are treated as plain text
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

The native app reads the payload and imports it without replacing an active session. It deletes the payload after success. A failed payload moves once to `FailedBrowserTextHandoffs` and appears in Settings > Import Inbox, where the user can retry or delete it.

## Runtime Behavior

- `importBrowserText` creates a normal `item.v1` record with `mediaType: text` and preserves the source URL or file reference.
- Selected text remains plain text. Readable pages and Markdown files preserve Markdown headings, which are normalized through `ObsidianMarkdownParser` and can produce a deterministic Listening Map immediately.
- Both the Safari Web Extension and Safari share preprocessor use the pinned local Defuddle 0.19.4 bundle with `useAsync: false`. Extraction cannot send the page to a third-party fallback.
- The Safari popup reads the result directly from `scripting.executeScript`; it does not depend on a second `tabs.sendMessage` round trip after injection.
- If Defuddle cannot produce readable Markdown, the extension falls back locally to semantic content from `article`, then `main`, then `body`, while preserving headings and paragraphs where possible.
- Both bundled and native emergency semantic fallbacks consume each DOM block's text once: descendants already included in a quotation or list container are not emitted again. Identical sibling prose is retained, since it may be intentional repetition.
- Speech cleanup preserves dotted abbreviations such as `U.S.`, `i.e.`, and `Ph.D.` as well as decimal references; bare-domain removal requires an alphabetic top-level label of at least two characters.
- Reimporting an automatically identified readable page with changed text creates a separate content edition, preserving the earlier item's text, sessions, maps and Margin anchors. Reimporting unchanged text retains the existing edition and prepared media, restoring it from Trash if necessary. An explicit handoff `itemId` continues to honor its caller-specified target.
- Followed-article diagnostics record `followedArticleExtractor` so a future capture can distinguish the primary, bundled fallback and native emergency extraction paths. This is diagnostic metadata, not a new handoff schema field.
- Safari owns capture/extraction/metadata and delegates playback plus interjections to the native app.
- Browser-owned TTS and browser recording remain follow-up work.
- Summary and discussion continue in the app for Gate 5.

## Failure Cases

- If the native app is unavailable, the extension keeps the App Group payload for the next app activation.
- A failed import is quarantined rather than retried on every app activation.
- If microphone permission is missing, interjection commands are unavailable but text capture and handoff remain valid.
- If Defuddle extraction fails, semantic DOM fallback is attempted before the extension reports a page-capture error; selected-text capture remains independently available.
- If no title is available, the browser should derive a title from the URL host or first text heading before handoff.

## Backend Requests

- `importBrowserText` is the app-side import command for Gate 5 validation.
- Durable payload loading is implemented with the `payloadId` URL path.
- Publish `availableCommands` so browser UI can hide recording and playback controls when permission or runtime capability is absent.
