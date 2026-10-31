# Spoken Margins on the web

A mobile-first, installable web app (PWA): find and follow podcasts, and Substacks that offer the
publisher's or Substack's own voice, play them, and add written and voice Margins. It has no
text-to-speech. Margins travel as `.spokenmargins` files that the iPhone app imports. Tracking issue: see
`git log -- Web/` for the issue each change names.

## Layout and owners

One writer per folder while the first wave runs in parallel.

| Folder | What | Tested by |
| --- | --- | --- |
| `src/shared/` | Types every module shares (`model.ts`) and tiny helpers | `npm run test:web` |
| `src/sources/` | Podcast search, RSS parsing, Substack voice detection, the feed-read path | `npm run test:web` |
| `src/packet/` | `.spokenmargins` read and write, voice recording to `.m4a`, share-link sealing (off) | `npm run test:web` |
| `src/transcribe/` | On-device speech-to-text for voice Margins: the pinned model, the worker, the opt-in rules | `npm run test:web` (rules), `e2e/transcribe.spec.ts` |
| `src/app/` and the Vite project files | The React UI: Four tabs, Library, player, Margin capture | `Web/package.json` scripts |

## Rules

- **Logic is plain TypeScript with no packages.** `npm run test:web` (root) runs every
  `Web/src/**/*.test.ts` with `node --test` on Node 24's type stripping, inside the fast plan
  (`scripts/verify-tests.py`). So use erasable syntax only (no `enum`, `namespace` or parameter
  properties) and write relative imports with `.ts`.
- **The UI has its own `package.json`** (Vite, React, Playwright). Its tests run in the thread that changes
  it and are reported on the PR. They aren't in the merge gate yet: that needs a workflow change, which is
  the owner's tap.
- **Share links are built but off.** Creating one is behind a build-time flag that every hosted build
  leaves off. It turns on in a new build after the DMCA designated agent is registered (owner, 2026-10-20),
  never from a server switch (2026-10-17).
  - `SHARE_LINKS_ENABLED` (`src/packet/share-link.ts`) reads `__SM_SHARE_LINKS__`, which `vite.config.ts` sets
    true only for `--mode share-links-test`, the Playwright build in `dist-share-links/`. `npm run build` leaves
    it false, and the upload code is compiled out (`e2e/share-links.spec.ts` checks both).
  - Opening a link needs no flag: a `/l/<id>#<key>` address, or the same pasted under Margins › Open a link,
    fetches `/l/<id>/packet` from the link's own server and opens it with the key in the `#` part.
  - A host that serves the app at `/l/<id>` adds `<base href="<app root>">`, as the stub server does. A host on
    another origin than the link server needs that server to allow cross-origin reads of `/l/<id>/packet`;
    it doesn't yet.
- **Feeds:** read directly from the browser first. Only when a feed blocks that, ask once and then read
  it through the Spoken Margins server, which keeps nothing. A Substack post page is read only when the
  listener taps that post (owner, 2026-10-21).
