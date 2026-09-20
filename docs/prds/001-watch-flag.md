# 001 — Watch mode for `svc status`

## Context

`svc status` reports the current state of the services this CLI manages. Today it
prints a single snapshot and exits. When someone is actively working on a service —
restarting it, waiting for it to come up, chasing down a flaky dependency — they
end up running `svc status` over and over by hand, or wrapping it in a shell loop,
just to see how the state is changing.

## Problem

Re-running a one-shot status check manually is tedious and error-prone: people
either poll too slowly and miss a transition, poll too fast and spam their
terminal, or forget to keep checking and miss the moment a service actually
changes state. There's no built-in way to just watch and be told when something
changes.

## Summary

Give `svc status` a way to keep running and continuously reflect the current
state of the services, instead of exiting after a single report. The person
running it should be able to leave it open in a terminal, glance at it, and
trust that what they see is current — without re-invoking the command themselves.

This is for engineers and operators actively working on a service: during a
deploy, a restart, an incident, or general local development, when they want a
live view of status rather than a point-in-time check.

## Notes

- Success looks like: someone can start watching and immediately see the current
  state, then see it update on its own as services change, without needing to
  re-run the command.
- Should feel natural to leave running in a terminal pane for the duration of a
  task, and easy to stop when no longer needed.
- Should not make the plain, one-shot `svc status` behavior harder to get to —
  this is an additional mode, not a replacement.
- Out of scope for this PRD: how updates are detected, how output is formatted or
  refreshed, timing/interval behavior, and any flags or options. Those belong in
  the spec.
