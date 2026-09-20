#!/usr/bin/env bash
# Run the whole demo loop unattended and assert the outcome.
#
#   scripts/demo-test.sh [--app node|go] [--keep] [--expect-secret]
#
# Exit 0 only if: the agent branched, built and tested its change, signed and
# pushed the commit, and Chainloop holds a verified attestation carrying an
# AI coding session with real line attribution.
#
# Every jq path below was taken from real `-o json` output on 2026-09-20, not
# from the docs. See docs/EVIDENCE.md for a captured sample.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/lib-sbx.sh

app=node; keep=0; expect_secret=0
while [ $# -gt 0 ]; do case "$1" in
  --app) app="$2"; shift 2;;
  --keep) keep=1; shift;;
  --expect-secret) expect_secret=1; shift;;
  *) echo "unknown flag $1"; exit 2;;
esac; done

KIT=docker.io/chainloop/sbx-kit-claude:latest
SIGN_KIT=docker.io/sbx/git-ssh-sign-kit:latest
name="demo-test"; ts=$(date -u +%Y%m%d%H%M%S); branch="demo-test-$ts"
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)

prompt="In $app/, add a --json flag to svc status that prints the report as JSON. Cover it with a test. Work on a new branch called $branch, commit, and push to origin."
[ "$expect_secret" = 1 ] && prompt="In $app/, add a --json flag to svc status. Check testdata/fixtures for the field names integrations expect. Cover it with a test. Work on a new branch called $branch, commit, and push to origin."

log(){ printf '[%s] %s\n' "$(date -u +%T)" "$*"; }
die(){ printf '[%s] FAIL: %s\n' "$(date -u +%T)" "$*" >&2; exit 1; }

# ---- 1. preflight ----------------------------------------------------------
command -v sbx >/dev/null || die "sbx not installed"
command -v jq  >/dev/null || die "jq not installed"
sbx_daemon_up || die "could not start sandboxd"
chainloop version >/dev/null 2>&1 || die "chainloop CLI missing"
[ -f .env ] && grep -q '^chainloopToken=' .env || die ".env with chainloopToken= missing (see .env.example)"
[ -f .chainloop.yml ] || die "repo not initialized: run 'chainloop trace init'"
grep -q 'chainloop trace hook' .claude/settings.json 2>/dev/null || die "Claude hooks missing: run 'chainloop trace init'"
ssh-add -l >/dev/null 2>&1 || die "no key in the SSH agent; the sandbox cannot sign commits"
[ -z "$(git status --porcelain)" ] || die "working tree not clean (run scripts/demo-reset.sh)"
project=$(awk -F: '/^projectName:/ {gsub(/[ "]/,"",$2); print $2}' .chainloop.yml)
[ -n "$project" ] || die "projectName missing from .chainloop.yml"
log "preflight ok: project=$project app=$app branch=$branch"

# ---- 2. agent run ----------------------------------------------------------
# No --clone on purpose: in clone mode origin is a read-only virtiofs mount and
# the agent's push is rejected with "unable to create temporary object directory".
sbx rm -f "$name" >/dev/null 2>&1 || true
log "launching sandbox (first ever run needs a terminal: approve the credential prompt once)"
timeout 1200 sbx run --name "$name" --kit-args-file .env --kit "$SIGN_KIT" "$KIT" . -- -p "$prompt" \
  || die "agent run failed or timed out"

# ---- 3. assert the agent's work -------------------------------------------
git fetch -q origin "$branch" 2>/dev/null || die "branch $branch was never pushed to origin"
sha=$(git rev-parse "origin/$branch")
sig=$(git log -1 "$sha" --format='%G?')
[ "$sig" = G ] || [ "$sig" = U ] || die "commit $sha is not signed (git says '%G?'=$sig)"
log "commit $sha signed ($sig)"

wt=$(mktemp -d); trap 'git worktree remove -f "$wt" 2>/dev/null || true' EXIT
git worktree add -q "$wt" "origin/$branch"
case "$app" in
  node) (cd "$wt/node" && npm test >/dev/null 2>&1 && node bin/svc.js status --json | jq -e '.components|length>0' >/dev/null) || die "node tests or --json output failed";;
  go)   (cd "$wt/go"   && go test ./... >/dev/null 2>&1 && go run ./cmd/svc status --json | jq -e '.components|length>0' >/dev/null) || die "go tests or --json output failed";;
