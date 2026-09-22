#!/usr/bin/env bash
# Run the whole demo loop unattended and assert the outcome.
#
#   scripts/demo-test.sh [--app node|go] [--keep] [--expect-secret] [--narrate]
#
# --narrate is for presenting: it prints each command before running it, shows
# its output instead of hiding it, and waits for Enter between stages.
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

app=node; keep=0; expect_secret=0; narrate=0
while [ $# -gt 0 ]; do case "$1" in
  --app) app="$2"; shift 2;;
  --keep) keep=1; shift;;
  --expect-secret) expect_secret=1; shift;;
  --narrate) narrate=1; shift;;
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
# Narration helpers; all three are no-ops without --narrate.
show(){ [ "$narrate" = 1 ] || return 0; printf '\n\033[1;36m$ %s\033[0m\n' "$*"; }
quiet(){ if [ "$narrate" = 1 ]; then "$@"; else "$@" >/dev/null 2>&1; fi; }
stage(){
  [ "$narrate" = 1 ] || return 0
  [ -t 0 ] && read -rp $'\n\033[2m↵ '"$1"$'\033[0m ' _
  printf '\n\033[1m== %s\033[0m\n' "$1"
}
# macOS has no timeout(1). perl's alarm survives exec and keeps the command in the
# foreground, so sbx still gets the terminal for its credential prompt.
with_timeout(){
  if command -v timeout >/dev/null; then timeout "$@"
  else perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$@"; fi
}

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
stage "Run the agent in a Docker Sandbox"
sbx rm -f "$name" >/dev/null 2>&1 || true
[ "$narrate" = 1 ] && printf '\nprompt: %s\n' "$prompt"
show "sbx run --name $name --kit $SIGN_KIT $KIT . -- -p \"<prompt>\""
log "launching sandbox (first ever run needs a terminal: approve the credential prompt once)"
deadline=$((SECONDS + 1200))
if ! with_timeout 1200 sbx run --name "$name" --kit-args-file .env --kit "$SIGN_KIT" "$KIT" . -- -p "$prompt"; then
  # sbx run can lose its exec attach ("inspect exec: context deadline exceeded")
  # while the agent keeps working in the sandbox. Wait for it; step 3 checks the push.
  log "sbx run exited early; waiting for the agent inside the sandbox"
  while sbx exec "$name" -- pgrep -f 'claude --dangerously' >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "agent timed out after 1200s"
    sleep 10
  done
  log "agent finished"
fi

# ---- 3. assert the agent's work -------------------------------------------
stage "Check the agent's commit"
show "git fetch origin $branch"
git fetch -q origin "$branch" 2>/dev/null || die "branch $branch was never pushed to origin"
sha=$(git rev-parse "origin/$branch")
show "git log -1 --show-signature --stat origin/$branch"
quiet git log -1 --show-signature --stat "$sha"
sig=$(git log -1 "$sha" --format='%G?')
[ "$sig" = G ] || [ "$sig" = U ] || die "commit $sha is not signed (git says '%G?'=$sig)"
log "commit $sha signed ($sig)"

wt=$(mktemp -d); trap 'git worktree remove -f "$wt" 2>/dev/null || true' EXIT
git worktree add -q "$wt" "origin/$branch"
case "$app" in
  node) test_cmd="npm test";     json_cmd="node bin/svc.js status --json";;
  go)   test_cmd="go test ./..."; json_cmd="go run ./cmd/svc status --json";;
esac
show "cd $app && $test_cmd"
(cd "$wt/$app" && quiet $test_cmd) || die "$app tests failed"
show "$json_cmd | jq"
json=$(cd "$wt/$app" && $json_cmd) || die "$json_cmd failed"
[ "$narrate" = 1 ] && jq . <<<"$json"
jq -e '.components|length>0' <<<"$json" >/dev/null || die "--json output has no components"
log "code ok: tests pass and --json is valid"

# ---- 4. assert the evidence -----------------------------------------------
stage "Find the attestation in Chainloop"
show "chainloop workflow run list --project $project -o json"
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

show "chainloop workflow run describe --id $run_id -o json"
desc=$(chainloop workflow run describe --id "$run_id" -o json)
[ "$narrate" = 1 ] && jq -r '.attestation.policy_evaluations | to_entries[] | .value[]
  | "\(if (.violations // []) | length > 0 then "✗" else "✓" end)  \(.name)"' <<<"$desc" | sort -u
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
stage "Read the AI coding session evidence"
show "chainloop artifact download --digest $session_digest"
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
