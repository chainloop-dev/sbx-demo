import { test } from 'node:test';
import assert from 'node:assert/strict';
import { collect, healthy, render, renderJson } from '../src/status.js';

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

test('renderJson prints the same report as parseable JSON', () => {
  const report = collect(new Date('2026-09-25T10:00:00Z'));
  const parsed = JSON.parse(renderJson(report));
  assert.equal(parsed.checkedAt, '2026-09-25T10:00:00.000Z');
  assert.equal(parsed.healthy, true);
  assert.deepEqual(parsed.components, report.components);
});
