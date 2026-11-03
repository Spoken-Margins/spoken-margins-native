# Sharing-loop tour packets (#3237)

Plans for the two packets the screen tour opens, written with `coop-packet` (see `Sources/CoopPacket/README.md`). Synthetic voice (`say -v Samantha`) only, never owner data.

- `sam-margin.json` → `App/TestFixtures/sharing-loop-sam-margin.spokenmargins`: Sam's Margin at 5:00 on the tour's generated podcast.
- `listener-margin.json` → `artifacts/sharing-loop/sharing-loop-listener-margin.spokenmargins` (not checked in): stands for the packet the listener sent. Only its digest matters; the tour marks the listener's own Margin with it.
- `sam-reply.json` → `App/TestFixtures/sharing-loop-sam-reply.spokenmargins`: Sam's reply to `margin-ui-listener` in that packet.

To rebuild, from the repo root:

```bash
mkdir -p artifacts/sharing-loop
for plan in sam-margin listener-margin sam-reply; do Packages/SessionKit/.build/tools/debug/coop-packet build Packages/SessionKitTools/Plans/sharing-loop/$plan.json --out artifacts/sharing-loop; done
```

Then copy the two Sam packets into `App/TestFixtures/`, and put the listener packet's digest (`coop-packet inspect`) in `UITestingLaunchSeed.listenerSharedIdentity`. `SharingLoopTourFixtureTests` fails if the packets stop matching the seeded episode or the reply stops naming that identity.
