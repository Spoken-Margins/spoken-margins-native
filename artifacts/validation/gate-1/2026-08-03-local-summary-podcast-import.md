# Local Summary And Podcast Import Device Feedback

- Date: 2026-08-03
- Reporter: product owner
- Branch under evaluation: `codex/mvp-local-foundation-models`
- Device build number and commit SHA: not supplied with the report
- State: product-owner evidence recorded; affected flows are not `human_validated`

## Observed results

1. An on-device interjection summary completed and was broadly acceptable, but retained spoken fillers such as “um” and “ah.” Expected behavior is a concise, lightly polished, intent-faithful rewrite.
2. The Apple Podcasts episode `https://podcasts.apple.com/us/podcast/1891-we-need-memes/id269169796?i=1000779583526` imported without a Listening Map.
3. The publisher episode page `https://www.noagendashow.net/listen/1891` did not import.

## Diagnosis

- Summary anchors were present in the local-model payload, but the prompt did not clearly separate listener speech to rewrite from source excerpts used only to resolve references.
- The live No Agenda RSS feed uses the Podcasting 2.0 project's legacy GitHub namespace URI. The parser accepted only the current namespace URI, so both `<podcast:chapters>` and `<podcast:transcript>` were skipped.
- The generic resolver did not recognize structured episode metadata embedded in publisher HTML pages.

## Remediation awaiting product-owner revalidation

- The local summary contract now explicitly removes filler, stutters, repetition, false starts, and transcription noise while preserving viewpoint, uncertainty, questions, qualifications, preferences, and requested actions.
- Anchors are explicitly source-only context and must not be summarized or attributed to the listener.
- RSS ingestion accepts the current and observed legacy Podcasting 2.0 namespace URIs.
- Structured publisher episode pages can supply audio, duration, transcript, and chapter URLs.

## Automated evidence

- `LocalFoundationModelsTests`: 4 passed, 0 failed.
- `SourceLinkImportTests`: 40 passed, 0 failed.
- Combined focused run: 44 passed, 0 failed.
- Regression fixtures use the exact reported Apple and publisher-page URL shapes.

Only the product owner can advance these flows to `human_validated` after installing a build containing the remediation.

## Follow-up: on-device Listening Map generation

The product owner subsequently tested podcast Listening Map generation on device and reported:

- generation latency was unacceptable for the MVP;
- generation failed with the displayed error “Medi data outside timeline” (reported verbatim).

This satisfies the feasibility study's stopping rule. The MVP decision is now:

- keep on-device Foundation Models for eligible interjection summaries;
- keep publisher chapters for podcasts;
- keep deterministic maps for native text;
- keep mapless podcast playback when publisher chapters are unavailable;
- disable on-device AI Listening Map generation and full-podcast transcription initiated for that purpose;
- reserve AI-generated Listening Maps for a future server-hosted path behind the remote-provider feature flag.

The failure is retained as product-owner evidence, but the retired generation flow is not `human_validated` and will not be repaired for the MVP.

## Consolidated product-owner pass

The product owner subsequently ran the optimized Recovery MVP device procedure and reported:

- podcast intake, cross-provider resolution, and publisher chapters: pass;
- playback completion behavior from issue #45 and native-audio speed persistence from issue #47: pass under the then-documented expectations;
- local summary: fail;
- generated-turn Lock Screen, Control Center, route, and Live Activity synchronization: pass, with a corrected completion expectation described below;
- deterministic/publisher/mapless Listening Maps and transcript-disclosure boundary: pass;
- Supertonic and the remaining daily-driver flow: pass.

The report did not include the installed build number, commit SHA, device, OS, or diagnostics path. As with earlier direct product-owner reports, it is valid evidence for the bounded flows actually accepted but is not evidence for a different build.

### Summary failure evidence

The exported handoff for “Post by @AlexiGlad on X” showed a five-bullet summary. Four bullets reproduced source-anchor material and the fifth copied the listener transcript, including “uh” and “um,” nearly verbatim. This falsifies both required properties: anchors remained source-only context, and the listener note was cleaned and condensed. The local-summary portion of issue #42 remains not `human_validated`.

The follow-up implementation now:

