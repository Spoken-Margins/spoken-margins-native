# App Store Connect copy — External TestFlight 0.1

Never commit the reviewer API key. Replace the bracketed key placeholder directly in Beta App Review Notes immediately before submission.

## Beta description

Spoken Margins is a local-first reading and listening workspace. Import text, PDFs, web articles, and public podcast links; listen with native playback; capture spoken interjections; optionally generate Listening Maps, summaries, and follow-ups; and export the resulting session.

## What to Test

Please test text/PDF and public-podcast intake, continuous playback, chapter navigation, spoken interjections, optional AI summaries/follow-ups, export, the Share extension, and Safari capture. Podcast episodes stream immediately and download automatically on Wi-Fi for offline listening. Settings offers a 1/2/5/10/20 GB podcast cache with a 5 GB default.

## Beta App Review Notes

Spoken Margins has no account or sign-in requirement. A fresh install includes “Welcome to Spoken Margins,” which demonstrates import-independent listening, navigation, interjection, and export.

AI is optional and uses a reviewer-specific, monitored, revocable OpenAI API key. In Settings, paste this key into the API Key field and save it:

`[PASTE DEDICATED REVIEWER KEY IN APP STORE CONNECT ONLY — NEVER COMMIT IT]`

At the first live AI action, the app describes which text is sent and requires explicit consent. To verify AI, import a text/PDF, generate a Listening Map, record an interjection and generate its summary, then submit a follow-up. To remove access, use Settings → Delete API Key. The key can also be revoked by the developer without shipping a new build.

The Share extension accepts an explicitly shared web page/URL, selected text, podcast/audio URL, PDF, Markdown, or plain-text file. The Safari extension reads the current page only after the reviewer invokes its action.

## Metadata checklist

- [ ] Public Support URL: `https://spokenmargins.proximitytoprogress.com/support/`
- [ ] Public Privacy Policy URL: `https://spokenmargins.proximitytoprogress.com/privacy/`
- [ ] App Privacy answers match the binary and privacy manifests.
- [ ] No tracking; no advertising or analytics collection is claimed.
- [ ] Export compliance: no non-exempt encryption (`ITSAppUsesNonExemptEncryption = false`).
- [ ] Age rating and content-rights answers complete.
- [ ] Feedback email and review contact complete.
- [ ] Sign-in marked not required.
- [ ] Dedicated reviewer key created, scoped/monitored, tested from a fresh install, and pasted only into Review Notes.
