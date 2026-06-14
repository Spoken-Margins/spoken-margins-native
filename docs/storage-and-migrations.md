# Storage And Migrations

## Purpose

Production storage should preserve sessions, anchors, audio references, and AI work across app launches and device sync. SQLite is the recommended source of truth.

The JSON Schemas define the portable contract. SQLite tables should be shaped to support those contracts, not replace them.

## Initial Tables

### items

- id primary key
- title
- media_type
- text nullable
- external_reference nullable
- external_reference_type
- status
- created_at
- updated_at

### transcripts

- id primary key
- item_id indexed
- language nullable
- source

### transcript_segments

- id primary key
- transcript_id indexed
- item_id indexed
- start_ms nullable
- end_ms nullable
- start_char nullable
- end_char nullable
- text
- speaker nullable

### audio_assets

- id primary key
- item_id indexed
- audio_source_type
- availability
- file_path nullable
- url nullable
- duration_ms nullable
- codec nullable
- voice_id nullable
- created_at

### listening_maps

- id primary key
- item_id indexed
- overview
- created_at

### listening_map_claims

- id primary key
- map_id indexed
- text
- sort_order

### listening_map_chapters

- id primary key
- map_id indexed
- item_id indexed
- title
- description
- anchor
- anchor_type
- start_char nullable
- end_char nullable
- start_ms nullable
- end_ms nullable
- transcript_segment_id nullable
- percent
- sort_order

### sessions

- id primary key
- item_id indexed
- status
- phase
- runtime_profile_id
- completion_percent
- current_target_type
- current_target_id
- current_char_offset nullable
- current_media_time_ms nullable
- current_segment_index nullable
- current_chapter_id nullable
- playback_rate
- pending_profile_transition nullable
- created_at
- completed_at nullable

### runtime_profile_events

- id primary key
- session_id indexed
- from_profile_id nullable
- to_profile_id
- reason
- created_at
- metadata_json nullable

### interjections

- id primary key
- item_id indexed
- session_id indexed
- target_type
- target_id
- chapter_id nullable
- created_at
- rough_percent
- anchor_type
- start_char nullable
- end_char nullable
- anchor_before nullable
- anchor_after nullable
- media_time_ms nullable
- playback_rate_observed nullable
- transcript_segment_id nullable
- turn_segment_index nullable
- audio_status
- audio_path nullable
- audio_duration_ms nullable
- transcription_status
- transcript nullable
- cleaned_transcript nullable
- display_text nullable
- transcript_deleted_at nullable
- cleaned_transcript_deleted_at nullable
- status
- error nullable

### conversation_turns

- id primary key
- session_id indexed
- role
- turn_type
- status
- summary nullable
- text nullable
- raw_text nullable
- source_interjection_ids_json
- created_at
- completed_at nullable
- error nullable

### ai_jobs

- id primary key
- kind
- item_id nullable indexed
- session_id indexed
- turn_id nullable indexed
- provider_type
- base_url nullable
- model
- api_key_ref nullable
- status
- attempts
- last_error nullable
- created_at
- updated_at

### watch_packages

- id primary key
- item_id indexed
- session_id indexed
- created_at
- expires_at nullable
- package_path nullable
- status

### watch_sync_events

- id primary key
- watch_package_id indexed
- session_id indexed
- item_id nullable indexed
- event_type
- created_at
- payload_json
- imported_at nullable
- import_error nullable

## Indexes

Required indexes:

- sessions by item_id and created_at
- interjections by session_id and created_at
- transcript_segments by item_id and start_ms
- transcript_segments by item_id and start_char
- listening_map_chapters by item_id and start_ms
- listening_map_chapters by item_id and start_char
- conversation_turns by session_id and created_at
- ai_jobs by status and updated_at
- watch_sync_events by session_id and created_at
- runtime_profile_events by session_id and created_at

## Migration Strategy

Use numbered SQLite migrations checked into the native repo.

Rules:

- migrations are append-only
- every schema change includes a fixture migration test
- no migration may drop user audio or interjection anchors
- JSON import/export remains versioned independently of database migrations

Initial migration:

- create all v1 tables
- create required indexes
- create metadata table with schema version

## Fixture Seeding

The native test target should load JSON fixtures and insert them through repository APIs, not direct SQL.

Seed order:

1. items
2. transcripts and transcript segments
3. audio assets
4. Listening Maps and chapters
5. sessions
6. interjections
7. conversation turns
8. AI jobs
9. runtime profile events
10. watch packages and sync events

## Data Integrity Rules

- Every session references an item.
- Every interjection references a session and item.
- Every interjection has a portable anchor.
- Audio files are never deleted by transcript deletion.
- Raw transcript, cleaned transcript, and display text have separate lifecycle rules.
- Deleting one interjection representation must not silently delete the others.
- Watch sync event import is idempotent by event id.
- AI job retry updates the job; it does not create duplicate turns unless explicitly requested.
- Playback progress updates must not overwrite newer interjection records.
- Profile transitions must not delete queued AI jobs, interjection audio, anchors, or prepared packages.
