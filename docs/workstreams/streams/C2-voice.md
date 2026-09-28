# C2 · voice: narration that never quietly gets worse

**Outcome.** Narration keeps the voice the listener chose unless there's a real reason to change it. When the app must fall back (heat, low battery, memory), it falls back to a bundled voice that sounds natural rather than robotic, needs no setup, and still renders at least twice as fast as real time on the oldest supported iPhone under thermal and battery stress. The listener can see why it changed, and the chosen voice comes back when the condition clears.

**Why now.** On the owner's iPhone 17 Pro, charging or Low Power Mode drops narration to the system voice. That fallback also pauses at every chunk boundary and multiplies the accessibility speech rate by the app's rate (#183). Piper can be imported but isn't linked, and is too painful to set up.

**Where.** Voice research and benchmarks in the cloud and on the Mac host. Integration on the Mac. Device checks by the owner.

**Seams.** Owns **I14** (speech engine selection).

## Starting points

- The fallback is deliberate policy, not a crash. `SupertonicResourcePolicy.allowsRendering()` (in `SupertonicSpeechPlaybackClient.swift`) refuses to render under Low Power Mode, thermal `.serious` or `.critical`, or within 60 s of a memory warning. The app then calls `activateSystemFallback` to the iOS voice. Thermal state is polled at decision points; nothing observes its change notification.
- Supertonic 3 INT8 runs on ONNX Runtime, CPU only, 8 steps, 240-character chunks, with a disk cache and a 15 s render-wait limit. The render duration is recorded but no real-time factor is computed anywhere.
- Piper: an import UI for `.onnx` + `.json` exists, but the renderer is "not linked in this build".
- **License trap:** many lightweight neural TTS stacks phonemize with espeak-ng, which is GPL. Voice models carry their own licenses too, some non-commercial. Whatever ships must suit App Store distribution.
- The oldest iPhones iOS 26 supports use the A13 chip (iPhone 11 and SE 2nd generation). The owner doesn't have one, so the budget must be derived: measure on the owner's phone in Low Power Mode while warm, and scale by a documented CPU ratio.

## Milestones

**M1: Fix the fallback we have** (target: Build 30).
- Done when #183's acceptance criteria hold:
  - Power state alone doesn't silently switch voices. Where policy requires a fallback, the reason is visible and logged.
  - The chosen voice returns when the condition clears.
  - Chunk boundaries don't flip play/pause or the Now Playing state.
  - Rate is one number and isn't multiplied by the accessibility rate.
- Host and app tests cover Low Power Mode and charging as separate transitions, with non-1.0 rates. Lane T3 is green.
- I14 is published, including how each I13 role (heading, caption, footnote, citation, reference) is spoken, so C1 can build on it.
- (owner) The owner confirms on the phone.

**M2: Pick a fallback voice** (research).
- Done when a comparison on the tracking issue covers at least 4 candidate engines or voices: license, app size, time to first audio, and real-time factor on a Mac (Mac).
  - It includes audio samples of the same three passages (including a scientific paragraph) for each candidate, plus Samantha and Supertonic, labeled blind for the owner.
  - It includes a small benchmark build the owner can run on the phone.
  - It ends with a recommendation that meets: ≥2× real time on the derived A13 budget, a license compatible with the App Store, and a stated app-size cost.
  - (owner) The owner does the blind listen, runs the phone benchmark in Low Power Mode, and accepts the app-size cost.

**M3: Ship it.**
- Done when:
  - The chosen voice is bundled and needs zero configuration.
  - It's the automatic fallback, with Supertonic still preferred when allowed.
  - A benchmark command reports real-time factor per engine.
  - In app tests, a 30-minute article plays through a forced fallback without a pause longer than 1 s.
  - (owner) The owner's phone meets the derived budget in Low Power Mode while warm.

**M4 (optional): Faster Supertonic.**
- Done when an experiment on the tracking issue reports real-time factor and blind-labeled samples for at least two efficiency changes (for example fewer steps, a smaller model, a GPU or Neural Engine path).
  - (owner) Any adopted change keeps the owner's blind-listen preference.

## Must not break

The Supertonic Terms gate. Voice identity recorded for prepared audio (#64). Background preparation while charging.

## Out of scope

Voice cloning. Personal Voice. Non-English voices (note what they would cost).

## Related

#34, #64, #73, #74, #83, #111, #183.
