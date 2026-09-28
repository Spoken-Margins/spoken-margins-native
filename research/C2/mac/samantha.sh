#!/bin/sh
# (Mac) Render the three passages with Apple's Samantha voice and time it.
# Writes out/samantha-mac/<passage>.wav and results/darwin/samantha-mac.t4.json.
# Rate: `say` default (175 wpm), i.e. what the system voice does at the app's rate 1.0 today.
set -e
cd "$(dirname "$0")/.."
say -v '?' | grep -q '^Samantha ' || { echo "Samantha isn't installed: System Settings > Accessibility > Spoken Content > System Voice > Manage Voices"; exit 1; }
mkdir -p out/samantha-mac results/darwin
python3 - <<'PY'
import json, subprocess, time, os, wave
ps = json.load(open("passages.json"))["passages"]
res = {"engine": "samantha-mac", "passages": {}}
for p in ps:
    open("/tmp/c2p.txt", "w").write(p["text"])
    aiff = f"/tmp/{p['id']}.aiff"; wav = f"out/samantha-mac/{p['id']}.wav"
    t = time.perf_counter()
    subprocess.run(["say", "-v", "Samantha", "-f", "/tmp/c2p.txt", "-o", aiff], check=True)
    render = time.perf_counter() - t
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@22050", aiff, wav], check=True)
    with wave.open(wav) as w:
        dur = w.getnframes() / w.getframerate()
    res["passages"][p["id"]] = {"render_s": round(render, 3), "audio_s": round(dur, 2), "rtf": round(render / dur, 3), "chunks": 1}
tr = sum(v["render_s"] for v in res["passages"].values()); ta = sum(v["audio_s"] for v in res["passages"].values())
res["speed_x"] = round(ta / tr, 2)
res["ttfa_s_median"] = None  # `say` renders whole passages; first-audio isn't comparable
json.dump(res, open("results/darwin/samantha-mac.t4.json", "w"), indent=2)
print(json.dumps(res, indent=2))
PY
