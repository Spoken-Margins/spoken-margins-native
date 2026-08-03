# Add Article to Spoken Margins Shortcut

Spoken Margins exposes an **Add Article to Spoken Margins** action to Apple Shortcuts. The action imports article text, retains the source URL, opens Spoken Margins, and can start listening immediately.

The action requires extracted article text. Passing only a URL is not sufficient because Spoken Margins' direct link importer is intentionally limited to podcasts, RSS feeds, and public audio files.

## Create the Shortcut

1. In Shortcuts, create a shortcut named **Add Article to Spoken Margins**.
2. Open the shortcut's Details, enable **Show in Share Sheet**, and limit accepted input to **URLs** and **Safari Web Pages**.
3. Add **Get Article using Safari Reader**, using **Shortcut Input** as its URL.
4. Add **Get Details of Articles** once for each of these details:
   - **URL**
   - **Name**
   - **Body**
   - **Author** (optional)
   - **Published Date** (optional)
5. Add Spoken Margins' **Add Article to Spoken Margins** action.
6. Connect the details from step 4 to **Article URL**, **Title**, **Body**, **Author**, and **Published Date**. Leave **Start Listening** enabled.

To support a copied URL when the shortcut is run outside the share sheet, add an **If** block before Safari Reader: when **Shortcut Input** has no value, use **Get Clipboard** as the URL.

## Product-owner validation

Only close issue #38 after the product owner validates the installed build and Shortcut on a physical device.

- Share a public static article from Safari and confirm one library item is created.
- Share a JavaScript-heavy public article and confirm readable text is imported.
- Run the Shortcut with the same article again and confirm it updates the same deterministic item rather than adding a duplicate.
- Confirm **Start Listening** opens playback when no session is active.
- Confirm importing an article does not replace an already-playing session.
- Confirm a non-article URL or an empty Safari Reader result produces a visible Shortcut error.
- Confirm the imported item retains the source URL and article title.

Authenticated or paywalled content is supported only when Safari Reader supplies the visible article body to the Shortcut.
