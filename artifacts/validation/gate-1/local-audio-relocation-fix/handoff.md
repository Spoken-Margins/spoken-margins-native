# Local audio container relocation correction

The owner confirmed **“its working”** on 2026-09-09. Source Play on the existing Introduction item is **human_validated** for this development update. This does not extend acceptance to professor timing, full-session completion, or other flows.

## Diagnosis and implementation

The phone's persisted source URL referenced its former data container, AE87308B…, while the existing Xcode debugger returned the running home directory as 789559FB…. Device file listing showed the exact Introduction MP3 still present in current Audiobooks storage. The first correction addressed asset ID versus file URL but did not address container relocation.

The app now resolves local audiobooks from the owned-storage relative path under current Application Support, with a relocated-file fallback for the saved URL. Start, saved-session restoration, and runtime reconstruction prepare that transport before playback. Package verification hashes the resolved current file as well. Missing source files produce an error instead of entering a silent media start. No audiobook, package, voice, or original content was replaced.

The real-player integration test now moves the source file, retains its stale Item URL, reconstructs the app, and resumes the saved session from current owned storage. Before this correction, playback stayed at 5,000 ms. The corrected test passes, including initial playback, pause/resume, Skim return, reconstruction, and rejection of modified source bytes. Both result records are retained here.

## Physical-device evidence

The signed build installed in place without a Library reset. It launched on the phone. The app's existing compact-control Play and Pause commands advanced the same Introduction session from 0 to 61,706 ms at the user's 1.75× rate; device-evidence.json records the observations. The owner then confirmed it works. Playback was paused after the bounded check; press Play to continue.

## Build and scope

Development build 0.1 (26), codex/provisional-next, base fdbceda0dd840a541653ac6fe84957ffd6bec704 plus working-tree changes. This is distinct from TestFlight 26. iOS 18+ supports iPhone and iPad; device evidence uses the paired iPhone 17 Pro, simulator regression uses iOS 26.5. No TestFlight upload or external distribution. Existing unrelated review artifacts and earlier session implementation remain preserved.

In scope: existing source playback across app-container relocation and current-file package verification. Out of scope: new voice generation, package regeneration, UI redesign, cross-edition matching, and distribution. The seeded sample remains the existing Introduction MP3 plus .spokenmargins package with Chatterbox professor/Skim clips. No reset or re-import is necessary. Device install, launch, play, pause, and build logs are in this directory. The app's Developer diagnostic export remains available if another issue occurs.

Owner checklist: Source Play — PASS (“its working”). Professor playback balance/timing — not newly assessed. Full-session completion — not assessed. Skim return on phone — not newly assessed.

## Verification status

Focused relocation regression, fast, app, adapters, and speech-canary all passed. The first full app run's console output interleaved a network log inside one test's pass line; Xcode reported 393 successful tests but the inventory parser saw 392. That run remains failed in the evidence, and the fresh run passed. No test or assertion was disabled.

All final plans share input fingerprint `cc653a8e374e11386fc2850006bb4592185d0edafaddd85beac31ddc4ecea777`.

- fast: verified — [fast manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-092813-043324-fast/manifest.json)
- app: verified — [app manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-093118-412758-app/manifest.json)
- adapters: verified — [adapters manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-093240-664240-adapters/manifest.json)
- speech-canary: verified — [speech-canary manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-093303-041519-speech-canary/manifest.json)
