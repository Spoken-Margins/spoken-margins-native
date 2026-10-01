#!/usr/bin/env python3
"""Print Codex usage limits from `codex app-server` (`account/rateLimits/read`).

sm_codex_audit.py runs this and parses its stdout (parse_limits), so keep the
printed lines as they are. Exits 1 with "no response" or "error ..." on failure.
"""
import json, subprocess, sys, time, select

C = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"


def main():
    p = subprocess.Popen([C, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)

    def send(o):
        p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()

    def recv(want_id, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([p.stdout], [], [], 1)
            if r:
                line = p.stdout.readline()
                if not line: break
                try: m = json.loads(line)
                except Exception: continue
                if m.get("id") == want_id: return m
        return None

    send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "limits-probe", "version": "0.1"}}})
    recv(1)
    send({"method": "initialized"})
    send({"id": 2, "method": "account/rateLimits/read"})
    r = recv(2)
    p.terminate()
    if not r: print("no response"); sys.exit(1)
    if "error" in r: print("error", r["error"]); sys.exit(1)
    res = r["result"]
    def win(w): return None if not w else {k: w.get(k) for k in ("usedPercent", "windowDurationMins", "resetsAt")}
    rl = res.get("rateLimits") or {}
    print("planType:", rl.get("planType"))
    print("primary:", win(rl.get("primary")))
    print("secondary:", win(rl.get("secondary")))
    print("limitIds:", list((res.get("rateLimitsByLimitId") or {}).keys()))
    for k, v in (res.get("rateLimitsByLimitId") or {}).items():
        print(" ", k, v.get("limitName"), "primary", win(v.get("primary")), "secondary", win(v.get("secondary")))


if __name__ == "__main__":
    main()
