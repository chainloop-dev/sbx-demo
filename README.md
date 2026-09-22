# sbx-demo

Run a coding agent in a Docker Sandbox. Every session becomes signed evidence, checked against policy, with the verdict on the pull request.

## Prerequisites

- [`sbx`](https://docs.chainloop.dev/guides/docker-sandboxes) installed, with the daemon running (`sbx daemon status`)
- The [`chainloop`](https://docs.chainloop.dev/getting-started/installation) CLI installed
- A Chainloop API token for the `sbx-demo` organization — see `.env.example`
- An SSH key loaded in your agent (`ssh-add -l`), so sandboxed commits can be signed

## Run it

```bash
cp .env.example .env   # fill in chainloopToken=
sbx run --clone --kit-args-file .env chainloop/sbx-kit-claude
```

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

## The three-stage story

Real work happens in three separate sessions, one number per feature — see `docs/README.md`. `docs/prds/001-watch-flag.md` is a merged example of stage 1. To show the full arc live:

1. **Intent** — `Write a PRD for <some feature> in docs/prds/002-<slug>.md, following the shape of 001-watch-flag.md.`
2. **Design** — `Read docs/prds/002-<slug>.md and write the spec in docs/specs/002-<slug>.md.`
3. **Implementation** — `Read docs/specs/002-<slug>.md and implement it in node/, with tests.`

Each is its own branch, PR, and attestation. Point out that a session mixing stages — e.g. rewriting the PRD while implementing — fails `session-stays-in-one-stage`.

## How it's governed

Policy checks run against every session's attestation (`.chainloop/policies/`):

- `session-stays-in-one-stage` — one of intent, design, or implementation per session
- `prd-no-implementation-detail` — an AI reviewer checks a PRD stayed at context/problem/summary, no flags or schemas
- `tests-were-run` — the transcript must show the test suite actually executing, not just test files changing
- `no-secrets` — fails on real-looking credentials in the diff (see the fixture above)

## Layout

- `docs/prds/`, `docs/specs/`: intent and design, one number per feature.
- `node/`, `go/`: the same `svc status` CLI, twice. Pick one.
- `.chainloop/`: the contract and policies every session is checked against.
- `scripts/demo-reset.sh`: back to a clean state (sandboxes, branches, tree).
- `scripts/demo-test.sh`: the whole loop, unattended, with assertions.

Guide: https://docs.chainloop.dev/guides/docker-sandboxes

## Resetting between runs

```bash
scripts/demo-reset.sh          # remove demo-* sandboxes and branches, clean the tree
scripts/demo-reset.sh --hard   # also drop persistent ~/.claude volumes (first-run experience)
```

Useful between takes at a demo booth, or before a fresh run of `scripts/demo-test.sh`.

## Troubleshooting on Linux

**`sbx create` fails with `unknown volume driver: block`.** The daemon needs `/usr/sbin` on its
PATH to find `mkfs.ext4`; without it the block volume driver is disabled at startup and the error
you get names neither. Start the daemon as `PATH="/usr/sbin:/sbin:$PATH" sbx daemon start -d`
([sbx-releases#48](https://github.com/docker/sbx-releases/issues/48)). `scripts/lib-sbx.sh` does this.

**`sbx` cannot reach `/dev/kvm`.** Run `sudo usermod -aG kvm $USER`, then open a new login shell.
In an older shell, `sg kvm -c '<command>'` works without logging out.

**Sandbox commits are not signed.** The sandbox forwards your host SSH agent; it needs a key
loaded on the host. `ssh-add -l` on the host must list one.
