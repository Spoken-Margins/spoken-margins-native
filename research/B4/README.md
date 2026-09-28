# B4 bridge: server skeleton (M1)

Design and privacy rules: [DESIGN.md](DESIGN.md). Tracking issue #190.

Needs Go 1.24+. No third-party modules.

```bash
cd research/B4/server && go test ./...     # unit and end-to-end tests
research/B4/scripts/demo.sh                # health, one attested request, block one install, kill switch
```

`deploy/` holds templates for the owner's VPS. Nothing here is deployed.
