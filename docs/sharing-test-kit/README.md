# Sharing test kit

One set of prepared `.spokenmargins` packets and one procedure for the owner's phone (about twenty minutes, ten on the short path it names), so the sharing failure modes get checked together instead of as "repeat what you did" plan steps (#848).

| File | What it is |
| --- | --- |
| [`procedure.md`](procedure.md) | What the owner follows on the phone. Each step says what he should see or hear. It goes out with the phone plan. |
| [`kit.json`](kit.json) | The one description of the kit: three public items, four packets, every Margin. |
| `packets/` | The four built packets and `SHA256SUMS`. Present once the Mac has built and staged them. |
| [`../../scripts/sharing_kit.py`](../../scripts/sharing_kit.py) | Builds, checks and re-verifies the kit. Tests: `scripts/tests/test_sharing_kit.py`. |

## What it covers

| Packet | Item | Failure mode |
| --- | --- | --- |
| `kit-1-episode-a` | Episode A, which the owner adds first | Import onto an item he already has; importing the same packet twice leaves no duplicates (J5 step 5). |
| `kit-2-episode-b` | Episode B, which he never adds himself | A packet whose source isn't in his Library; a different episode of the same show whose first 6 seconds match A (#456). |
| `kit-3-wrong-cut` | Episode A's identity, fingerprints made on B | A packet that says it is on his episode but was placed against another cut. No Margin may show a time with "Audio verified" or "Combined evidence" (#456). |
| `kit-4-article` | A web article he adds only after importing | A packet whose article isn't in his Library: no item is made and the Margins wait, then he adds the article and opens the packet again to attach them. Margins are tied to the words they quote. |

Step 1 of the procedure shares Margins from an episode that is streaming (#536). On Wi-Fi the app downloads a new episode at once, so the step has him turn Wi-Fi off first. Step 7 shares again from the same episode once it is downloaded and holds imported Margins, which is the "sending Margins back out" case. Importing a podcast packet whose episode he lacks (kit-2) downloads that episode on its own, so that one is never a streaming test.

Nothing in the procedure deletes the app, resets anything or touches his Library beyond adding three items. The optional last step moves only those three to Recently Deleted, which keeps them. `scripts/sharing_kit.py lint` fails if the procedure ever says otherwise.

## The content

All of it is public, with no sign-in, and licensed for this use.

- **Episode A:** HPR4737, "Keep spare parts for Ethernet run", Hacker Public Radio, hosted by Archer72, CC BY-SA 4.0. 8:08.
- **Episode B:** HPR4736, "How to replace the battery in a car key fob", Hacker Public Radio, hosted by Ken Fallon, CC BY-SA 4.0. 5:14.
- **Article:** "Declaration of Independence: A Transcription", National Archives. A founding document, so public domain.

Why these:

- Hacker Public Radio serves each episode as a plain MP3 with no dynamic ads, so the file on the phone is the file the fingerprints were made from. The recent HPR episodes checked open with the same 6.0 seconds of sound. `verify-content` measures that from the audio and fails if it changes.
- The links in `kit.json` carry no token or key, so the exporter's own link policy would keep them (`is_shareable_link` mirrors `ShareableLinkPolicy`).
- Both are short, so the downloads are small.
- The quotes are sentences that appear exactly once on the page.

The packets hold computer voices and fingerprints (ShazamKit signatures) of the episode audio, not the audio itself. The episodes keep their authors' CC BY-SA 4.0 license, and the attribution above ships with the kit.

## Building the packets (Mac)

`coop-packet` speaks the voices with `say` and signs the audio with ShazamKit, so this part needs a Mac with the voices Samantha, Daniel, Karen and Moira (`say -v ?`).

```bash
python3 scripts/sharing_kit.py build      # fetch the pinned audio, write the four packets, check them
python3 scripts/sharing_kit.py stage      # copy them, with SHA256SUMS, into docs/sharing-test-kit/packets/
```

`build` works in `artifacts/sharing-kit/` (git-ignored). It stops when:

- the audio on the public server is no longer the file `kit.json` pins by hash;
- `coop-packet check` fails. That check reads every packet with the current reader and with the Build 29 reader, merges them in every order and imports each twice (see the `CoopPacket` README);
- a built packet disagrees with `kit.json` in `lint-packets`, which needs no Swift: the manifest keys against the ones Build 29's reader accepts (it refuses any other), every file against its hash, the sender, the item, the Margins in order, the voice and the fingerprints of each Margin, and a `requiredCapabilities` list Build 29 can read. `Contracts/schemas/spoken-margins-package.schema.json` is not used here: it still describes an older manifest (`source`, `sourceAudioOmitted`) that no build writes.

`python3 scripts/sharing_kit.py plans` writes only the `coop-packet` plans, for reading or for running `coop-packet build` by hand.

## Keeping it honest

- `lint` checks `kit.json` and `procedure.md` against each other: every packet file, sender, Margin count and spoken line must appear in the procedure. Every label the procedure puts in bold must be text the app has (it reads the string literals under `App/SpokenMarginsApp/Sources` and `Packages/SessionKit/Sources`), so a renamed button fails here, not on his phone. The wording of the old import sheet (`SpokenMarginsPackageImportView`, which no screen presents) is refused outright. It also holds the packet limits and the wrong-cut rule (most of the packet's fingerprints must come from outside the shared intro, because SessionKit places nothing when half or fewer of a packet's fingerprints match).
- `verify-content` needs the network, `ffprobe` for duration checks and `ffmpeg` for the shared intro. A missing audio tool fails the check instead of skipping it. It re-downloads the audio and checks its hash, length, license, host and shared intro, that the host still answers HEAD with the file's size and accepts byte ranges (the app sizes a download that way before it starts one), and that each quote appears once on the page. Run it before rebuilding, and when a step of the procedure fails for no clear reason.
- `scripts/tests/test_sharing_kit.py` also reads the field names in `PacketBuilder.swift` and `SharingModels.swift`, so a plan can't drift from what `coop-packet` decodes.
- When a staged packet or the procedure changes, change `kit.json` first and rebuild. Don't edit packets by hand.

## What it doesn't prove

The Mac build proves the packets are well formed and that Build 29 can open them. It does not prove where the app places each Margin, or what the recipient screens say. The owner's pass on the phone does that. The procedure's "You should see" lines are written from the code that presents them (`Build23RecipientSharingExperience.swift`, `Build23ImportedMarginPresentation.swift`, `SharedMarginPlacement.swift`, `Gate1AppModel.swift`) and the podcast anchor plan; where a result depends on the matching pass, the procedure asks him to write down what he saw instead of naming one label.

Not covered: the #536 failures that need a very long episode or an `http` link (host tests cover those; he passed #536 on his own phone on 2026-10-07), a packet with exactly one Margin inside a shared intro (SessionKit places it; see the podcast anchor plan), and reply threads.

Known behaviors the procedure is written around:

- Importing a packet for an article that is not in the Library creates no item and fetches nothing. The Margins show in the Margins tab under its **Shared** chip (the tab opens on **Mine**) until he adds the article and opens the packet again.
- An item added from a bare audio link is named after the file ("hpr4737").
- **Listen** on a Margin plays its voice only. The chime and the pause come from playing the episode past a placed Margin.
- The item page shows **Download Again** once an episode is downloaded. It never shows "Available offline".
- The app saves fingerprints of a playing episode only after about 70 seconds (`SparseFingerprintSchedule`), so a share from an episode played for less has no fingerprint spine to check, and #536 passes vacuously. Step 1 plays two minutes and scrubs once.
- Wi-Fi back on starts a download for every episode that is waiting or streaming only, not just A.
