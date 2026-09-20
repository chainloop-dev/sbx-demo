# sbx-demo

A tiny operations CLI, `svc`, used to demonstrate AI coding sessions recorded and
governed by Chainloop inside Docker Sandboxes.

## The three stages

`docs/prds/` states intent. `docs/specs/` states the design. `node/` (and `go/`) is
the implementation. One number per feature across all three, e.g. `001-watch-flag`.

- Work on **one stage per session**. A session that edits a PRD while implementing it
  has rewritten the requirement to match the code, and the `session-stays-in-one-stage`
  policy will fail the attestation.
- A PRD holds context, problem, summary and notes. No flags, schemas, endpoints,
  file names or acceptance criteria: those belong in the spec. The
  `prd-no-implementation-detail` policy has an AI reviewer checking this.
- Read the spec before implementing. Never change the PRD or the spec while implementing.

## Working rules

- `go/` and `node/` are the same CLI twice. Work only in the one the task names.
- Build and test before reporting done: `cd node && npm test`, or `cd go && go test ./...`.
  Neither has external dependencies; do not add any.
- `testdata/fixtures/` holds sample integration config. Every credential in it is fake.
- Keep changes scoped to the task. Do not refactor unrelated code.
- Commit with a short imperative subject, then push.

## Before you hand over

This repository is governed by Chainloop. Your session is recorded and evaluated
against the contract in `.chainloop/contracts/`. After you push, check that your own
work passed:

```bash
chainloop workflow run list --project sbx-demo -o json | jq -r '.[0] | "\(.policyStatus) \(.id)"'
```

If the policy status is not `passed`, read the violations and fix them in this same
session before reporting done:

```bash
chainloop workflow run describe --id <id> -o json | jq -r '
  .attestation.policy_evaluations | to_entries[] | .key as $s | .value[]
  | select((.violations // []) | length > 0) | "\($s) \(.name)", (.violations[] | "   \(.)")'
```

A green attestation is part of the job, not a separate step.
