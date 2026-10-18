# Stream: New, Library, Margins

**The idea.** Keep three tabs but change the first one's axis from "what you follow" to "what arrived". The Following tab becomes **New**: one chronological stream of everything that reached the app since you last looked, with a noisy show folded to a single row ("The Daily · 3 new") that expands in place and can be set to Quiet so it stays followed but leaves the stream. A show gets its own screen, reached from its name in New or from the Library's Shows sort, and that screen is where Follow, Unfollow and Quiet live. Manage feeds goes away: New's toolbar gets a **Follow** button that opens its own sheet, Follow a show or a friend, with Paste (a copied show link is followed at once, with Undo), Browse shows and writers, and Import from another app. The Library's plus means only "add a source". Settings gets a gear on every tab and six sections with the long lists collapsed. Margins stay grouped by item, with Share beside each item's heading; groups are ordered by their newest Margin, which carries a Newest label.

## Taps

| Job | As built | Proposed | Route |
| --- | --- | --- | --- |
| Import an OPML file | 6 | 5 | New tab > Follow (person.badge.plus, toolbar) > Import from another app tile (the file picker opens at once) |
| Follow a podcast from a link | 5 | 3 | New tab > Follow (person.badge.plus, toolbar) |
| Unfollow a show | 5 | 3 | New tab > Show name on a folded row |
| Find the Margin you added most recently | 1 | 1 | Margins tab |
| Hear a Margin's moment | 3 | 2 | Margins tab > Margin row (plays this moment) |
| Share one Margin with a friend | 5 | 3 | Margins tab > chevron on a Margin row (details) > Share this Margin (square.and.arrow.up) |
| See an item's details | 1 | 1 | Library row (title area) |
| Add an article from the clipboard | 2 | 2 | Add (plus) |
| Write a Margin while listening | 2 | 2 | Mini player (Open Now Playing) > square.and.pencil 'Write a Margin' |
| Open the Timeline for what's playing | 2 | 2 | Mini player (Open Now Playing) > Timeline (pane switch) |
| Change the reading voice | 4 | 3 | gearshape, Settings (toolbar) |
| Free up storage | 5 | 3 | gearshape, Settings (toolbar) |
| Export all Margins | 6 | 2 | Margins tab > Export all Margins (toolbar) |
| Get help | 2 | 2 | gearshape, Settings (toolbar) > "How Spoken Margins Works" (questionmark.circle) |
| See new episodes from a show you follow | 1 | 1 | New tab |
| Open a Margin packet a friend sent | 2 | 2 | open a .spokenmargins packet file (Files, Mail, AirDrop, Messages) |
| Share all of an item's Margins | 3 | 3 | Margins tab > Share (square.and.arrow.up), 'Share Margins from <item>' > Share N (square.and.arrow.up) |

Still over the ceiling: importing an OPML file (5), a once-per-listener job. It was 4 when the import tile sat on the Library's Add sheet.

## Problems it solves

1. Newest Margin: the first group on the Margins tab, labelled Newest.
2. Dates: the Item screen's header, and the Library's Added and Published sorts.
3. Clusters: the Library's sort control (Added, Published, Publisher, Topic, Shows).
4. The noisy show: one folded row in New, or none at all once it is Quiet; its episodes join the Library only when played.
5. Now Playing: untouched.
6. Settings: six sections, feed management out of it and out of the landing tabs, help and import rows inside it.

## What it makes worse

- "Following" stops being a word in the app. A newcomer looking for "my podcasts" has to find the Shows sort in the Library, or tap a show's name in New.
- New mixes several kinds of thing (episodes, items you added, shared Margins, and later friends and clubs). If the rare rows are rare they will read as noise.
- Unfollowing a show that has nothing new costs 4 (Library, sort by Shows, the show, Unfollow).
- Follow is a toolbar button on New, which a newcomer has to notice; the Library's plus no longer helps them follow anything.

**The one thing taken out:** the Library's options menu (Settings, Help, Preparing Audio). Settings is a gear, Help lives in Settings, and Preparing Audio keeps only its card.

**What would show it is wrong:** he opens New, sees a day's worth of folded rows, and still goes looking for one particular show; that means he thinks per show, not per day, and Four tabs fits better.

## How it grows

New is a stream of what arrived, so a friend's activity and a club's activity are rows in it, dated like everything else.

- **A friend's story** is a row in the stream when they leave Margins: "Sam left 2 Margins on Tides", under Today. Tapping it opens a Friend screen: what they are listening to now, and their Margins newest first, each playable at its moment in your copy. Several Margins in a day fold to one row, as a noisy show does.
- **A book club** is a row when the club moves on or its thread grows: "Salt Club · chapter 4 this week · 3 new in the thread". It opens a Club screen with the current item, a play button and the thread.
- Follow a friend or join a club from the same Follow sheet, by pasting their invite link.
- The cost is the one already listed under "What it makes worse": New carries four kinds of row, and the fold is what keeps it readable. A friend or club with nothing new is only reachable through the Library's Shows sort, which would need to become "Following" to hold them.

## The screens that change most

```
 New                     Follow+  ⚙ |   Library                 ⇅ Added  + ⚙ |   Show: The Daily          Quiet ○
 ─────────────────────────────────── |   ──────────────────────────────────── |   ───────────────────────────────────
 Today                               |   Added today                          |   Following since March   [Unfollow]
 ▸ The Daily · 3 new            ›    |   ▶ How whales sleep      Hakai  12m   |
 ▶ Why cities hum   Nautilus  18m    |   ▶ The Daily: Oct 16     17m          |   Oct 16  ▶ The Daily: Oct 16    17m
 ✎ Sam left 2 Margins on Tides  ›    |   Added this week                      |   Oct 15  ▶ The Daily: Oct 15    22m
 ◉ Salt Club · ch. 4 · 3 new    ›    |   ▶ Tides (PDF)           ch. 3 of 9   |   Oct 14  ▶ The Daily: Oct 14    19m
 Yesterday                           |   ▶ Why cities hum        Nautilus     |   Oct 13  ▶ The Daily: Oct 13    21m
 ▸ Hard Fork · 1 new            ›    |   …                                    |   …
 ─────────────────────────────────── |   ──────────────────────────────────── |   ───────────────────────────────────
 ▶ Tides · 12:40 ────────── ● 🎙     |   ▶ Tides · 12:40 ────────── ● 🎙      |   ▶ Tides · 12:40 ────────── ● 🎙
 [ New ]  [ Library ]  [ Margins ]   |   [ New ]  [ Library ]  [ Margins ]    |
```

The ▸ rows are folded shows; tapping the row expands it in place, tapping the show's name opens the Show screen. The ✎ and ◉ rows are the friend and club rows the stream grows into; they are not in the flow map yet. The Library's ⇅ control is one in-place sort (Added, Published, Publisher, Topic, Shows).
