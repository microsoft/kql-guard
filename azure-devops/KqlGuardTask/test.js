'use strict';
// Framework-free self-check (matches the repo's test/run-tests.sh ethos).
// Covers the pure helpers only — no ADO agent, no network.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const t = require('./index.js');

// --- buildArgs: defaults, full options, raw-args passthrough ---
assert.deepStrictEqual(
  t.buildArgs({ path: '.', format: 'sarif', maxCost: '', schema: '', args: '' }),
  ['.', '--format', 'sarif']);

assert.deepStrictEqual(
  t.buildArgs({ path: 'detections', format: 'sarif', maxCost: '50', schema: 's.json', args: '' }),
  ['detections', '--format', 'sarif', '--max-cost', '50', '--schema', 's.json']);

assert.deepStrictEqual(
  t.buildArgs({ path: '.', format: 'text', maxCost: '', schema: '', args: '--strict --table-sizes sizes.json' }),
  ['.', '--format', 'text', '--strict', '--table-sizes', 'sizes.json']);

// --- splitArgs: quotes honored ---
assert.deepStrictEqual(
  t.splitArgs('--schema "my file.json" --strict'),
  ['--schema', 'my file.json', '--strict']);

// --- assetFor: four supported targets + unsupported ---
assert.strictEqual(t.assetFor('linux', 'x64'), 'kql-guard-linux-x64');
assert.strictEqual(t.assetFor('linux', 'arm64'), 'kql-guard-linux-arm64');
assert.strictEqual(t.assetFor('darwin', 'arm64'), 'kql-guard-osx-arm64');
assert.strictEqual(t.assetFor('win32', 'x64'), 'kql-guard-win-x64.exe');
assert.strictEqual(t.assetFor('darwin', 'x64'), null);
assert.strictEqual(t.assetFor('win32', 'arm64'), null);

// --- downloadUrl: latest vs pinned ---
assert.strictEqual(
  t.downloadUrl('kql-guard-linux-x64', 'latest'),
  'https://github.com/microsoft/kql-guard/releases/latest/download/kql-guard-linux-x64');
assert.strictEqual(
  t.downloadUrl('kql-guard-linux-x64', 'v1.2.0'),
  'https://github.com/microsoft/kql-guard/releases/download/v1.2.0/kql-guard-linux-x64');

// --- sarifToIssues: against the fixture + empty inputs ---
const sarif = JSON.parse(fs.readFileSync(path.join(__dirname, 'test.sarif'), 'utf8'));
const issues = t.sarifToIssues(sarif);
assert.strictEqual(issues.length, 2);
assert.deepStrictEqual(issues[0], {
  type: 'error', message: 'KQL001: Syntax error: unexpected token',
  sourcepath: 'detections/a.kql', linenumber: 3, columnnumber: 5,
});
assert.deepStrictEqual(issues[1], {
  type: 'warning', message: 'KQL003: Leading wildcard scan is expensive',
  sourcepath: 'detections/b.kql', linenumber: 1, columnnumber: 1,
});
assert.deepStrictEqual(t.sarifToIssues({ runs: [] }), []);
assert.deepStrictEqual(t.sarifToIssues(null), []);

// --- resultForExit: full gate table ---
assert.strictEqual(t.resultForExit(0, false), 'Succeeded');
assert.strictEqual(t.resultForExit(0, true), 'Succeeded');
assert.strictEqual(t.resultForExit(1, false), 'SucceededWithIssues');
assert.strictEqual(t.resultForExit(1, true), 'Failed');
assert.strictEqual(t.resultForExit(2, false), 'Failed');
assert.strictEqual(t.resultForExit(2, true), 'Failed');

console.log('ok - all kql-guard ADO task self-checks passed');
