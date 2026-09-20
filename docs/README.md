# docs

Three stages, three sessions, one number per feature.

| Directory | Holds | Written by |
|---|---|---|
| `prds/` | Intent. Why we want it, who for, what success looks like. No design. | session 1 |
| `specs/` | Design. CLI surface, behaviour, exit codes, what to test. No code. | session 2 |
| `../node/` | The implementation. | session 3 |

`docs/prds/001-watch-flag.md` and `docs/specs/001-watch-flag.md` are the same feature.
The number is how a reader ties them together, and how `session-stays-in-one-stage`
knows the three are distinct steps.

Each stage is its own AI coding session, its own pull request, and its own signed
attestation in Chainloop. Stage N reads what stage N-1 merged.
