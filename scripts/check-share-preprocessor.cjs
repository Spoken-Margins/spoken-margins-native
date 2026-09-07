// Exercise the JavaScript resource from the built extension, not a helper import.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = {
  console,
  document: { URL: 'https://example.com/brief.pdf', contentType: 'application/pdf',
    title: 'Brief PDF', body: null, querySelector: () => null },
  window: { location: { href: 'https://example.com/brief.pdf' } }
};
vm.runInNewContext(fs.readFileSync(process.argv[2], 'utf8'), context, { timeout: 5000 });
assert.equal(typeof context.ExtensionPreprocessingJS?.run, 'function');
vm.runInNewContext('ExtensionPreprocessingJS.run({completionFunction: value => { globalThis.payload = value; }})',
  context, { timeout: 5000 });
assert.equal(context.payload?.contentType, 'application/pdf');
assert.equal(context.payload?.isPDFDocument, true);
assert.equal(context.payload?.documentURL, 'https://example.com/brief.pdf');
console.log('Built Safari preprocessing entrypoint and PDF payload: passed');
