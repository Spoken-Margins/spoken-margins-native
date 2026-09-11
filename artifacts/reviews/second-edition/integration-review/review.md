# Integration candidate review

All 35 input identities in `inputs.json` matched before review.

## Finding

### P1 — Item-level Replay opens the completed session instead of starting the promised new session

The item-detail primary control deliberately labels a finished item **Replay** ([`ExperienceItemDetailScreen.swift:188`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceItemDetailScreen.swift:188), [`ExperienceItemDetailScreen.swift:222`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceItemDetailScreen.swift:222)), but calls `startItem`. `startItem` treats a fully finished session as a continuation ([`Gate1AppModel.swift:5034`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:5034), [`Gate1AppModel.swift:7969`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:7969)) and passes it to `resumeSession`. At 100%, `resumeSession` only inspects that old session and presents it paused; its own success message says “Use Play from Beginning to restart” ([`Gate1AppModel.swift:5127`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:5127)). It does not call `startNewSession`.

Counterexample: finish an item, return to its detail screen, then tap **Replay**. The user is shown the old finished session rather than replaying in a separate session, contrary to the visible action and the completed-session retention rule. The Library row play action has the same route through `startItem`.

When the preferred continuation is finished (or complete), have `startItem` call `startNewSession(id:)`; retain `resumeSession` only for unfinished sessions. Add a model test that finishes a session, invokes `startItem`, and asserts a different session ID at initial position. The existing assertion for “Opened completed session. Use Play from Beginning to restart” ([`Gate1AppModelWorkflowTests.swift:2388`](../../../../App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift:2388)) preserves the behavior that conflicts with Replay.

## Closed prior findings and scope notes

The destructive operations now pass `interjection.sessionId` from the app model, and all three engine endpoints route it through the scoped lookup. The candidate includes duplicate-ID/two-session coverage. Written exports now retain `captureKind`, preserve written text without a cleaned-transcript substitution, and include a fixture plus legacy-null coverage; JSON and Markdown serialization carry the distinction.

The changed Margin detail gates Manage to the selected item and exact session, while the engine remains defensive if another caller reaches a foreign Margin. Finished presentation uses `snapshot.phase == .finished`; no new playback status case was introduced. The task-first Library and Margin surfaces expose their secondary/recovery controls as visible controls, context menus, swipe actions, or accessibility actions. I found no further concrete defect in those paths during this pass.

No build, test, simulator, screenshot, or human product-flow validation was performed in this review. The separately reported fast result and pending app execution are not asserted here.