- **Packets stay importable by Build 32 and Build 34.** Voice Margins are AAC in `.m4a`.
- **A voice Margin without words shares with placeholder words** (#3025): `Voice Margin at 12:34 in “Title”,
  recorded 30 Oct 2026` (`src/shared/placeholder.ts`), because every iPhone reader back to Build 29 rejects an empty
  transcript. The words box starts with them, muted and tagged "Placeholder"; a transcript or the listener's own words
  replace them. They aren't stored as the Margin's words: the packet writer writes the same ones at export, in the
  existing transcript field, so no packet key changes.

## On-device transcription

After a voice Margin is recorded, its words can be written out on the device and put in the words box for the
listener to check and edit before saving. A voice Margin travels with words, so this is how a spoken Margin gets
text without typing. The packet format is unchanged.

- **Model:** Moonshine Tiny (English, MIT, Useful Sensors), the 8-bit ONNX files from
  `onnx-community/moonshine-tiny-ONNX`, pinned to one commit in `src/transcribe/catalog.ts`. About 32 MB from
  Hugging Face, plus about 27 MB for the engine that runs it (onnxruntime-web's WebAssembly build, served with
  the app). The listener is told "59 MB" before anything downloads.
- **Why Moonshine, not Whisper:** whisper-tiny.en is about 45 MB at the same precision and always works on a
  30-second window, so a 10-second Margin costs as much as a 30-second one. Moonshine works on the recording's
  real length and wrote the test clip out word for word.
- **Opt-in.** Nothing is fetched until the listener says yes, in the composer after their first voice Margin
  or in Settings › Writing out voice Margins. "No thanks" is remembered. Settings can remove the model.
- **Nothing is uploaded.** The recording is decoded in the page and transcribed in a Web Worker. The only
  network use is a GET of each pinned file from Hugging Face (which redirects to its own file CDN).
  `e2e/transcribe.spec.ts` fails if any request carries a body or goes anywhere else; with
  `SM_E2E_LIVE_MODEL=1` it downloads from Hugging Face for real instead of from
  `~/Library/Caches/spoken-margins-web-models/`.
- **Cache.** Transformers.js keeps the model files and the engine in the `sm-transcription-model` Cache Storage
  bucket. The engine is left out of the offline app shell, so a listener who never turns this on never
  downloads it.
- **Speed, measured on an M1 Pro in Chrome:** a 30-second recording took about 1.3 s on WebAssembly and about
  7.5 s on WebGPU with the same 8-bit files (their int8 operators fall back to the CPU). The WebGPU-friendly
  files (32-bit encoder, 4-bit decoder) took about 1.5 s but weigh 75 MB, so the app uses WebAssembly
  everywhere. Loading takes about 2 s once cached. Phones are not measured yet.
- **Transformers.js 4.3.1 workaround.** `pipeline()` and the tokenizer loader ask for files at the `main`
  branch even when given a revision. The worker builds the pipeline from its parts and sets
  `env.remotePathTemplate` to the pinned commit, so every request names it.
- **Install size.** Transformers.js also pulls onnxruntime-node and sharp into `node_modules` for Node use.
  The web build never imports them.

## Android wrapper (#2981)

`android/` is a Capacitor project that serves the same Vite build in an Android WebView. Inside it, feeds,
Substack pages and podcast search are read with Android's own HTTP stack (`src/sources/native-http.ts`), so no
site blocks the read and there is no relay and no consent question. The read path picks that transport itself;
every rule about what is read and when stays in `read.ts` and `search.ts`.

- `npm run android:sync` builds the web app and copies it into `android/`.
- `npm run android:build` also runs Gradle and writes `android/app/build/outputs/apk/debug/app-debug.apk`.
  It needs JDK 21 (`JAVA_HOME`) and an Android SDK whose licences are already accepted (`ANDROID_HOME`, or
  `sdk.dir` in the git-ignored `android/local.properties`). Gradle fetches the missing SDK platform itself.
- **Packets in the app (#3009).** The WebView has no Web Share and ignores a blob download, so "Save or send"
  writes the file to the app's cache (Filesystem plugin) and opens Android's share sheet (Share plugin). A packet
  opened with or shared to the app arrives through the App plugin and is read with Filesystem; the file picker
  shows every file there, because Android reports `.spokenmargins` as `application/octet-stream`. The choice is
  `src/app/logic/native-packets.ts`; the browser keeps its download link and Web Share. Settings' "Back up all
  Margins" takes the same route (`saveFile` in `src/app/download.ts`), and a backup `.zip` opened with the app or
  shared to the installed web app unpacks its packets as a picked one does (`packetsToOpen`).
- **Transcription in the app.** The worker fetches the model with the WebView's own `fetch` (CapacitorHttp stays
  off), which Hugging Face allows from any origin. It needs a WebView with WebAssembly SIMD (Chrome 91 or later)
  and Cache Storage, which current Android System WebView has. Not tried on a device.
- Nothing here is verified on a device until someone installs the APK.
