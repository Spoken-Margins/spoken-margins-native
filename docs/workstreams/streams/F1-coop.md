# F1 · coop: listen together, asynchronously

**Outcome.** A group listens to the same item at different times, and it feels like a conversation.
- Each person's new Margins reach the others.
- A listener can review what's new to them by skimming from Margin to Margin, with a little lead-in context, and add their own replies.
- Everyone ends up with the same merged set: no duplicates, clear attribution, and the same result whatever order packets arrive in. The owner thinks of it like git: many contributors, merged locally.

Serverless first (packets in a group chat). A server later makes it effortless: join a club, get notified when someone has finished and left Margins. Much later, large clubs get summaries of where many people reacted.

**Why.** One-to-one sharing works. The book club is the experience that makes people come back, and the thing that could spread the app.

**Where.** Mac. **Effort:** xhigh for M1.

**Waits for.**
- A2 M2 (one playback coordinator).
- C4 anchors (Margins must land in the right place in each person's copy).
- D5 M2 for Skim-to-Margin.
- B4 M1 for the server phase.

**Seams.** Owns **I10** for group features. Uses I9 (episode identity), I7 (structure, for clustering), I11 (server).

## Starting points (read before designing anything)

- `docs/repo-review-2026-09-24.md`: why the first co-op attempt failed. Four playback state machines. Packets that Build 28 rejected because every export required a new capability. A frozen-clock stall that was never explained. Its §5 recommends an order: coordinator first, then the smallest vertical slice, and conversation metadata emitted only when a packet actually contains a reply.
- `park/co-op-2026-09-24` is reference only. Don't merge it. It holds:
  - `MarginConversation.swift` (conversation v1 and v2);
  - `docs/co-op-experience-plan-2026-09-24.md`, a four-person reply scenario;
  - `docs/book-club-repository-protocol-plan.md`, a signed-DAG and encrypted-relay design.
- One-to-one today: `SpokenMarginsPackageImporter` is idempotent by package digest and auto-adds the podcast. J5 covers it.

## Milestones

**M1: Many-to-one merge (no server).**
- Done when:
  - Importing packets from three people on the same episode produces one item with three attributed layers, the same result for all six import orders, and no duplicates on re-import.
  - Each Margin carries "new to me" state.
  - Each packet still imports into Build 29, which simply shows the Margins.
  - Host tests cover the order permutations and re-imports.
  - Lane T4 runs a three-packet J5 variant.

**M2: Review and reply.**
- Done when:
  - "Review new Margins" skims from one new Margin to the next with a short lead-in (through D5's navigation).
  - A listener can reply to a specific Margin. The reply is linked to its parent by a stable identifier.
  - A reply packet makes the round trip A → B → C → A with correct threading.
  - The conversation capability is required only when a packet actually contains a reply, so Build 29 imports reply-free packets. It shows replies as plain Margins, or rejects them with a clear message; test which.
  - The owner runs it with two or three real people (T6).

**M3: Book club with a server.**
- Done when:
  - A club is created with an invite link. Members' new Margins arrive without passing files around. A member is notified when someone has finished an item and left Margins.
  - The design, reviewed by the owner before building, states what the server can read. Recommendation: end-to-end encrypted Margins, so the server relays but can't listen.
  - Works for a club of 10 on the lane with simulated members.

**M4: Large clubs.**
- Done when, for an item with 100 simulated members' Margins, the listener can hear a summary of each hot spot ("10 people reacted here: 2 argued X, 2 argued the opposite, 6 found it funny") with attribution preserved and the individual Margins one tap away. Where the clustering runs (on device, or server with consent) is decided with the owner in M3.

## Must not break

J5. Build 29 importing new packets (I10). Podcast-anchor placement quality.

## Out of scope

Human authentication or signing of Margins (#22). Worth doing later, not required (owner's words).

## Related

#18, #19, #22, #25, #26, #70, #82, #157, #158, #166.
