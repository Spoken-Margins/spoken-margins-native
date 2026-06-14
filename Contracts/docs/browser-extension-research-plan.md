# Browser Extension Research Plan

## Purpose

The browser extension is the least proven production surface. It should be investigated before being treated as a firm implementation commitment.

Obsidian Web Clipper is an important reference because it demonstrates useful capture behavior for web pages and YouTube-like media pages. The research goal is not to clone it. The goal is to understand what browser extension capabilities are practical and how they should coordinate with the native Spoken Margins app.

## Questions To Answer

### Text Pages

- Can the extension reliably capture selected text?
- Can it extract readable article text across common sites?
- Can it preserve source URL, title, author, and published date when available?
- Can it package a text item for handoff to the native app?

### Browser Media

- Can it detect playable media on the page?
- Can it observe source media time and playback rate?
- Can it access captions or transcript text when available?
- Can it identify transcript segment timing well enough for portable anchors?
- Can it survive page navigation, tab backgrounding, and media player changes?

### YouTube-Like Pages

- Can it discover transcript/caption content without brittle DOM assumptions?
- Can it preserve timestamped transcript segments?
- Can it anchor interjections to source media time while the video is sped up?
- Can it avoid violating platform rules or user expectations?

### Native App Coordination

- How does a browser session hand off to the native app?
- Does the browser own playback, delegate playback, or only observe page-owned playback?
- How are interjection audio, anchors, and transcript spans transferred?
- What happens if the native app is unavailable?
- What happens if the browser can capture text but not microphone audio?

## Expected Output

The research spike should produce:

- a capability matrix for browser text and browser media modes
- a minimum browser session handoff payload
- failure cases and fallback behavior
- candidate traces to add under `traces/`
- recommendation on whether the browser extension should be in the first production wave or a later phase

## Non-Goals

- Do not make browser local storage the canonical session store.
- Do not depend on wall-clock time for media anchors.
- Do not require browser playback ownership for page-owned videos.
- Do not assume all media sites expose transcripts.
