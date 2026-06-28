# Gate 1 Device Verification

Use this checklist after routine verification passes and closeout UI routes have been run for the build being presented. Record device model, iOS version, build SHA, provider, audio route, and pass/fail notes for each item.

Use the default `SpokenMarginsApp` scheme for Gate 1 device validation. Gate 1 TTS evidence is system speech. The separate `SpokenMarginsAppDevice` scheme preserves Kokoro/MLX work for a later gate and is not required for Gate 1.

## Required Device Pass

- Install a signed iPhone build and a signed iPad build from the same commit.
- Reset local data, seed fixtures, and start the seeded article.
- Confirm the Listening Map overview is spoken before the article body.
- Confirm play/pause, skip back, skip forward, chapter jump, Home, and End Session stop or resume the expected audio target.
- Allow microphone permission, record five source interjections, and confirm `.m4a` files are saved and transcription reaches transcribed or failed-with-audio-preserved.
- Deny microphone permission on a clean install and confirm interjection recording is blocked without corrupting playback state.
- Generate a source interjection summary while item audio is still playing; confirm it waits until item audio completes before playing.
- Play an AI response, interject into it, summarize that interjection, and confirm the summary does not interrupt the active AI response.
- Confirm AI turn rows and AI chapter rows in the primary timeline are tappable.
- Configure a real OpenAI-compatible provider, run Listening Map generation, summary generation, follow-up, provider failure, and retry.
- Enable airplane mode or provider-unreachable mode and confirm pending AI work is recoverable.
- Confirm system speech starts, pauses, resumes, skips, and plays generated summaries/AI responses with the expected target labels and progress.
- Validate Bluetooth/AirPods route and interruption recovery if available in the build being presented.
- Export the session after creating a second session for the same item; confirm no interjections or turns leak across sessions.

## Evidence To Attach

- `./scripts/verify-gate1-routine.sh` terminal log.
- `./scripts/verify-gate1-closeout.sh` terminal log when the build is being presented for gate closeout.
- Device screen recordings for source playback -> summary auto-play and AI response -> AI-targeted summary queuing.
- Screenshot or recording evidence for microphone allowed/denied, saved `.m4a`, Speech transcription result, provider settings, provider success/failure/retry, offline deferred recovery, diagnostics, and export preview.
- Notes for any pass-with-issues result, including exact date, device, route, and reproduction steps.
