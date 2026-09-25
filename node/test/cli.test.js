import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const bin = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'svc.js');

test('status --json prints a parseable report matching the table output', () => {
  const out = execFileSync('node', [bin, 'status', '--json'], { encoding: 'utf8' });
  const report = JSON.parse(out);
  assert.ok(report.checkedAt);
  assert.ok(Array.isArray(report.components));
  assert.ok(report.components.every((c) => 'name' in c && 'ok' in c && 'latencyMs' in c && 'detail' in c));
});
