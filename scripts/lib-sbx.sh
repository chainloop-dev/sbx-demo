#!/usr/bin/env bash
# Shared helpers for the demo scripts.
#
# Two host quirks on Linux, both of which fail in confusing ways if you miss them:
#
#   1. sandboxd must run with /usr/sbin on PATH. mkfs.ext4 lives there, and without it
#      the daemon silently disables its "block" volume driver at startup, so every
#      `sbx create` fails with `unknown volume driver: block`.
#      Upstream: https://github.com/docker/sbx-releases/issues/48
#
#   2. sandboxd needs the kvm group. A shell that predates `usermod -aG kvm` does not
#      have it, so we re-exec through `sg` rather than asking for a new login.

sbx_daemon_up() {
  if sbx daemon status >/dev/null 2>&1 && sbx daemon status 2>&1 | grep -q '^Status: running'; then
    return 0
  fi
  echo "starting sandboxd (kvm group, /usr/sbin on PATH)"
  if id -nG | tr ' ' '\n' | grep -qx kvm; then
    PATH="/usr/sbin:/sbin:$PATH" sbx daemon start -d
  else
    /usr/bin/sg kvm -c 'PATH="/usr/sbin:/sbin:$PATH" sbx daemon start -d'
  fi
  sleep 3
  sbx daemon status 2>&1 | grep -q '^Status: running'
}
