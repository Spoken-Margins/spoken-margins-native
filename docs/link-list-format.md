# Link list file (`spoken-margins.link-list.v1`)

A listener, or their own assistant, can save one JSON file that lists links. In **+ > Files**, picking the file, or a folder that holds it, makes the app add each podcast episode, article or PDF as if the link had been pasted, in file order. Nothing starts playing.

The app knows a link list only by its `schemaVersion`. A `.txt`, `.md` or `.markdown` file is never read as one, even if it holds nothing but a URL. JSON with any other `schemaVersion` (a Listening Edition, for one) goes the way it always did. Code: `LinkListFile` in SessionKit (#3767).

## Example an assistant can copy

```json
{
  "schemaVersion": "spoken-margins.link-list.v1",
  "title": "Morning brief, November 8",
  "entries": [
    { "url": "https://example.com/article", "title": "Optional display title" },
    { "url": "https://example.com/episode" },
    { "url": "https://example.com/show.xml", "follow": true }
  ]
}
```

## Rules

1. `schemaVersion` must be exactly `spoken-margins.link-list.v1`. A different version of this format (`spoken-margins.link-list.v2`, say) is refused with a message that names it.
2. `entries` is required and holds at least one entry whose `url` starts with `https://` and has a host. Entry order is playing order. One link is a list with one entry.
3. `title` is optional on the list and on each entry. On the list, a title makes a list picked in Files become a Library collection with that name (#3769); the Quick Folder still adds the links as loose items. On an entry it is read but not used: each link is named by the page it resolves to.
4. Unknown fields are ignored, so later versions can add them.
5. A link that is not `https`, or an entry with no `url`, is skipped and named; the other entries still arrive. A list with no usable link is refused.
6. A link listed twice in one file is added once, at its first place. That includes an entry and a `"follow": true` entry with the same link: the first one wins.
7. One file holds at most 50 entries and is at most 1 MB. A bigger file is refused whole, so a long list never half arrives.
8. A link the app can't resolve is named after the list is read, and the other entries still arrive.
9. An entry with `"follow": true` is a show the assistant suggests the listener follow, not an item to add (#4683). Only the JSON value `true` counts: `"true"`, `1`, `false` and a missing field mean an ordinary entry. A list whose only usable entries are follows is accepted. More than 10 usable follow entries (after skipping the ones that aren't `https`) refuses the whole list: "This list suggests more than 10 shows to follow. Ask for 10 or fewer."

In a picked folder, the app reads every `.json` file it finds (up to 4 levels deep, 200 files) and adds the link lists; it recognizes them by `schemaVersion` alone, so the file can have any name. Other `.json` files in the folder go to the Listening Edition import as before.

A build that doesn't know `follow` ignores it and adds the link as if pasted. A link list is not a packet, so that is acceptable.

## Pasted text

A listener can paste the whole reply from their own assistant, which is prose around one JSON block (`LinkListText` in SessionKit, #4683). The app reads pasted text as a link list only when it holds the marker `spoken-margins.link-list.` (case-sensitive). Text without the marker is never a list and is never refused.

1. The block can be bare, in a ```` ```json ```` fence or in a bare fence, with prose before and after, CRLF line endings or a byte order mark.
2. The app tries each `{ ... }` object that holds the marker, outermost and earliest first, up to 16 of them. The first link list wins; a later object, even one that is refused, never beats it. Another format's object before the list is skipped.
3. With no list, the first refusal is shown (a newer version, too many links or follows, no usable link). If an object holds the marker but isn't valid JSON, or the reply is cut off inside the object (the marker is in a JSON string and the object never closes): "Your AI's reply has a link list that couldn't be read. Ask it for the JSON block again."
4. The marker in prose only, with no object around it, is not a list.
5. The same limits apply as to a file: at most 50 entries, and a reply over 1 MB (1,000,000 UTF-8 bytes) that holds the marker is refused with the size message. Without the marker it is not a list.

## Quick Folder

A link list saved in the Quick Folder shows in the Quick Add list like any other file, and adding it adds its links. The scan offers a `.json` file there only when the file itself says it is a link list (the same `schemaVersion` rule, read off the main thread); a Listening Edition or any other `.json` file never shows. A list the app refuses (a newer version, say) does show, so tapping it names the reason. The scan reads at most 40 `.json` files newest first, each at most 1 MB; a bigger file is read only as far as its first 512 bytes and shows only if it announces the link-list format, so adding it can say why it is refused.

With the Quick Folder feeding the play queue, a new link list is added to the Library the same way, ahead of the text files that arrived with it. Its links are not queued yet.

Not yet: a batch of more than eight new files arriving whole, and a list becoming a Library folder (#3769).
