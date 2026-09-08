# Product-owner device feedback — September 8, 2026

Owner confirms running the updated checkout from Xcode. Device inventory reports a developer-installed 0.1 (25), with a changed bundle container relative to September 7. The exact compiled source/input hash is not established by this inventory.

| Observation | State | Boundary |
| --- | --- | --- |
| Loading/importing native text while another text item plays retains smooth animation | human_validated | Animation smoothness only; uninterrupted audio and play/pause state were not explicitly reconfirmed. |
| Opening the lowest Library item during native-text playback causes prolonged sluggishness | failed | Owner reports responsiveness returned after pressing the mini-player X. This is a useful intervention, not proof of CPU contention or a specific renderer failure. |
| Native-text opening audio stays at zero chunks for more than five minutes, including while idle | failed | Exact spinner location remains unconfirmed. Item-details code replaces the Play action with a noninteractive preparing indicator; queue starvation and preparation-state accuracy need investigation. |
| Scrubber dislocation | failed | Owner reports recurrence after the previous fix. Prepared versus live mode was not specified in this follow-up. The earlier callback-order regression is insufficient evidence of physical correctness. |

The September 7 fixes must not be described as resolving these failed device flows. Preserve previous accepted observations separately. Do not require the owner to repeat the original validation matrix or wait another five minutes merely to reconfirm a stall. A diagnostics export captured during the stalled/dislocated state is the next useful device evidence; current prepared-job state, playback snapshot, and renderer reason must be distinguished from generic performance assumptions.

## Diagnostic export at 2026-09-08T12:29:57Z

- Library bootstrap reports 115 items; playback is paused, target `item_text_tts`, voice James / Supertonic M2.
- Generation reports `ready`, `23/23`. The export lacks a generation item ID, so this cannot establish which Library item owns those chunks.
- “Why You Won’t Get a Flying Car” reports `ready_2_of_143`: its bounded opening preparation completed.
- “Something Is Shifting in the Inflation Picture” reports `preparing_0_of_2` and `started_without_waiting_for_opening_buffer`.
- `backgroundAudioPreparation=complete` and `automaticAudioPreparationQueue=queued` are last-written diagnostic values, not an atomic current queue snapshot.

Code inspection shows `preparing_0_of_2` is assigned at enqueue and only replaced on horizon completion; it can remain stale after partial preparation or a switch to live playback. It is not proof of a current zero-chunk manifest. The item-details spinner separately derives its count from the Library row; its exact item identity is required to connect the owner's visible stall to these exported strings. No claim that the user's spinner was merely cosmetic is justified yet. The export has no scrub gesture state, slider range, or rendered thumb position, and does not establish a scrubber root cause.

Owner identifies the stalled item as “Something Is Shifting in the Inflation Picture” (Inflation). This binds the visible stall to the exported `preparing_0_of_2` / `started_without_waiting_for_opening_buffer` entries. The export still does not identify the owner of generation `23/23`, or specify whether the scrubber recurrence used live or fully rendered playback. Item details currently disables its primary Play path whenever the Library row is `.preparing`; missing manifests can also produce that state without a running job. These are confirmed presentation mechanisms, not yet a proven cause of the five-minute rendering stall.
