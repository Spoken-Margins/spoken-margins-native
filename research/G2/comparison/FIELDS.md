# Comparison fields

Each app is one JSON file in `apps/<id>.json`. `scripts/build.py` merges them into `../comparison.json`; `scripts/validate.py` rejects any claim without a source.

## App record

```json
{
  "id": "snipd",
  "name": "Snipd",
  "vendor": "Snipd AG",
  "category": "podcast",            // podcast | read-aloud | read-it-later | notes | ai-research | social-listening
  "website": "https://www.snipd.com",
  "why_listed": "One sentence: which segment would use it instead of Spoken Margins.",
  "claims": { "<field>": Claim, ... }
}
```

## Claim

Every claim has a value and at least one source. A claim with no public source says `"value": "unknown"` and explains in `note`; it still needs `checked` and the URL where it was looked for.

```json
{
  "value": "yes",                   // yes | partial | no | unknown, or a string/number for text fields
  "detail": "Short plain-English description of what the product does.",
  "sources": [
    { "url": "https://…", "title": "Page title", "published": "2026-05-01 or null", "checked": "2026-09-28",
      "quote": "Short verbatim excerpt (≤ 30 words) that supports the value." }
  ],
  "note": "Optional caveat, e.g. only on paid tier, only in US, only on web."
}
```

`checked` is the date the page was read. `published` is the page's own date when it shows one.

## Fields

Capability fields take `yes | partial | no | unknown`.

| Field | Question it answers |
| --- | --- |
| `platforms` | (text) Which platforms: iOS, iPadOS, Android, macOS, web, Windows |
| `price_free_tier` | (text) What the free tier includes |
| `price_paid` | (text) Cheapest paid plan, with currency and period, e.g. "USD 9.99/month or 84.99/year" |
| `plays_podcasts` | Can it subscribe to and play podcast feeds? |
| `reads_web_articles_aloud` | Can it read saved web articles aloud with TTS? |
| `reads_pdfs_aloud` | Can it read PDFs aloud? |
| `voice_notes_anchored` | Can the listener record a spoken note tied to a point in the audio/text? |
| `text_notes_anchored` | Can the listener type a note tied to a point in the audio/text? |
| `hands_free_capture` | Can the listener capture a moment without looking (headphone gesture, Watch, lock screen, CarPlay)? |
| `transcripts` | Does it show a transcript of podcast audio? |
| `ai_summaries` | Does it generate AI summaries or chapters? |
| `export_markdown_pkm` | Can notes/highlights go to Obsidian, Notion, Readwise, Logseq or plain Markdown? |
| `share_note_at_moment` | Can a listener share a note or clip that another person opens at that moment in the source? |
| `group_listening` | Does it support groups, book clubs or shared annotations among several people? |
| `on_device_privacy` | Does it state that notes/processing stay on the device, or that it has no account requirement? |
| `account_required` | Is an account required to use it? (`yes` means an account is required) |
