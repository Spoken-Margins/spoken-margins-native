# Task-cost map

What the listener's most frequent actions cost in taps (#2396). The data is [task-cost-map.json](task-cost-map.json); `scripts/tests/test_task_cost_map.py` reads it.

## How to read it

- A swipe counts as one tap (owner, 2026-10-21). Typing and speaking cost nothing. Choosing a destination in the iOS share sheet costs one.
- Each route starts from the screen a listener is likely on, and every tap or swipe names the control it uses (an accessibility identifier, or a visible string where the control has none) and the file that holds it.
- `budget` is the most taps the route may take. The test fails when a route's steps add up to more than its budget, and when a named control is no longer in its file. The second failure means the route changed: update the map in the same change, so the new cost is in the diff.
- The counts come from reading the source on 2026-10-25, not from driving the app. A cold start, the first-run microphone primer and a missing permission add taps that are not traced here.

## Where it costs the most

1. **Share a Margin from the playback screen: 6.** More, Export, Share Margins, Review, Share, then a destination. From the Margins tab it is 4. After finishing an item, `playback.finished.share.button` skips the first step.
2. **Mark complete from the playback screen: 2 through the Library, 4 through the Item screen's options menu.** The Library swipe is 1. #2393 is about this.
3. **A written Margin from the mini player: 3.** The mini player has a microphone but no pencil.
4. **Follow a show: 3 to 4.** By name from Library plus is the cheapest. Following has no per-show rows or Follow sheet yet, so the four-tabs check "tap into three shows in a row" does not apply until it does (#1865).
5. **Check whether an item has Margins: 1 to open it.** The Library row shows only other people's shared Margins; #2394 (PR #2644) adds the count.

## Finding your place again

- Library and Following remember their scroll position by row id (`FollowingScrollMemory`), so coming back costs 0 taps and about 0.3 s of scroll. Search text, filters and sort persist in `model.libraryQuery`.
- **Margins has no scroll memory**: the list returns at the top, so a long list costs scrolling after every visit.
- Starting an item leaves the tab bar (`screen = .playback`), and the mini player is hidden there. Going back is one tap on `playback.home.button`.

## Adding an action or route

Add it to the JSON with its steps and a budget equal to its cost, and add the action id to `ACTIONS` in the test if it is one of the named actions. The test does not run the app, so it cannot see a step that is added without being listed; the budget is a review prompt for the people changing a route, not a measurement.
