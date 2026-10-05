# Flow designs (4 October 2026)

Six flows, each redesigned in one pass: where the flow is today, three directions, the recommended design, what it needs technically, the owner's decisions and the slices to build it. They are designs, not specs of shipped behaviour. Nothing here was built or tried on a phone when it was written; the slice issues track what has been since.

| Doc | Recommended design | Mockup |
|---|---|---|
| [Following and discovery](following-and-discovery.md) | "Today's picks": a short daily list with an end | none |
| [Hands-free Margins](hands-free-margins.md) | Press, talk, keep going | none |
| [Getting back to notes](getting-back-to-notes.md) | "Listen Back": your Margins as a short episode | [phone mockups](https://claude.ai/artifact/JQzUk9YTKjqUVMkPyJd9Jt) |
| [Offline trip prep](offline-trip-prep.md) | "Pack": one button readies a trip's listening | none |
| [First run](first-run.md) | "A Margin is waiting" | none |
| [Sharing with a friend](sharing-with-a-friend.md) | Share a moment; friends reply by voice | [clickable mockup](https://claude.ai/artifact/E6LrL8jUiETYVyr4Uj58qP) |

The mockups and the owner's review of these designs ([review](https://claude.ai/artifact/LwPCHsuUZDrvbXCwV4KAkv)) are private claude.ai pages. The docs are the spec; the pages only illustrate them.

## Reading the slices

- Each doc ends with a "Decisions for you" (or "Decisions for Cole") section. Those are the owner's. A slice that depends on one is filed `needs-owner` until he answers, and the answer goes on the issue. Slices that decide none of them are filed `ready`.
- Play this moment, a friend's cut and Listen Back all play "a lead-in, then the Margin". One SessionKit type owns all of their lead-ins (#807), so the playback slices in the sharing and Listen Back designs wait for it. Each of those docs says which slices.
- File paths and line numbers cite `next` on 4 October 2026 and drift as code moves. Check the code before relying on one.
