# Design brief: navigation and structure

Written 2026-10-16. You propose **structure**: which screens exist, what sits on each, and how a listener moves between them. Screens are drawn later, after the owner picks a proposal.

## The jobs, and what they cost today

Spoken Margins plays articles, PDFs and podcasts, and lets a listener leave spoken or written Margins on them. It has three tabs: Library, Following and Margins. Tap counts come from `Design/flow-map/flow-map.json`, starting on Library; a menu item counts as two.

Over the three-tap ceiling:

1. Import an OPML file: 6 taps, through Following, then Manage feeds.
2. Export all Margins: 6.
3. Follow a podcast from a link: 5.
4. Unfollow a show: 5.
5. Share one Margin with a friend: 5.
6. Free up storage: 5.
7. Change the reading voice: 4, through a menu on the Library tab.

Within target: hear a Margin's moment (3), write a Margin while listening (2), open the Timeline (2), add an article from the clipboard (2), get help (2), see item details (1), see new episodes (1).

Two jobs are cheap to reach but fail anyway:

- **Finding your newest Margin** is one tap, but the Margins tab groups by item and lists each item's Margins in source order, so the newest one is often not on top.
- **Item details** has no published date and no date added at all.

## The owner's problems, in his words

1. He can't find Margins he added recently.
2. He can't see when items were added or published.
3. He wants to see his items by cluster.
4. A source with "three items a day that he plays once a week" fills up Following and the Library. Don't stop people adding it. Make it easy to reach when wanted and invisible when not.
5. He likes Now Playing, but the controls are "far too bulky". Now and Timeline will show images, links, tables, figures and embeds, so space matters.
6. Settings is a junk drawer. Feed management lives under Following → Manage instead of Settings. App configuration belongs in Settings, and long lists collapse: show two deleted items, then expand. He calls this easy.

## An open question: the library

Don't treat the library as "the main problem". He corrected that framing. His own idea is a challenge, not a spec: a **suggestion screen** beside a **one-dimensional library you can sort**, with clusters and tags built from internet metadata (publisher, date, topic). Answer the challenge underneath it: what to play next, and finding a thing again. You may propose something else if it serves those better.

## Fixed rules

1. Two taps is the target for an everyday job, and three is the ceiling.
2. Progressive disclosure: one job per screen, and feed management never on a landing screen.
3. Blue and orange carry status, never red and green. Colour never carries meaning alone; add a label, an icon or position.
4. Every touch target is at least 44 points.
5. Liquid Glass only on controls, never on content.
6. Reuse what exists before adding a control. Tapping a Timeline row, or the "Play this moment" card, should carry a job before a new button does.
7. Name things in the listener's words, not the code's.

## Rejected before

`Design/tried.md` keeps the full list. In short:

1. Two rounds of whole-app directions in September (Four Rooms, The Deck, Notebook; then Player, Today, Notebook): "very cluttered, no clear direction for a user", then "none clicked".
2. Five Home screens with shelves and glanceable icons: "they all look quite poor".
3. Placing a shared Margin by ear with extra buttons: too much for a rare case.
4. Ten reference apps, Overcast to Libby: all unimpressive, because none solves the problems above.

What failed each time was redrawing screens without fixing the paths through them. Now Playing is the one redesign he accepted, so leave it until last.

## What to hand back

1. Two or three proposals, each a set of flow-map edits: screens added, removed or merged, and arrows changed.
2. For each, every job's new tap count and which of his six problems it solves.
3. One sentence on what you would watch for to show the proposal is wrong.
4. No pixels, colours or type. Fewer screens beats more, so before you hand a proposal over, take one thing out.

Save proposals in the flow-map viewer's sandbox, https://claude.ai/artifact/AvZu69RrQXwjzezaJWrxJG, so he can try them. Add anything he rejects to `Design/tried.md`.
