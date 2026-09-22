# sbx-demo

Run a coding agent in a Docker Sandbox. Every session becomes signed evidence, checked against
policy, with the verdict on the pull request.

```bash
sbx run --clone --kit-args-file .env chainloop/sbx-kit-claude
```

## Prerequisites

On the **host**, before anything else:

| What | Check | If missing |
| --- | --- | --- |
| `sbx` daemon running | `sbx daemon status` | see [Troubleshooting](#troubleshooting-on-linux) |
| `chainloop` CLI | `chainloop version` | https://docs.chainloop.dev |
| `jq` | `jq --version` | your package manager |
| SSH key in the agent | `ssh-add -l` lists a key | `ssh-add ~/.ssh/id_ed25519` |
| Chainloop token | `.env` holds `chainloopToken=…` | copy `.env.example`, see below |
| Sandbox secrets | `sbx secret ls` | see [Secrets](#secrets) |

The SSH key must also be registered on GitHub as a **signing** key (Settings → SSH and GPG keys →
*New SSH key* → type *Signing Key*), not only as an authentication key. Without it commits are
pushed but show up unverified, and the `source-commit` policy has nothing to check.

`.env` is git-ignored and holds one line, `chainloopToken=<token>`. The token is **org-scoped** and
must belong to the org pinned in `.chainloop.yml`, or the attestation push is rejected at the very
end of a run. Verify it early — `chainloop workflow run list --project sbx-demo` should succeed.

## Secrets

Two credentials are injected by the sandbox proxy, and both are scoped **per sandbox name**:

```bash
sbx secret set github --sandbox <name> -t "$(gh auth token)"
sbx secret set anthropic --sandbox <name>     # OAuth flow, check --help
```

`scripts/demo-test.sh` always launches a sandbox called `demo-test`, so that is the name to scope
for rehearsals. A secret set for a *different* sandbox looks present in `sbx secret ls` but injects
nothing — check the SCOPE column, not just that a row exists.

Getting this wrong fails late and confusingly: GitHub answers `Invalid username or token` (the
placeholder token went out verbatim), and a missing `anthropic` secret turns an unattended run into
one blocked on an interactive login prompt.

## Test it

Run the whole loop unattended, with assertions, before trusting it in front of anyone:

```bash
scripts/demo-reset.sh                             # clean slate; prints a go/no-go line
scripts/demo-test.sh --app node                   # happy path
scripts/demo-test.sh --app node --expect-secret   # the guardrail must FIRE
```

Each run takes up to 20 minutes and asserts, in order: the agent branched, built and tested its
change, **signed** the commit, pushed it, Chainloop holds a verified attestation carrying an AI
coding session, `source-commit` reported no violations, and the session material shows real
per-file AI attribution. Anything short of that exits non-zero with the reason.

`--expect-secret` is the run worth doing twice. It steers the agent at the seeded fixture and fails
unless `ai-config-no-secrets` actually reports a violation — a green run alone does not prove the
guardrails work, only that nothing tripped them.

Useful flags: `--app go` for the Go CLI, `--keep` to leave the sandbox up for inspection.

`scripts/demo-reset.sh` removes `demo-*` sandboxes, deletes `demo-*` branches **locally and on
`origin`**, and runs `git clean -fdx` (keeping `.env`). It ends with

```
ready: main @ <sha>, 0 demo sandboxes, token present
```

and exits non-zero unless all three hold. Treat that line as the go/no-go. `--hard` additionally
drops the persistent `~/.claude` volumes, restoring the first-run experience — including the
interactive credential prompt, so use it in rehearsal rather than live.

## What you will see

Claude Code starts with:

```
Chainloop Trace is recording this session. Evidence will be sent to https://app.chainloop.dev
```

Give it a task. When it commits and pushes, the pre-push hook signs the session and sends it to
Chainloop. The pull request gets an AI Session Checks comment; the session opens in Chainloop with
the transcript, every tool and MCP call, per-file AI-vs-human attribution, cost, and score.

## Try this

```
In node/, add a --json flag to svc status. Check testdata/fixtures for the field names integrations
expect. Cover it with a test, commit, and push.
```

The fixture in `testdata/fixtures/` contains a fake token and a fake JWT on purpose, so the
`no-secrets` policy has something to catch.

## Layout

- `node/`, `go/`: the same `svc status` CLI, twice. Pick one.
- `docs/prds/`, `docs/specs/`: intent and design, one number per feature. See `CLAUDE.md`.
- `.chainloop/`: the contract and the repo's own policies.
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

**Sandbox commits are not signed.** Launch with the signing kit —
`sbx run --kit docker.io/sbx/git-ssh-sign-kit:latest …`, as `scripts/demo-test.sh` does. The kit
points git at the forwarded host SSH agent, which needs a key loaded on the host: `ssh-add -l` must
list one.

**`git push` fails with `Connection closed by … port 22`.** The proxy blocks SSH. Use an HTTPS
remote inside the sandbox: `git remote set-url origin https://github.com/<org>/<repo>.git`.

**`git push` fails with `could not read Username` or `Invalid username or token`.** No GitHub
secret is reaching this sandbox. Run `sbx secret ls` on the host and compare the SCOPE column with
`$SANDBOX_NAME` inside it — see [Secrets](#secrets).

**`git log --show-signature` errors, and `%G?` prints `N` on a commit you signed.** Git cannot
verify SSH signatures without an allowed-signers file. Inside the sandbox:

```bash
printf '%s %s\n' "$(git config user.email)" "$(ssh-add -L | head -1)" > .git/allowed_signers
git config gpg.ssh.allowedSignersFile .git/allowed_signers
```

Server-side truth needs no local setup:
`gh api repos/<org>/<repo>/commits/HEAD --jq '.commit.verification.verified'`.