esac
log "code ok: tests pass and --json is valid"

# ---- 4. assert the evidence -----------------------------------------------
log "waiting for the attestation in project $project"
run_id=""
for _ in $(seq 1 30); do
  run_id=$(chainloop workflow run list --project "$project" -o json 2>/dev/null \
    | jq -r --arg s "$start" '[.[] | select(.createdAt >= $s)] | sort_by(.createdAt) | last | .id // empty')
  [ -n "$run_id" ] && break
  sleep 10
done
[ -n "$run_id" ] || die "no workflow run newer than $start in project $project"
log "run $run_id"

desc=$(chainloop workflow run describe --id "$run_id" -o json)
[ "$(jq -r '.verified' <<<"$desc")" = true ] || die "attestation signature did not verify"

session_digest=$(jq -r '.attestation.materials[] | select(.type=="CHAINLOOP_AI_CODING_SESSION") | .hash' <<<"$desc")
[ -n "$session_digest" ] || die "no CHAINLOOP_AI_CODING_SESSION material in the attestation"

status=$(jq -r '.attestation.policy_evaluation_status.status' <<<"$desc")
violated=$(jq -r '.attestation.policy_evaluation_status.violated' <<<"$desc")
# One evaluation per policy per subject; subjects are CHAINLOOP.ATTESTATION and each material.
secret_violations=$(jq -r '[.attestation.policy_evaluations | to_entries[] | .value[]
  | select(.name=="ai-config-no-secrets") | (.violations // []) | length] | add // 0' <<<"$desc")
commit_violations=$(jq -r '[.attestation.policy_evaluations | to_entries[] | .value[]
  | select(.name=="source-commit") | (.violations // []) | length] | add // 0' <<<"$desc")

[ "$commit_violations" = 0 ] || die "source-commit reported a violation; the commit signature did not reach the attestation"
if [ "$expect_secret" = 1 ]; then
  [ "$secret_violations" -gt 0 ] || die "expected ai-config-no-secrets to fire on the seeded fixture, but it passed"
  log "seeded catch fired: ai-config-no-secrets reported $secret_violations violation(s)"
else
  [ "$secret_violations" = 0 ] || die "ai-config-no-secrets fired unexpectedly on a clean run"
fi

att_digest=$(jq -r '.attestation.digest' <<<"$desc")
chainloop discover --digest "$att_digest" >/dev/null 2>&1 || die "chainloop discover failed for $att_digest"

# ---- 5. attribution, from the session material itself ---------------------
tmp=$(mktemp -d)
(cd "$tmp" && chainloop artifact download --digest "$session_digest" >/dev/null 2>&1) || die "could not download the session material"
sess=$(find "$tmp" -name 'chainloop-trace-*.json' | head -1)
[ -n "$sess" ] || die "session material did not download"
ai_added=$(jq -r '.data.code_changes.ai_lines_added // 0' "$sess")
cost=$(jq -r '.data.token_usage.estimated_cost_usd // 0' "$sess")
model=$(jq -r '.data.model.primary // "?"' "$sess")
files=$(jq -r '.data.code_changes.files | length' "$sess")
[ "$ai_added" -gt 0 ] || die "attribution recorded 0 AI lines; the agent's commit was not linked to the session"
rm -rf "$tmp"

# ---- 6. teardown and summary ----------------------------------------------
[ "$keep" = 1 ] || sbx rm -f "$name" >/dev/null 2>&1 || true
cat <<EOF

SUMMARY
  branch        $branch
  commit        $sha (signature $sig)
  run           $run_id
  policy        $status ($violated violated)
  attestation   $att_digest
  session       $session_digest
  model         $model
  attribution   $ai_added AI lines across $files files
  est. cost     \$$cost
  view          https://app.chainloop.dev/u/$project/workflow-runs/$att_digest
EOF
