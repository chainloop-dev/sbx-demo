# sbx-demo

Run a coding agent in a Docker Sandbox. Every session becomes signed evidence, checked against policy, with the verdict on the pull request.

```bash
sbx run --clone --kit-args-file .env chainloop/sbx-kit-claude
```

`.env` holds one line, `chainloopToken=<your Chainloop API token>`, and is git-ignored.

## What you will see

Claude Code starts with:

```
Chainloop Trace is recording this session. Evidence will be sent to https://app.chainloop.dev
```

Give it a task. When it commits and pushes, the pre-push hook signs the session and sends it to Chainloop. The pull request gets an AI Session Checks comment; the session opens in Chainloop with the transcript, every tool and MCP call, per-file AI-vs-human attribution, cost, and score.

## Try this

```
In node/, add a --json flag to svc status. Check testdata/fixtures for the field names integrations expect. Cover it with a test, commit, and push.
```

The fixture in `testdata/fixtures/` contains a fake token and a fake JWT on purpose, so the `no-secrets` policy has something to catch.

## Layout

- `node/`, `go/`: the same `svc status` CLI, twice. Pick one.
- `scripts/demo-reset.sh`: back to a clean state (sandboxes, branches, tree).
- `scripts/demo-test.sh`: the whole loop, unattended, with assertions.

Guide: https://docs.chainloop.dev/guides/docker-sandboxes

## Troubleshooting on Linux

**`sbx create` fails with `unknown volume driver: block`.** The daemon needs `/usr/sbin` on its
PATH to find `mkfs.ext4`; without it the block volume driver is disabled at startup and the error
you get names neither. Start the daemon as `PATH="/usr/sbin:/sbin:$PATH" sbx daemon start -d`
([sbx-releases#48](https://github.com/docker/sbx-releases/issues/48)). `scripts/lib-sbx.sh` does this.

**`sbx` cannot reach `/dev/kvm`.** Run `sudo usermod -aG kvm $USER`, then open a new login shell.
In an older shell, `sg kvm -c '<command>'` works without logging out.

**Sandbox commits are not signed.** The sandbox forwards your host SSH agent; it needs a key
loaded on the host. `ssh-add -l` on the host must list one.
