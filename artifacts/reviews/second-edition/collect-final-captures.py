"""Export only named screenshots from verified runs of the current input."""
import json
from pathlib import Path
import re
import runpy
import shutil
import subprocess
h = runpy.run_path('artifacts/reviews/second-edition/run-remaining-checks.py', run_name='helpers')
root = h['ROOT']
identity = h['verification'].input_identity()
output = root / 'artifacts/validation/gate-1/second-edition/screenshots'
output.mkdir(exist_ok=True)
records = []
for p in sorted((root / 'artifacts/test-runs').glob('*/manifest.json')):
    run = json.loads(p.read_text())
    if run.get('input_sha256') != identity or run.get('status') != 'verified' or not (p.parent/'tests.xcresult').exists():
        continue
    if not any(t in p.parent.name for t in ('-ui', '-release')):
        continue
    device = run.get('destination',{})
    if isinstance(device,str): device={'description':device}
    desc = json.dumps(device)
    family = 'ipad' if h['IPAD'] in desc else 'small' if h['SMALL'] in desc else 'phone'
    dest = root/'artifacts/reviews/second-edition'/('final-export-'+p.parent.name)
    if not (dest/'manifest.json').exists():
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(p.parent/'tests.xcresult'),'--output-path',str(dest)],check=True,stdout=subprocess.DEVNULL)
    for test in json.loads((dest/'manifest.json').read_text()):
        for a in test.get('attachments',[]):
            name=a.get('suggestedHumanReadableName','')
            if not name.startswith('second-edition-') or not name.endswith('.png'): continue
            label=re.split(r'_\d+_[0-9A-F-]{36}',name)[0]
            if label.endswith('.png'): label=label[:-4]
            file=family+'-'+label+'.png'
            shutil.copyfile(dest/a['exportedFileName'],output/file)
            records.append({'file':file,'test':test.get('testIdentifier'),'run':str(p.relative_to(root)),'input_sha256':identity,'destination':device})
records=list({r['file']:r for r in records}.values())
(output/'final-index.json').write_text(json.dumps(records,indent=2)+'\n')
for r in records: print(r['file'])
