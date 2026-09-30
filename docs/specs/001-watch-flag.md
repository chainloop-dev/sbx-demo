# 001 — Watch mode for `svc status`

Implements PRD [001-watch-flag](../prds/001-watch-flag.md).

## CLI surface

Add two flags to `svc status`, usable in both the Node and Go implementations:

```
svc status [--json] [--watch] [--interval <seconds>]
```

- `--watch` — enter watch mode: collect and render status repeatedly instead of
  once, until stopped (see "How it stops" below).
- `--interval <seconds>` — how often to refresh, in whole seconds. Only valid
  together with `--watch`. Passing `--interval` without `--watch` is a usage
  error.
- `--json` — unchanged; composes with `--watch` (see "Terminal behaviour").

Plain `svc status` (no `--watch`) keeps its current one-shot behavior exactly
as-is — this is an additive mode, not a replacement path.

### Argument validation

- `--interval` must parse as a positive integer. A missing value, a
  non-integer, zero, or negative value is a usage error.
- The minimum accepted interval is **1 second**. Anything below that is a
  usage error — this is the direct fix for the PRD's "poll too fast and spam
  their terminal" failure mode.
- `--interval` without `--watch` is a usage error.
- Usage errors print the existing usage line (extended to show the new flags)
  to stderr and exit with status `2`, matching the current behavior for an
  unrecognized command.

## Refresh interval and its default

- Default refresh interval when `--watch` is given without `--interval`:
  **2 seconds**.
- The interval is measured from the start of one refresh to the start of the
  next; it does not stack delay on top of collection time (collection here is
  effectively instant, but the design should not assume that stays true).

## Terminal behaviour

Watch mode has two output modes, chosen the same way for both language
implementations:

1. **Interactive (stdout is a TTY) and no `--json`.** Before each refresh
   after the first, clear the screen and move the cursor to the top
   (`\x1B[2J\x1B[H`), then print a one-line header followed by the normal
   plain-text report:

   ```
   watching every 2s — press Ctrl+C to stop
   checked at 2026-09-20T18:04:11.000Z
   COMPONENT  STATUS LATENCY  DETAIL
   ...
   ```

   The first refresh prints directly, with no leading clear, so the initial
   snapshot appears immediately without a blank flash.

2. **Non-interactive stdout, or `--json` is set.** Never emit clear/cursor
   escape codes, regardless of `--watch`. Each refresh's output is exactly
   what one-shot `svc status` (with or without `--json`) would have printed,
   written in sequence with no separator beyond the trailing newline each
   render already produces. This keeps `svc status --watch | tee log.jsonl`
   and similar redirections meaningful instead of full of control characters,
   and keeps `--json` output easy to parse per-refresh.

Mode selection depends only on "is stdout a TTY" and "is `--json` set" — it
does not depend on `--interval`.

## How it stops

Watch mode stops on `SIGINT` (Ctrl+C) only. There is no in-band keypress
(e.g. `q`) to quit — that would require putting the terminal into raw mode,
which this CLI does not otherwise need and should not take on for this
feature.

On `SIGINT`:

- Stop scheduling further refreshes. Do not start a refresh that is already
  in-flight's *next* cycle; let any in-flight render finish rather than
  cutting output mid-line.
- If the interactive header/clear mode was used, leave the terminal showing
  the last full, completed report (do not clear on the way out).
- Exit as described below. `SIGINT` during watch mode is the expected,
  designed way to end the command — it is not treated as failure.

## Exit codes

- Plain `svc status` (no `--watch`): unchanged — `0` if the last report was
  healthy, `1` if not.
- `svc status --watch`, stopped normally via `SIGINT`: exit `0`, regardless of
  whether the most recently displayed report was healthy. Watch mode's job is
  to show state over time, not to assert health on exit; a person can see an
  unhealthy report on screen and still have stopped it deliberately.
- Usage errors (bad `--interval`, or `--interval` without `--watch`): exit
  `2`, per the existing convention for argument errors.

## Tests

- **Argument parsing**
  - `--watch` alone is accepted and enables watch mode with the default
    2-second interval.
  - `--watch --interval 5` is accepted and uses a 5-second interval.
  - `--interval 5` without `--watch` exits `2` with a usage message.
  - `--interval 0`, a negative value, and a non-numeric value each exit `2`.
  - `--interval` below the 1-second minimum exits `2`.
- **Rendering mode selection**
  - TTY stdout, no `--json`: first refresh has no leading clear sequence;
    every subsequent refresh is preceded by the clear/home escape sequence
    and the "watching every Ns" header.
  - Non-TTY stdout, plain text: sequential refreshes contain zero escape
    sequences and each one matches the plain one-shot render exactly.
  - `--json` with `--watch`, TTY or not: zero escape sequences ever; each
    refresh matches the one-shot `--json` render exactly.
- **Timing**
  - The loop is driven through an injectable clock/scheduler (not real
    `sleep`) so tests can advance time deterministically and assert the
    collector was invoked the expected number of times at the expected
    interval, without a real-time-dependent test taking multiple seconds or
    being flaky.
- **Stop behaviour**
  - Sending `SIGINT` after N refreshes stops further collection (no refresh
    N+1 begins) and the process exits `0`.
  - `SIGINT` exits `0` even when the last collected report was unhealthy.
  - In interactive mode, the final screen state after `SIGINT` still contains
    the last full report (i.e., stopping mid-cycle doesn't clear it away).
- **Regression**
  - Plain `svc status` and `svc status --json` (no `--watch`) are unchanged:
    same output shape and same exit-code-from-health behavior as before this
    feature.
