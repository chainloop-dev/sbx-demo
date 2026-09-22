#!/usr/bin/env bash
# Prepare a fresh sandbox for committing and pushing. Run once, before the first commit.
#
#   scripts/sandbox-setup.sh [--check]
#
# Four things differ inside a sandbox, and every one of them fails in a way that
# does not name its own cause:
#
#   1. A host SSH remote (git@github.com:...) is unusable here. The proxy blocks
#      port 22, so `git push` dies with "Connection closed by <ip> port 22" and
#      nothing mentions the proxy. Rewritten to HTTPS, which the proxy authenticates.
#
#   2. The proxy injects the GitHub token only into the sandbox the secret is
#      scoped to. Scoped elsewhere, the placeholder GH_TOKEN (gho_sbxp...) goes out
#      verbatim and GitHub answers "Invalid username or token" - which reads like a
#      bad token rather than a missing one.
#
#   3. Signing is not configured. The host SSH agent is forwarded, but nothing points
#      git at it, so commits land unsigned and `source-commit` (check_signature: yes)
#      has nothing to check. docker.io/sbx/git-ssh-sign-kit does this at launch; this
#      is the fallback for sandboxes started without that kit.
#
#   4. Without gpg.ssh.allowedSignersFile git cannot verify SSH signatures at all:
#      `git log --show-signature` errors out and %G? prints N on a perfectly good
#      signature. That looks exactly like "you forgot to sign".
#
# Everything written here is repo-local (.git/config). In clone mode none of it
# reaches the host, and the sandbox's ~/.gitconfig is rebuilt for every new sandbox,
# so this has to run again in each one.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

check_only=0
case "${1:-}" in
  --check) check_only=1 ;;
  "") ;;
  *) echo "unknown flag $1" >&2; exit 2 ;;
esac

log()  { printf '  %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; failed=1; }
failed=0

# ---- 1. origin over HTTPS --------------------------------------------------
url=$(git remote get-url origin)
case "$url" in
  git@github.com:*)
    https="https://github.com/${url#git@github.com:}"
    if [ "$check_only" = 1 ]; then
      warn "origin is SSH and will not push from a sandbox: $url"
    else
      git remote set-url origin "$https"
      log "origin rewritten to $https"
    fi
    ;;
  *) log "origin ok: $url" ;;
esac

# ---- 2. GitHub credentials -------------------------------------------------
if login=$(gh api user --jq .login 2>/dev/null); then
  log "github auth ok as $login"
else
  warn "GitHub credentials are not reaching the proxy. On the host:
      sbx secret ls          # check the SCOPE column, not just that a secret exists
      sbx secret set github --sandbox ${SANDBOX_NAME:-<sandbox>} -t \"\$(gh auth token)\""
fi

# ---- 3. commit signing -----------------------------------------------------
key=$(ssh-add -L 2>/dev/null | head -1 || true)
if [ -z "$key" ]; then
  warn "no key in the forwarded SSH agent; commits cannot be signed.
      On the host, 'ssh-add -l' must list a key."
elif [ "$check_only" = 1 ]; then
  log "signing key available: ${key%% *} ${key##* }"
else
  git config gpg.format ssh
  git config user.signingkey "$key"
  git config commit.gpgsign true
  printf '%s %s\n' "$(git config user.email)" "$key" > "$(git rev-parse --git-dir)/allowed_signers"
  git config gpg.ssh.allowedSignersFile "$(git rev-parse --git-dir)/allowed_signers"
  log "signing on, key ${key##* }, verifiable locally"
fi

# ---- 4. report -------------------------------------------------------------
# %G? is only meaningful once allowedSignersFile exists; before that it prints N
# for every commit, signed or not.
log "HEAD $(git log -1 --format='%h') signature state: $(git log -1 --format='%G?')"
[ "$failed" = 0 ] || exit 1
