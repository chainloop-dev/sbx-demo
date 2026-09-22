#!/usr/bin/env bash
# Return the demo repo and this host to the pre-demo state.
#   scripts/demo-reset.sh          remove demo-* sandboxes and branches, clean the tree
#   scripts/demo-reset.sh --hard   also drop the sandbox's persistent ~/.claude volumes (first-run experience)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/lib-sbx.sh
hard=0; [ "${1:-}" = "--hard" ] && hard=1

# 1. sandboxes
if command -v sbx >/dev/null; then
  for s in $(sbx ls 2>/dev/null | awk 'NR>1 && $1 ~ /^demo-/ {print $1}'); do
    echo "removing sandbox $s"; sbx rm -f "$s"
  done
  if [ "$hard" = 1 ]; then
    # Persistent volumes are named after the agent; removing them resets trust flags and history.
    sbx volume ls 2>/dev/null | awk 'NR>1 && $1 ~ /claude/ {print $1}' | while read -r v; do
      echo "removing volume $v"; sbx volume rm -f "$v" || true
    done
  fi
fi

# 2. branches, local and on the bare remote
git checkout -q main
for b in $(git branch --list 'demo-*' --format='%(refname:short)'); do git branch -D "$b"; done
if git remote get-url origin >/dev/null 2>&1; then
  for b in $(git ls-remote --heads origin 'demo-*' | awk '{print $2}' | sed 's#refs/heads/##'); do
    git push -q origin --delete "$b"
  done
fi

# 3. working tree, keeping the token
git clean -fdxq -e .env
git checkout -q -- .

# 4. report
left=$(git status --porcelain | wc -l)
sb=$(command -v sbx >/dev/null && sbx ls 2>/dev/null | awk 'NR>1 && $1 ~ /^demo-/' | wc -l || echo 0)
tok=$( [ -f .env ] && grep -q '^chainloopToken=' .env && echo present || echo MISSING )
echo "ready: main @ $(git rev-parse --short HEAD), $sb demo sandboxes, token $tok"
[ "$left" -eq 0 ] && [ "$sb" -eq 0 ] && [ "$tok" = present ]
