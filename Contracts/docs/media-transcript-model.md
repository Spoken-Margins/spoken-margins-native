# Media, Transcript, And Audio Model

## Purpose

This document defines how Spoken Margins should model text items, generated audio, podcasts, videos, browser media, and offline watch packages with one shared playback model.

The key rule is:

Text-backed items use a transcript timeline. Native-audio items can play and preserve durable media-time anchors without a full transcript. Spoken Margins derives only bounded transcript excerpts around interjections in the default MVP. Full native-audio transcription for AI-generated Listening Maps is reserved for a future server-hosted feature and must remain internal derived data rather than becoming visible through a transcript view, search, clipboard, share sheet, export, portable package, or diagnostics.

The active runtime capability profile decides which audio representation can be used right now. A phone/tablet online profile may generate maps and summaries; a phone/tablet offline profile may still play prepared media, synthesize local TTS when permitted, record interjections, and defer AI jobs; a browser media profile may observe page-owned playback without owning the audio; an untethered watch profile only plays prepared audio or native media already available on watch.

## Core Model

An item has content and may have native audio.

When present, a transcript is the richest navigable timeline:

- For text items, the transcript is generated from the text.
- For pre-rendered TTS, the transcript is the source text aligned to generated audio.
- For real-time TTS, the transcript is still the source text; timing may be estimated or produced lazily.
- For podcasts or videos, bounded excerpts are generated around interjections. The default MVP does not create a full generated transcript for Listening Map generation.
- For browser media, the transcript may come from the page, platform metadata, captions, or generated transcription.

Audio source types:

- `generated_tts_realtime`: audio is synthesized during playback.
- `generated_tts_prerendered`: audio file exists before playback.
- `native_media_file`: user or app has the audio/video file.
- `browser_owned_media`: browser page owns playback.
- `remote_stream`: audio is streamed by a provider or media URL.

## Transcript Timeline

Transcript segments should support:

- segment id
- text
- start/end character offsets when text-backed
- start/end media time when audio/video-backed
- optional speaker
- optional confidence
- source type

Interjections should prefer this anchor order:

1. transcript segment/span
2. media timestamp
3. surrounding text
4. local playback segment as fallback only

## Text Item Flow

For a pasted article or note:

1. Store item text.
2. Derive transcript segments from paragraphs/sentences.
3. Generate Listening Map from text/transcript.
4. Either synthesize TTS in real time or pre-render audio.
5. Align generated audio with transcript segments when possible.

Real-time TTS is memory efficient and quick to start, but may use more battery and depends on the playback device.

Pre-rendered TTS is better for offline watch use, battery predictability, and consistent chapter timing, but requires preparation time and storage.

Phone/tablet text playback supports both real-time local TTS and pre-rendered audio when available. The Recovery MVP does not queue map, summary, or discussion work for a remote provider. Apple Foundation Models is used only for eligible interjection summaries. Deterministic native-text maps, publisher podcast chapters, mapless playback, interjections, export, and pasted-response import remain available without the local model.

Production TTS segmentation should optimize for low latency, natural continuity, reliable interruption, and stable anchors. It should not copy the prototype's fixed chunk sizes as a product requirement.

When playback is generated just in time, the speech engine should avoid exposing synthesis boundaries to the user as awkward pauses whenever the platform allows it. When playback is pre-rendered, alignment metadata should preserve enough transcript timing to support chapters, interjections, rollback, and exports.

## Podcast Or Video Flow

For native media:

1. Store or reference the media asset and begin playback without transcription.
2. Import publisher chapter timing in this precedence: Podcasting 2.0 chapter JSON, inline Podlove Simple Chapters, embedded media chapters, then timestamped episode-description chapters. Podcasts without publisher chapters remain mapless in the default MVP; a future server-generated map must never replace a publisher map.
3. Persist publisher timestamps as media chapters even when no transcript exists, so chapter navigation does not require transcription.
4. Anchor ordinary playback and mapless interjections to source media time.
5. When an interjection is saved, derive only its bounded before/after source excerpt when no stored timeline is available.
6. When the user explicitly requests a Listening Map and no valid publisher map exists, prefer an existing publisher transcript and otherwise generate a full transcript.
7. Keep any full native-audio transcript as internal derived data for the map and later excerpt resolution; do not expose, search, copy, share, or export it as source text or transcript.
8. Use the media's native audio for playback throughout transcription and map generation.

The permitted user-visible native-audio derivative is deliberately narrow: source attribution, map overview, chapter titles and descriptions, timestamps/resolved positions, and bounded context immediately before and after a saved interjection. The user's own interjection representations remain separately exportable.

The media may be sped up or slowed down. Anchors always use source media time, not wall-clock listening time.

## Browser Flow

For browser text:

- capture selected/readable text
- create a text item or browser session package
- use app-owned, browser-owned, or delegated TTS depending on active capability profile
- capture interjections in-browser only when recording permission and the browser text profile allow it

For browser media:

- capture media URL/page URL
- capture transcript/captions when available
- observe source media time and playback rate
- anchor interjections to source media time and transcript segment
- hand off session events to the app unless a future browser-only profile owns canonical persistence

## Offline Watch Flow

The watch should receive a prepared package containing:

- item metadata
- session metadata
- pre-rendered audio files or podcast audio references available on watch
- transcript timeline
- Listening Map and resolved chapter timings
- rollback/navigation settings

The watch should not need to transcribe, summarize, generate maps, or call AI while offline.

It records:

- interjection audio
- source playback position
- chapter id when available
- transcript segment/span when available
- playback rate
- command/event log

The phone/iPad reconciles, transcribes, cleans up, summarizes, and continues discussion after reconnect.
