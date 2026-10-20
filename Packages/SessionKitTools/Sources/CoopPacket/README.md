# coop-packet

A Mac tool for co-op test packets (#856). Synthetic listeners (written by Claude or Codex) answer real packets, or start threads for a person to answer, so the whole co-op loop can be tested without recruiting people. Packets are written by the same SessionKit code the app uses.

```bash
swift build --package-path Packages/SessionKitTools --scratch-path Packages/SessionKit/.build/tools --product coop-packet
```

The binary lands in `Packages/SessionKit/.build/tools/debug/coop-packet`. The tool has its own package, which depends on `Packages/SessionKit` by path, so a project using SessionKit doesn't resolve it (#1873). It builds inside SessionKit's `.build`, which worktrees link to a cache that disk relief clears, as `scripts/sharing_kit.py` does. Keep packets, plans and episode audio under `artifacts/` (git-ignored): exported packets hold the owner's voice.

## Commands

- `inspect <packet>...` prints each packet as JSON: item, sender, digest, and every Margin's time, anchor, text, voice length and reply links. Read this before writing replies.
- `build <plan.json> [--out <dir>]` writes a packet from a plan, then runs `check` on it.
- `map <edition.json> [--type text|pdf|epub] [--url <link> | --no-url] [--sender <label>] [--name <file>] [--out <dir>]` writes a map-only packet (#1471): a skim-ready Listening Map for an article or a PDF, with chapter titles and summaries and no Margins, from a Listening Edition. Each chapter is placed by its first seven words, so the packet holds none of the text. `--type pdf --no-url` makes the packet a PDF the listener supplies from their own copy; otherwise the link is the edition's source link. It then runs `check`.
- `check <packet>...` runs four checks:
  - every packet imports in the current reader and in the Build 29 reader, with the same Margins;
  - packets on the same item import into fresh SQLite Libraries in every order (all orders up to five packets, then 120 shuffles), and every order gives the same packets, Margins and reply threads;
  - opening any packet again adds nothing;
  - a sender who shared again (the same Margin in two packets, #858) leaves the listener one copy of it: a copy kept for a Margin no packet carries twice fails the check, and a note says how many Margins were re-sent.

  A map-only packet is checked differently: the current reader must read it, and Build 29 must refuse it with its usual "unsupported capability" message (the packet declares `spoken-margins.listening-map-packet.v1` as required and carries an empty commentary layer so that older readers get as far as that check).

  It exits 2 on a failure.

## Plan format

Paths are relative to the plan file.

```json
{
  "sender": "Ada (synthetic)",
  "voice": "Samantha",
  "fileName": "A1-ada-jensen",
  "base": "../owner/Jensen.spokenmargins",
  "margins": [
    { "id": "ada-1", "replyTo": { "margin": "margin-0003" }, "text": "..." },
    { "id": "ada-2", "replyTo": { "packet": "../out/B1.spokenmargins", "margin": "b-1" }, "offsetMs": 4000, "text": "..." },
    { "id": "ada-3", "atMs": 4200000, "spoken": false, "text": "..." }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `sender` | Shown to the listener. Keep "synthetic" in it so a test packet is never mistaken for a person. |
| `voice` | A macOS voice for `say` (`say -v '?'` lists them). Each Margin can set its own `voice`. |
| `base` | The packet being answered. The item, fingerprint spine and acoustic evidence come from it. |
| `item` | The item (a `SharedItemIdentity`), when there's no base: a thread the synthetic listener starts. |
| `episodeAudio` | A downloaded copy of the episode. Each Margin placed by time gets ShazamKit evidence made from it, as the sender's phone would, so it lands right on a copy with different ads. |
| `embeddedText` | Article text to embed instead of a link. The item must be a text, pdf, epub or other item with no `canonicalURL`; its two hashes are set from the text. |
| `margins[].replyTo` | The parent: `margin` is its package-scoped id, and `packet` defaults to `base`. A reply to a reply joins its parent's conversation. |
| `margins[].atMs`, `offsetMs` | Where it sits. Without `atMs`, a reply sits at its parent's place and carries the parent's evidence. Any offset drops that evidence, so the Margin is placed by time only. |
| `margins[].quote` | For an article: the words it's anchored to. |
| `margins[].anchor` | A full `PortableAnchorEvidence`, used as is, for adversarial packets. |
| `margins[].spoken` | `false` sends text only. Spoken is the default. |

## What it doesn't cover

- The Margins it writes are what Claude or Codex wrote; they say what was heard only as well as the transcript used to write them.
- It builds no fingerprint spine for a thread it starts, only per-Margin evidence.
- `check` imports as an outside listener who holds every packet. The sender's own Library, where their Margins are local rather than imported, is the app's job (#473).
