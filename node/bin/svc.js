#!/usr/bin/env node
// svc is a tiny operations CLI used to demo AI coding sessions in Docker Sandboxes.
import { collect, healthy, render } from '../src/status.js';

const [command] = process.argv.slice(2);

function usage() {
  process.stderr.write('usage: svc status\n');
}

switch (command) {
  case 'status': {
    const report = collect();
    process.stdout.write(render(report));
    process.exitCode = healthy(report) ? 0 : 1;
    break;
  }
  default:
    usage();
    process.exitCode = 2;
}
