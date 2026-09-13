# Personal knowledge workflows

Implementation on `codex/provisional-next`, September 12, 2026. These changes are not in the distributed Build 27. Only the product owner can accept the flows after using them.

## Share sheet → chosen model → listening edition

Create a Shortcut and enable Show in Share Sheet for Safari web pages/URLs:

1. Use Safari Reader’s Get Article action on Shortcut Input. Get the article’s Body as plain text and keep that value as **Original Article Text**. Also retain Name and URL. Review extraction when the page has a paywall or unusual formatting.
2. Run Spoken Margins **Make Listening Map Prompt** with Original Article Text.
3. Send that prompt to the model action you choose. This can be an available Apple Use Model action or a ChatGPT action configured by you. Model availability, account access and execution behavior belong to that action. Spoken Margins sends no model request.
4. Run **Assemble Listening Edition**. Title = article Name; Source URL = article URL; Original Article Text = the unchanged saved value; Model or Author = your label; Map JSON = the model response.
5. Optionally Save File to keep the resulting JSON. Run **Import Listening Edition** with that file to open the app and import it. Import does not start playback.

This is an editable recipe, not a signed downloadable `.shortcut`. The app supplies the three native actions. Their discovery, model action binding and share-sheet execution require a device check. You can also assemble the JSON yourself and use Sources → Import Listening Edition to choose a file or paste it, Preview, then Import Item and Map.

The JSON contract is `Contracts/schemas/listening-edition.schema.json`; a small playable example is `Contracts/fixtures/listening-editions/article.json`. A document contains exact source text, title, optional source URL, generator label, overview, and scenes. Each scene has a title, description, summary and inclusive 1-based startBlock/endBlock. Blocks are separated by literal blank lines (`\n\n`). Scenes must cover all blocks in order without gaps or overlap. Import rejects invalid versions, URLs, bounds and oversized files. The maximum source is 5 MB, document 8 MB, and scene count 200. Import does not verify the model’s factual accuracy.

Retrying the same source retains its item and existing sessions. A changed map for that exact source requires the explicit replacement toggle in the preview. Changed source text becomes a separate item. Descriptions and summaries remain visible on the item. Go to Scene uses the source’s character anchors. Skim uses supplied summaries only after complete prepared audio provides usable distinct scene boundaries; it does not invent timestamps. Map-only import is not included.

**Ready notification:** enable notifications on the Listening Edition screen. A notification is requested when complete source audio and scene timing are available. Tap it to open the item. Short startup prewarming is not full preparation; use the app’s existing full preparation policy for longer items. iOS permission, scheduling and app lifetime govern delivery. Continuous app-background article analysis and native map generation have not been established by this implementation. The external Shortcut workflow does not depend on either.

## Margins → Obsidian or another folder

In Settings → Margin Output, choose a folder inside your Obsidian vault using Files, then Send Test Note. Enable Automatically Save Margins. Existing and new active text Margins are exported as individual Markdown files, including source/session identity, position and bounded source context. Recordings and full source text are excluded. Recorded Margins need a transcript before delivery.

Delivery checks while the app is active (about every 15 seconds), pauses during recording, and retries when the app becomes active. Retry Delivery runs a check immediately. It is not an always-running background sync service. Canonical Library data survives a failed folder write. Disabled delivery leaves existing files in place. File providers may upload the folder according to their own settings.

Files have stable Margin identifiers to avoid duplicate retries. Changed app transcripts update files only while the previous contents are still app-owned. Outside edits are preserved and reported. Reselect a new output folder for fresh copies. Deleting a Margin in the app does not delete its exported note. Moving a folder or revoking provider access can require reselecting the folder.

Any notes app that reads Markdown from a writable Files folder can use the same output, including a suitable Logseq folder. This does not implement proprietary APIs, bidirectional synchronization or managed-vault integration.

## Read Later → Library

Sources or Settings → Read Later. Choose a service, follow Get an access token, paste the token and Connect. Refresh, Load More, and explicitly Add individual articles. Tokens are stored in this device’s Keychain. Disconnect removes the saved token and leaves imported items intact. The adapter does not archive items, change progress, or write Margins back to the reading service.

- **Readwise Reader:** use your account token. Lists Later articles, emails and RSS entries; imports available HTML or falls back to the original URL. PDFs, books and highlights are outside this adapter. A Reader account/trial is required.
- **Raindrop.io:** use a free account, create a personal integration in account settings and obtain its test token. Lists bookmarks across collections with pagination. Imports readable article text from the original website. Paywalls, login-only pages, deleted articles and unsupported sites may fail visibly. Paid permanent copies are not used. This is personal-token setup, not a production OAuth onboarding flow.

No live account import is claimed as verified. Test one item with each account, a repeated import, pagination and disconnect. Reader success does not establish Raindrop behavior or vice versa.

Primary API references: [Reader](https://readwise.io/reader_api), [Raindrop personal token](https://developer.raindrop.io/v1/authentication/token), [Raindrop listing](https://developer.raindrop.io/v1/raindrops/multiple), [Instapaper current content-access requirements](https://old.instapaper.com/developers/v1/full-api). Raindrop replaces the earlier Instapaper candidate because Instapaper app approval and current content-access dependencies prevent assuming a clean free-account path.
