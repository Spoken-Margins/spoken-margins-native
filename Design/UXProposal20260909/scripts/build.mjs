import fs from 'node:fs';
import path from 'node:path';
for(const file of ['index.html','book.css','prototype.js','audit.js']){if(!fs.statSync('public/'+file).size)throw new Error('Missing '+file);}
const html=fs.readFileSync('public/index.html','utf8');
for(const match of html.matchAll(/(?:src|href)="([^"#]+)"/g)){if(/^(https?:|mailto:)/.test(match[1]))continue;const target=match[1].split('#')[0];if(target&&!fs.existsSync(path.join('public',target)))throw new Error('Missing local reference: '+target);}
const findings=JSON.parse(fs.readFileSync('public/findings.json'));
if(new Set(findings.map(x=>x.id)).size!==findings.length)throw new Error('Duplicate finding IDs');
for(const f of findings){for(const k of ['id','title','severity','basis','observation','impact','proposal','test','evidence'])if(!f[k])throw new Error(f.id+' missing '+k);for(const e of f.evidence.filter(x=>x.startsWith('evidence/')))if(!fs.existsSync('public/'+e))throw new Error('Missing evidence '+e);}
fs.rmSync('dist', {recursive:true, force:true});
fs.cpSync('public', 'dist', {recursive:true});
console.log('Static book build verified: '+findings.length+' findings; all local entry references and finding evidence exist. Output: dist/');
