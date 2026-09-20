// Collects and renders the health of the service's components.
// Checks are simulated so the demo has no external dependencies.

export function collect(now = new Date()) {
  return {
    checkedAt: now.toISOString(),
    components: [
      { name: 'api', ok: true, latencyMs: 12, detail: '200 OK' },
      { name: 'database', ok: true, latencyMs: 3, detail: 'connections 4/50' },
      { name: 'queue', ok: true, latencyMs: 8, detail: 'depth 0' },
    ],
  };
}

export function healthy(report) {
  return report.components.every((c) => c.ok);
}

export function render(report) {
  const rows = [
    `checked at ${report.checkedAt}`,
    `${'COMPONENT'.padEnd(10)} ${'STATUS'.padEnd(6)} ${'LATENCY'.padEnd(8)} DETAIL`,
  ];
  for (const c of report.components) {
    const state = c.ok ? 'ok' : 'FAIL';
    rows.push(`${c.name.padEnd(10)} ${state.padEnd(6)} ${`${c.latencyMs}ms`.padEnd(8)} ${c.detail}`);
  }
  return rows.join('\n') + '\n';
}
