# Two-target implementation map (before code changes)

Candidate: `codex/co-op` at HEAD `34837c6055471297ca0b360c591f734bad5c2c82` plus substantial pre-existing dirty work. Owner instruction to implement `docs/co-op-experience-plan-2026-09-24.md` has been recorded in `docs/release-lanes.md`. Usage at entry: 38% used / 62% remaining; the older 70% remaining floor is already crossed, so the budget decision is pending.

Minimal graph: Cole C; Alex A → C; Blair B → C; Casey D → [A,B]. D must retain ordered *exact revision* references to A and B. Context order C,A,B,D should play C once. Reversing packet arrival must not change graph or order. Casey's own capture anchor remains distinct from A/B source positions. After re-recording A, D still points to the prior A revision.

| Boundary | Current state | Required change and check |
| --- | --- | --- |
| Model/graph | `MarginConversation.parent` is optional single reference; merge and ancestors walk a chain | Versioned ordered target list; validate limit, uniqueness, same item when resolved, cycles across all edges, topological context order and missing ancestors |
| Schema/archive | conversation.v1 field `parent`; closed schema; archive requires v1 for any conversation | New capability and schema for multi-target records; preserve v1 decoding, reject unsupported new packets, never downgrade by dropping target |
| Persistence/import | JSON record store and atomic merge; overlap dedup by exact revision | Check old stored JSON compatibility; exact target equality, atomic conflict rollback and reverse arrival |
| Sender/forward | Forward closure walks one chain | Gather all necessary ancestors once; review every included voice/body; preserve omitted links as visibly missing |
| App metadata/recording | Context editor picker and pending capture carry one parent | Multi-select exact targets, preserve selection through recording/restart, clear on cancel, show targets before save |
| Listening | `parentPlaybackDestinations` walks one chain; queue plays ancestors then reply | Deterministic deduplicated context queue; selected reply alone remains immediate; skip/return preserved |
| Source position | `conversationSourcePosition` and `sourceAnchorForConversation` can inherit a parent anchor | Preserve the child's capture anchor; resolve source separately and conservatively; never choose first target as placement evidence |
| Fixture | Supplied legacy archive has 22 Margins and no conversation metadata | Stable conversion for selected Cole revision; A/B/D packet round trip; real importer accepts reversed/repeated arrival |
| Owner proof | Earlier suite and builds predate multi-target change | One identifiable candidate and physical owner listening/record/export/reimport; no claim of human validation from tests |

Disproof cases: duplicate target, self link, A→D cycle when D already targets A, target in another item, contradictory same revision, missing A or B, D received first, old v1 packet, repeated legacy import, context ordering and audio dedup. A model-only or archive-only success does not close the feature.
