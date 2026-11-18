# OPML import fixtures (B1 M2)

Subscription exports in the shape each app writes, with feeds from the onboarding catalog. They are reconstructed from each app's export format, not files exported by the owner. Real exports from the owner's apps would replace or join these (an owner item on #187).

- `overcast.opml`: Overcast's extended export. Each feed outline holds its episodes as `type="podcast-episode"` children, which must not be read as feeds.
- `pocket-casts.opml`: Pocket Casts. Flat list inside a `feeds` outline.
- `castro.opml`: Castro. Flat list directly in the body, OPML 1.1.
- `antennapod.opml`: AntennaPod. OPML 2.0 with `dateCreated`.
- `edge-cases.opml`: folders, lowercase `xmlurl`, an http feed, a private feed, a feed repeated with a trailing slash, escaped `&amp;`, an outline with no feed URL and one with a non-web URL.

List fixtures (#4046, PR 4):

- `lists-folders.opml`: nested folders (`Tech` holding `AI`) and a show in none, the shape other apps write for groups.
- `lists-categories.opml`: OPML 2.0 `category` with leading slashes, `/Tech/AI` as one name, a `podcast:guid`, and `sm:skip` and `sm:more` word lists.
- `lists-includes.opml`: `type="include"` rows (one unusable) and a show written with `sm:via`.
- `lists-edges.opml`: blank and repeated categories, leading slashes only, NFC and NFD of one name, XML-escaped names, a blank GUID, an empty category.
