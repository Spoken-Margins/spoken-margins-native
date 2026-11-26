# When an ingest fix meets saved items

A fix to how we read a PDF, a Substack post, another article or a podcast changes what the next import produces. It does not change what a listener already has. This page is the checklist for that gap, so the next ingest bug starts from it instead of rediscovering it.

It describes how the app behaves today and what to check. It does not propose rebuilding anyone's Library, and the reasons are below.

## The default: no automatic rebuild

A saved item is more than its text. Margins anchor to positions in that text. Re-ingesting an item changes the text, so Margins can land on other words or lose their place. A bulk rebuild after an update would risk that for every item at once, and updates are infrequent enough that a rebuild is rarely worth it.

So the default for a fix that changes ingest is:

1. New imports get the fix.
2. Saved items stay as they are.
3. If an old item matters, the listener chooses to refresh that one item, and its Margins stay safe.

## What the app already does

- **A changed re-import becomes an edition.** `BrowserTextImporter` keeps the saved item and its Margins when the same article or PDF comes in again with different text. The new text becomes a separate item whose id ends in `-edition-` and a SHA-256 of the text.
- **A PDF can move in place, but only when it is safe.** When a newer extraction of a saved PDF puts every Margin and position on the same words, `StructuredUpgradeJob` moves the existing item to it. Otherwise the new text becomes an edition. This is the one in-place upgrade we have, and it is the pattern to copy: plan the change, check every Margin lands on the same words, and apply it only then.
- **Followed feeds keep their own copy of each post's text.** `FollowedSourceCoordinator` rewrites that copy each time a feed is read. A feed is read again only when it is more than six hours old (`refreshStale`, `minimumAge`). Adding a post from Following builds the import from the saved copy, not from a fresh read.

## Three places a bad ingest can sit

For any ingest fix, say which of these it covers and which it leaves alone.

1. **Items already in the Library.** A fix never touches these. Re-adding the post creates an edition and leaves the original.
2. **Stored Following entries.** An entry saved by an older build keeps its old text until its feed is next due, which can be hours after the update.
3. **Anything cached from the old extractor**, such as a stored page or a derived map.

A fix that only covers fresh imports is a real fix. It must still say that it is one, in the PR description.

## Worked example: Substack headings (#4461, #4468)

A followed Substack post imported from its feed had no chapters, so its Timeline had no scenes. The feed's HTML body was being flattened to one line, which removed the headings the importer builds chapters from. #4468 keeps the headings.

What the fix was shown to do:

- A fresh import from the feed, with and without the publisher's generated voice, gives one chapter per heading. A host test covers it.
- Reading the same post from its page by hand gave the same chapters. No repository test covers that.

What it was not shown to do, and why that matters here:

- It was not tried on a Following entry saved before the fix.
- It was not tried on an item already in the Library.

After the fix shipped, a followed Substack post that has headings was added again from the Following tab and still showed no chapters on a maintainer's phone. The leading explanation is the stale stored entry above, but that is unconfirmed. Tracing the code and a host test with the real feed both produce chapters for a fresh read, so the open question is what the saved entry held at the time of the add. Settle that before treating the explanation as the cause.

Later the same day, a headed Substack post added through the share sheet on the same build came in with chapters and the publisher's voice. That confirms the fix for a fresh read of the page. It does not test the Following path, because a share-sheet add reads the page at that moment and never uses the saved Following copy. The Following case stays untested: add a headed post from Following after its feed has refreshed, and see whether chapters appear.

## Before merging an ingest fix

1. Name which of the three places above the fix covers.
2. Test the saved-item case, not only a fresh import: start from a stored entry or a Library item made the old way, and check what the listener sees.
3. If a saved item can improve, prefer a per-item refresh the listener asks for. Reuse the same-words check from the PDF upgrade. Never rewrite text under existing Margins.
4. If saved items cannot improve, say so in the PR and the release notes so nobody is told it is fixed everywhere.
5. Do not report the fix as verified from a fresh import alone. Draw the screen a listener sees from an item made the old way.

## Not decided

These would make the next case cheaper. None is built, and none is needed until an ingest bug actually strands saved items.

- Stamp each imported item with the extractor version that made it, so we can tell which items an update would improve.
- A per-item "refresh from source" action that applies only when the same-words check passes.
- Re-reading a followed feed when the listener adds one of its posts, so the text is current at that moment.
