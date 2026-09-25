#!/usr/bin/env node
// svc is a tiny operations CLI used to demo AI coding sessions in Docker Sandboxes.
import { collect, healthy, render, renderJson } from '../src/status.js';

const [command, ...args] = process.argv.slice(2);

function usage() {
  process.stderr.write('usage: svc status [--json]\n');
}

switch (command) {
  case 'status': {
    const report = collect();
    process.stdout.write(args.includes('--json') ? renderJson(report) : render(report));
    process.exitCode = healthy(report) ? 0 : 1;
    break;
  }
  default:
    usage();
    process.exitCode = 2;
}
