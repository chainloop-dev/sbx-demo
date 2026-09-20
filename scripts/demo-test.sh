#!/usr/bin/env bash
# Run the whole demo loop unattended and assert the outcome.
#   scripts/demo-test.sh [--app node|go] [--keep]
# Exit 0 only if: the agent's branch builds and tests, svc status --json is valid JSON,
# the session is attested in Chainloop, and ai-config-no-secrets failed on the seeded fixture.
#
# TODO(first run): pin the sbx arg pass-through (`-- -p`) and the exact JSON fields from
# `chainloop workflow run describe`. Marked VERIFY below.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/lib-sbx.sh
app=node; keep=0
while [ $# -gt 0 ]; do case "$1" in --app) app="$2"; shift 2;; --keep) keep=1; shift;; *) echo "unknown flag $1"; exit 2;; esac; done

name="demo-test"; ts=$(date -u +%Y%m%d%H%M%S); branch="demo-test-$ts"; start=$(date -u +%FT%TZ)
prompt="In $app/, add a --json flag to svc status. Check testdata/fixtures for the field names integrations expect. Cover it with a test, commit, and push."
log(){ printf '[%s] %s\n' "$(date -u +%T)" "$*"; }
die(){ log "FAIL: $*"; exit 1; }

# 1. preflight
command -v sbx >/dev/null || die "sbx not installed"
sbx_daemon_up || die "could not start sandboxd"
chainloop version >/dev/null || die "chainloop CLI missing"
[ -f .env ] && grep -q '^chainloopToken=' .env || die ".env with chainloopToken= missing"
[ -f .chainloop.yml ] && grep -q 'chainloop trace hook' .claude/settings.json 2>/dev/null || die "repo not initialized: run chainloop trace init"
[ -z "$(git status --porcelain)" ] || die "working tree not clean (run scripts/demo-reset.sh)"
project=$(awk -F: '/^projectName:/ {gsub(/[ "]/,"",$2); print $2}' .chainloop.yml); [ -n "$project" ] || die "projectName not in .chainloop.yml"
log "preflight ok: project=$project app=$app"

# 2. fresh branch
git checkout -q -b "$branch" && git push -q -u origin "$branch"
log "branch $branch"

# 3. headless session (VERIFY: `--` pass-through to the kit's entrypoint; fallback is sbx exec ... claude -p)
sbx rm -f "$name" >/dev/null 2>&1 || true
log "launching sandbox $name"
timeout 900 sbx run --clone --name "$name" --kit-args-file .env chainloop/sbx-kit-claude -- -p "$prompt" \
  || die "agent run failed or timed out"

# 4. push guard: make sure the branch on origin has the agent's commit
git fetch -q origin "$branch"
if [ "$(git rev-parse "origin/$branch")" = "$(git rev-parse "$branch")" ]; then
  log "agent did not push; pushing from inside the sandbox so the hook runs"
  sbx exec "$name" -- git push -u origin HEAD || die "push from sandbox failed"
  git fetch -q origin "$branch"
fi
sha=$(git rev-parse "origin/$branch"); log "agent commit $sha"

# 5. assert the code
wt=$(mktemp -d); git worktree add -q "$wt" "origin/$branch"
case "$app" in
  node) (cd "$wt/node" && npm test >/dev/null && node bin/svc.js status --json | jq -e '.components | length > 0' >/dev/null) || die "node tests or --json output failed";;
  go)   (cd "$wt/go" && go test ./... >/dev/null && go run ./cmd/svc status --json | jq -e '.components | length > 0' >/dev/null) || die "go tests or --json output failed";;
esac
log "code ok: tests pass, --json is valid"

# 6. assert the evidence (VERIFY field names against real output on first run)
log "waiting for the attestation in Chainloop (project $project)"
run_json=""
for i in $(seq 1 30); do
  run_json=$(chainloop workflow run list --project "$project" -o json 2>/dev/null | jq -c --arg s "$start" '[.[] | select(.createdAt >= $s)] | first // empty') || true
  [ -n "$run_json" ] && break; sleep 10
done
[ -n "$run_json" ] || die "no workflow run newer than $start in project $project"
run_id=$(echo "$run_json" | jq -r '.id'); log "run $run_id"
desc=$(chainloop workflow run describe --id "$run_id" -o json)
echo "$desc" | jq -e '.. | objects | select(.type? == "ai-coding-session" or .kind? == "AI_CODING_SESSION" or .name? == "aicodingsession")' >/dev/null || die "no AI coding session material in run"   # VERIFY
echo "$desc" | jq -e '[.. | objects | select(.name? == "ai-config-no-secrets")] | any(.status? == "failed" or .result? == "FAILED")' >/dev/null || die "ai-config-no-secrets did not fail on the seeded fixture"  # VERIFY
digest=$(echo "$desc" | jq -r '.. | .digest? // empty' | grep -m1 sha256 || true)
[ -n "$digest" ] && { chainloop discover --digest "$digest" >/dev/null || die "discover failed for $digest"; log "discover ok: $digest"; }
log "evidence ok"

# 7. teardown and summary
git worktree remove -f "$wt"; git checkout -q main
[ "$keep" = 1 ] || sbx rm -f "$name" >/dev/null 2>&1 || true
echo; echo "SUMMARY"; echo "  branch   $branch"; echo "  commit   $sha"; echo "  run      $run_id"; echo "  digest   ${digest:-n/a}"
echo "  url      https://app.chainloop.dev (project $project)"
