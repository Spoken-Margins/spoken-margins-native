# Structure proposals

Written 2026-10-16 against the flow map at commit `32173207`. Each proposal is a set of edits to `../flow-map/flow-map.json`: screens added, renamed, moved or removed, arrows added (`"proposed": true`) or removed, and every job recomputed. No pixels, colours or type. Now Playing and the Timeline are untouched in all four.

## Tap through them

`concepts.html` is a page with five phone prototypes, today's app and the four proposals, that you can tap through: tabs switch, a show opens, the plus opens the Add sheet, a Margin row plays. It is published as an artifact for the owner; open the file in a browser to see the same thing.

## The four

1. **[Stream](stream.md)**: New · Library · Margins. The first tab's axis changes from "what you follow" to "what arrived", with noisy shows folded to one row. Shows get a screen; Manage feeds dissolves into the Add sheet.
2. **[Up next](up-next.md)**: Up next · Library · Margins. The owner's own idea, answered as a challenge: a bounded shortlist beside a sortable library. Feed management gets one home under Settings.
3. **[Four tabs](four-tabs.md)**: Library · Shows · Margins · Settings. A show is a place you go. Nothing arrives, so nothing floods. Settings is a tab.
4. **[Same tabs](same-tabs.md)**: the control. Today's tabs with only the paths fixed. It shows how much the structural proposals buy beyond path fixes.

## What the numbers say

Taps per job, counted the way the brief counts them (a menu item is 2, the picker's own taps are in the job's final cost).

| Job | Built | Same tabs | Stream | Up next | Four tabs |
| --- | --- | --- | --- | --- | --- |
| Import an OPML file | 6 | 5 | 4 | 5 | 4 |
| Follow a podcast from a link | 5 | 4 | 3 | 3 | 3 |
| Unfollow a show | 5 | 4 | 3 | 3 | 3 |
| Share one Margin with a friend | 5 | 3 | 3 | 3 | 3 |
| Free up storage | 5 | 3 | 3 | 3 | 3 |
| Export all Margins | 6 | 2 | 2 | 2 | 2 |
| Change the reading voice | 4 | 3 | 3 | 3 | 3 |
| Hear a Margin's moment | 3 | 2 | 2 | 2 | 2 |
| Everything else | 1 or 2 | same | same | same | same |

Three things to read off it:

1. **Most of the gain is path fixes, not structure.** The control gets every everyday job to the ceiling or under it except the two that run through Manage feeds, following and unfollowing a show. The shared fixes are listed at the top of each JSON file; they belong in any proposal the owner picks. None of them puts feed management on a landing screen: Quiet and Unfollow live on the Show screen in the three structural proposals.
2. **The structural proposals beat the control on exactly the Manage feeds jobs**, and differ from each other only on importing an OPML list, which happens once.
3. **So the choice between Stream, Up next and Four tabs is not a tap-count choice.** It is about guessability, screen count and the noisy show, which is what the rest of this file is about.

## Could a newcomer guess where things live?

Six questions a new listener asks, and the answer in each proposal. "Named" means the tab or row says it; "learned" means they find it once and remember.

| Question | Stream | Up next | Four tabs |
| --- | --- | --- | --- |
| Where are my podcasts? | learned: Library, sort by Shows, or a name in New | learned: Settings, Shows you follow | named: Shows tab |
| What's new? | named: New | named: Up next | learned: counts on the Shows tab |
| Where are my notes? | named: Margins | named: Margins | named: Margins |
| How do I follow a show? | learned: + then Paste or Browse | learned: + then Paste, or Settings | named: Shows tab + |
| How do I change the voice? | learned: gear | learned: gear | named: Settings tab |
| Where did that episode go? | New, then the Library once played | Up next, then the Library once played | its show, then the Library once played |

Four tabs names four of six, and the two it does not name are the same two nobody names. Stream names two and asks the newcomer to learn that shows live inside the Library. Up next names two and hides shows under Settings, which is right for someone who thinks "subscriptions are a setting" and wrong for everyone else.

## The noisy show, in each

- **Stream:** folded to one row per day; Quiet, set on the show's screen, removes it from the stream. It still has a tab it can fill.
- **Up next:** one card at most; Quiet, set on the show's screen, removes the card. It cannot fill anything.
- **Four tabs:** one row with a count; Quiet, set on the show's screen, sinks it to a collapsed group. It cannot fill anything.

## Screens

| | Built | Same tabs | Stream | Up next | Four tabs |
| --- | --- | --- | --- | --- | --- |
| Screens in the map | 48 | 48 | 48 | 49 | 48 |
| Removed | | | Manage feeds | | Following |
| Added | | | Show | Show | Show |

None of them is smaller than today. The Show screen is new in all three structural proposals because a show has no place of its own in the app at all; the Library's options menu is the thing taken out in every one.

## The pick

**Four tabs**, for guessability: four of six newcomer questions are answered by a word on the tab bar, against two for the others, and the noisy show is contained by design rather than by folding. Its cost is a fourth tab and the loss of a single "what's new today" list. **What would show the pick is wrong:** the owner opens Shows and taps into three shows in a row to collect the day's episodes. Then he listens by day, and Stream is the right structure; Up next stays the fallback if he wants the app to choose for him.

## Running the numbers

```bash
python3 Design/proposals/compute-taps.py Design/proposals/four-tabs.json --check
python3 Design/proposals/compute-taps.py Design/proposals/four-tabs.json --markdown
```

`--write` stores each job's counts and route in the proposal file. The base map's counts match the brief for all sixteen jobs. A job may name `via` screens and `via_edges` (arrow ids the route must use); on equal cost the route prints through proposed arrows.

## The viewer's sandbox

The flow-map viewer's sandbox stores arrow adds and removes between screens that already exist. It cannot show an added screen, so the three structural proposals' Show screen does not fit there. The sandbox copies carry only the arrows between existing screens and say so in their names.