- removes common fillers and adjacent repeated words before model invocation without changing the stored transcript;
- bounds `anchorBefore` to its nearest trailing 240 characters and `anchorAfter` to its nearest leading 240 characters;
- uses Foundation Models guided structured generation for listener-intent bullets;
- rejects residual fillers, excess bullet count/length, and any seven-word contiguous anchor copy instead of saving an unsafe result.

### Corrected final-audio behavior

Although generated-turn external controls synchronized correctly, the product owner clarified that completion of the final audio must automatically close the session rather than leave a completed player open. Issue #43 therefore remains only partially human-validated, and issue #45 is held open until this broader completion behavior is revalidated.

The follow-up implementation distinguishes true 100% completion from external pause, drains any queued generated turn first, automatically detaches the session after the final turn, ends its Live Activity, returns to Home, and persists the session as `finished` even when normalized text offsets round to 99%.

## Second bounded revalidation

The product owner retested only the two failed flows:

- automatic final-audio session closure: pass and `human_validated`;
- podcast interjection summary: failed with the reported message “failed likely unsafe.”

The failure indicates that rejecting unsafe or anchor-contaminated output works, but the successful summary path is still not reliable enough. The summary portion of issue #42 remains open.

The next bounded implementation changes the model topology from one batch rewrite to one guided structured rewrite per interjection. Each rewrite first receives the cleaned note and bounded anchors. If Apple rejects that request or the output validator rejects its result, the app retries that interjection with the cleaned listener note alone. Cancellation remains cancellation rather than triggering a retry. This retains anchor-assisted reference resolution when safe while preventing source context from making the entire summary unavailable.

## Third bounded report: BBC podcast anchors unavailable

- Remediation build: 11
- Branch: `codex/mvp-local-foundation-models`
- Base commit at verification: `b4bd7f2` plus the documented working-tree changes

The product owner retested with the Apple Podcasts episode “1816, the Year Without a Summer” and reported:

- the interjection summary completed rather than returning “likely unsafe”;
- no before/after anchors were generated for an interjection at media time 11:35;
- the app displayed an App Transport Security failure while retrieving the podcast download;
- the publisher enclosure URL was `http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-nondrm-download-rss/proto/http/vpid/p0kbxb7s.mp3`.

The missing anchors are a downstream effect of the failed audio download: the app had no local media file from which to transcribe the bounded source windows. This report therefore does not validate context-assisted summary quality.

The remediation keeps App Transport Security enabled. Podcast download transport upgrades HTTP enclosures to HTTPS without changing the item’s publisher URL provenance. BBC Media Selector URLs additionally change their embedded `/proto/http/` redirect instruction to `/proto/https/`; otherwise the HTTPS entry point redirects back to HTTP. Redirects encountered during download are also upgraded instead of allowing an insecure request. Existing failed imports can exercise the remediation through the visible Retry action; reimport is not required.

This remediation is `verified` pending product-owner revalidation. The relevant falsification checks are: no ATS exception is added, HTTPS publisher URLs remain byte-for-byte unchanged, query/fragment identity survives an HTTP upgrade, the exact reported BBC URL resolves through an HTTPS-only redirect chain, and Retry migrates an already-failed record without reimport.

Verification evidence:

- `PodcastDownloadCoordinatorTests`: 6 passed, 0 failed, including the focused Retry-without-reimport regression.
- Contract validation and surface-contract validation: passed.
- `swift build --build-tests --package-path Packages/SessionKit`: passed.
- unsigned generic iOS device build for `SpokenMarginsApp`: passed.
- live HTTPS-only request for the exact transformed BBC URL: final status 200 with `audio/mpeg` after an HTTPS-only redirect chain.
- repository scan: no ATS arbitrary-load or exception-domain setting is present.

## Product-owner revalidation: BBC anchor recovery

The product owner subsequently tested Build 11 and accepted the remediation. The following bounded flow is now `human_validated`:

- an existing BBC podcast import whose HTTP enclosure had previously failed under App Transport Security can recover without reimport;
- the secure podcast download succeeds through the HTTPS-only transport path;
- the app can generate the missing before/after anchors after local audio becomes available.

This validation does not close the separate interjection-summary quality work. Context-assisted summary concision, grammar, intent preservation, and resistance to anchor copying remain subject to their own product-owner validation.
