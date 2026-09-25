#!/usr/bin/env node
// svc is a tiny operations CLI used to demo AI coding sessions in Docker Sandboxes.
import { collect, healthy, render, renderJSON } from '../src/status.js';

const [command, ...flags] = process.argv.slice(2);

function usage() {
  process.stderr.write('usage: svc status [--json]\n');
}

switch (command) {
  case 'status': {
    const unknown = flags.filter((f) => f !== '--json');
    if (unknown.length > 0) {
      usage();
      process.exitCode = 2;
      break;
    }
    const report = collect();
    process.stdout.write(flags.includes('--json') ? renderJSON(report) : render(report));
    process.exitCode = healthy(report) ? 0 : 1;
    break;
  }
  default:
    usage();
    process.exitCode = 2;
}
