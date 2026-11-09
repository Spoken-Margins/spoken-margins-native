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
    { "url": "https://example.com/episode" }
  ]
}
```

## Rules

1. `schemaVersion` must be exactly `spoken-margins.link-list.v1`. A different version of this format (`spoken-margins.link-list.v2`, say) is refused with a message that names it.
2. `entries` is required and holds at least one entry whose `url` starts with `https://` and has a host. Entry order is playing order. One link is a list with one entry.
3. `title` is optional on the list and on each entry. It is read but not used yet: each link is named by the page it resolves to, and the list's title waits for the Library folder (#3769).
4. Unknown fields are ignored, so later versions can add them.
5. A link that is not `https`, or an entry with no `url`, is skipped and named; the other entries still arrive. A list with no usable link is refused.
6. A link listed twice in one file is added once, at its first place.
7. One file holds at most 50 entries and is at most 1 MB. A bigger file is refused whole, so a long list never half arrives.
8. A link the app can't resolve is named after the list is read, and the other entries still arrive.

In a picked folder, the app reads every `.json` file it finds (up to 4 levels deep, 200 files) and adds the link lists; it recognizes them by `schemaVersion` alone, so the file can have any name. Other `.json` files in the folder go to the Listening Edition import as before.

## Quick Folder

A link list saved in the Quick Folder shows in the Quick Add list like any other file, and adding it adds its links. The scan offers a `.json` file there only when the file itself says it is a link list (the same `schemaVersion` rule, read off the main thread); a Listening Edition or any other `.json` file never shows. A list the app refuses (a newer version, say) does show, so tapping it names the reason. The scan reads at most 40 `.json` files newest first, each at most 1 MB; a bigger file is read only as far as its first 512 bytes and shows only if it announces the link-list format, so adding it can say why it is refused.

With the Quick Folder feeding the play queue, a new link list is added to the Library the same way, ahead of the text files that arrived with it. Its links are not queued yet.

Not yet: a batch of more than eight new files arriving whole, and a list becoming a Library folder (#3769).
