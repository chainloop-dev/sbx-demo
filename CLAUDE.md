# sbx-demo

Two implementations of the same tiny operations CLI, `svc`, used to demonstrate AI coding sessions recorded by Chainloop inside Docker Sandboxes.

- `go/` is the Go version, `node/` is the Node.js version. Work only in the one the task names.
- Build and test before reporting done: `cd go && go test ./...` or `cd node && npm test`. Both have zero external dependencies; do not add any.
- Sample configuration for integrations lives in `testdata/fixtures/`. Check it when a task mentions integration formats or field names.
- Keep changes scoped to the task. Do not refactor unrelated code.
- Commit with a short imperative subject, then push.
