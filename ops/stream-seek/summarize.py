import json, sys
for line in open(sys.argv[1] if len(sys.argv) > 1 else 'results.jsonl'):
    try: d = json.loads(line)
    except Exception: print('unparsed', line[:100]); continue
    r = d['run']
    seeks = r.get('seeks', [])
    errs = [s['errorSec'] for s in seeks if s.get('errorSec') is not None]
    seekms = [s['seekMs'] for s in seeks]
    mb = [round(s['bytesSinceReset']/1e6, 1) for s in seeks]
    print(f"{d['profile']:5} {r['file']:14} precise={int(r['precise'])} ready={r['ready']} readyMs={r['readyMs']:6} MBatReady={r['bytesAtReady']/1e6:6.2f} firstSeekMs={seekms[:2]} MB={mb} maxAbsErr={max(map(abs,errs)) if errs else None} errs={errs}")
