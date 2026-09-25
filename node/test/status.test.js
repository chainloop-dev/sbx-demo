import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { collect, healthy, render, renderJSON } from '../src/status.js';

test('healthy is true only when every component is ok', () => {
  const report = { components: [{ ok: true }, { ok: true }] };
  assert.equal(healthy(report), true);
  report.components[1].ok = false;
  assert.equal(healthy(report), false);
});

test('render prints a header and one row per component', () => {
  const report = collect(new Date('2026-09-25T10:00:00Z'));
  const out = render(report);
  for (const want of ['checked at 2026-09-25T10:00:00.000Z', 'COMPONENT', 'api', 'ok', '12ms', '200 OK']) {
    assert.ok(out.includes(want), `output missing ${want}:\n${out}`);
  }
});

test('renderJSON prints the same report as JSON', () => {
  const report = collect(new Date('2026-09-25T10:00:00Z'));
  assert.deepEqual(JSON.parse(renderJSON(report)), report);
});

test('svc status --json prints parseable JSON and exits 0 when healthy', () => {
  const bin = fileURLToPath(new URL('../bin/svc.js', import.meta.url));
  const res = spawnSync(process.execPath, [bin, 'status', '--json'], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  const out = JSON.parse(res.stdout);
  assert.equal(typeof out.checkedAt, 'string');
  assert.deepEqual(out.components.map((c) => c.name), ['api', 'database', 'queue']);
});
