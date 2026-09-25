#!/usr/bin/env bash
# Run the whole demo loop unattended and assert the outcome.
#
#   scripts/demo-test.sh [--app node|go] [--keep] [--narrate]
#
# --narrate is for presenting: it prints each command before running it, shows
# its output instead of hiding it, and waits for Enter between stages.
#
# The script opens a GitHub issue; the agent closes the governance loop on its own:
# branch, code, test, signed commit, push, pull request, then it watches the PR
# checks and fixes whatever fails.
#
# Known trade-off: the pre-push hook is what records the session, so the PR steps
# only reach Chainloop when a fix makes the agent push again. When every check is
# green on the first push, the recorded session ends at that push and the AI
# Session Score's alignment criterion reads the PR steps as never done.
#
# Exit 0 only if: the commit is signed and its tests pass, the PR links the issue,
# every PR check is green except the human approval, and Chainloop holds a verified
# attestation carrying an AI coding session with real line attribution.
#
# Every jq path below was taken from real `-o json` output on 2026-09-20, not
# from the docs. See docs/EVIDENCE.md for a captured sample.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/lib-sbx.sh

app=node; keep=0; narrate=0
while [ $# -gt 0 ]; do case "$1" in
  --app) app="$2"; shift 2;;
  --keep) keep=1; shift;;
  --narrate) narrate=1; shift;;
  *) echo "unknown flag $1"; exit 2;;
esac; done

KIT=docker.io/chainloop/sbx-kit-claude:latest
SIGN_KIT=docker.io/sbx/git-ssh-sign-kit:latest
name="demo-test"; ts=$(date -u +%Y%m%d%H%M%S); branch="demo-test-$ts"
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)

issue_title="svc status: add --json output"
issue_body="Scripts and dashboards need to read \`svc status\` without parsing the table. Add a --json flag that prints the same report as JSON."
# Built after the issue exists, in step 2: it needs the issue number.
make_prompt(){ cat <<EOF
You're picking up GitHub issue #$1: \`svc status\` only prints a table, so scripts can't read it. Add a --json option that prints the same report as JSON.

1. Work on a new branch called $branch.
2. Make the change in $app/ and add a test for it.
3. Run the tests.
4. Commit, push, and open a pull request that closes #$1.
5. Watch the pull request's checks. If one fails, fix it and push again, until everything is green except the human review, which you leave for a reviewer.
EOF
}

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
# --narrate only. The agent runs headless (-p) and prints nothing until it is done,
# so stream its session transcript from inside the sandbox: each tool call and
# message as it happens. Transcripts from earlier runs persist in the sandbox's
# ~/.claude volume, so only a file written after $1 (epoch seconds) counts.
stream_agent(){
  until sbx exec "$name" -- true >/dev/null 2>&1; do sleep 3; done
  sbx exec "$name" -- sh -c 'while :; do
      f=$(find ~/.claude/projects -name "*.jsonl" -newermt "@'"$1"'" 2>/dev/null | head -1)
      [ -n "$f" ] && exec tail -n +1 -f "$f"
      sleep 2
    done' 2>/dev/null \
  | jq -r --unbuffered 'select(.type == "assistant") | .message.content[]?
      | if .type == "tool_use" then "  \u001b[36m▶ \(.name)\u001b[0m \(.input.command // .input.file_path // .input.pattern // "" | tostring | gsub("\n"; " ") | .[0:150])"
        elif .type == "text" then "  \u001b[33m💬\u001b[0m \(.text | gsub("\n"; " ") | .[0:300])"
        else empty end'
}
streamer=""
stop_stream(){
  [ -n "$streamer" ] || return 0
  pkill -P "$streamer" 2>/dev/null || true; kill "$streamer" 2>/dev/null || true
  wait "$streamer" 2>/dev/null || true; streamer=""
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
command -v gh >/dev/null || die "gh not installed"
# A stale GITHUB_TOKEN in the shell wins over the gh keyring login; ignore it.
unset GITHUB_TOKEN
gh_token=$(gh auth token 2>/dev/null) || die "gh is not logged in: run 'gh auth login'"
[ -z "$(git status --porcelain)" ] || die "working tree not clean (run scripts/demo-reset.sh)"
project=$(awk -F: '/^projectName:/ {gsub(/[ "]/,"",$2); print $2}' .chainloop.yml)
[ -n "$project" ] || die "projectName missing from .chainloop.yml"
org=$(awk -F: '/^organization:/ {gsub(/[ "]/,"",$2); print $2}' .chainloop.yml)
log "preflight ok: project=$project app=$app branch=$branch"
# The sandbox shares this checkout, and the agent leaves it on its own branch.
start_branch=$(git branch --show-current)
cleanup(){ stop_stream; git worktree remove -f "${wt:-}" 2>/dev/null || true; git checkout -q "$start_branch" 2>/dev/null || true; }
trap cleanup EXIT

# ---- 2. agent run ----------------------------------------------------------
# No --clone on purpose: in clone mode origin is a read-only virtiofs mount and
# the agent's push is rejected with "unable to create temporary object directory".
stage "Open the issue the agent will implement"
show "gh issue create --label demo-test --title \"$issue_title\""
gh label create demo-test --color BFD4F2 --description "Opened by scripts/demo-test.sh" --force >/dev/null
issue_url=$(gh issue create --label demo-test --title "$issue_title" --body "$issue_body") \
  || die "could not open the GitHub issue"
issue=${issue_url##*/}
log "issue #$issue: $issue_url"
prompt=$(make_prompt "$issue")

stage "Run the agent in a Docker Sandbox"
sbx rm -f "$name" >/dev/null 2>&1 || true
# Removing a sandbox drops its secrets, so give the new one GitHub access every run.
sbx secret set github --sandbox "$name" -f -t "$gh_token" >/dev/null || die "could not give the sandbox a GitHub credential"
[ "$narrate" = 1 ] && printf '\n%s\n' "$prompt"
show "sbx run --name $name --kit $SIGN_KIT $KIT . -- -p \"<prompt>\""
log "launching sandbox (first ever run needs a terminal: approve the credential prompt once)"
deadline=$((SECONDS + 1200))
if [ "$narrate" = 1 ]; then stream_agent "$(( $(date +%s) - 5 ))" & streamer=$!; fi
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
stop_stream

# ---- 3. assert the agent's work -------------------------------------------
stage "Check the agent's commit"
show "git fetch origin $branch"
git fetch -q origin "$branch" 2>/dev/null || die "branch $branch was never pushed to origin"
sha=$(git rev-parse "origin/$branch")
# %G?/%GS instead of --show-signature: that one prints the key fingerprint, which
# ai-config-no-secrets flags as an API key whenever it lands in a recorded session.
show "git log -1 --stat origin/$branch"
quiet git log -1 --stat --format='commit %H%nsignature: %G? (signed by %GS)%nauthor: %an <%ae>%n%n%B' "$sha"
sig=$(git log -1 "$sha" --format='%G?')
[ "$sig" = G ] || [ "$sig" = U ] || die "commit $sha is not signed (git says '%G?'=$sig)"
log "commit $sha signed ($sig)"

wt=$(mktemp -d)
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

# ---- 4. check the agent's pull request --------------------------------------
stage "Check the pull request the agent opened"
show "gh pr view $branch"
pr_json=$(gh pr view "$branch" --json number,url,title,body 2>/dev/null) \
  || die "the agent did not open a pull request for $branch"
pr_url=$(jq -r .url <<<"$pr_json")
[ "$narrate" = 1 ] && jq -r '"#\(.number) \(.title)\n\(.url)\n\n\(.body)"' <<<"$pr_json"
jq -e --arg ref "#$issue" '(.title + " " + .body) | contains($ref)' <<<"$pr_json" >/dev/null \
  || die "PR $pr_url does not reference issue #$issue"
log "PR $pr_url references #$issue"

show "gh pr checks $branch"
checks=""
# Until PR Validation has run, GitHub shows it NEUTRAL with a placeholder link, so
# "done" means every check has settled and PR Validation links to its workflow run.
settled='length > 0 and all(.state != "PENDING" and .state != "QUEUED" and .state != "IN_PROGRESS")
  and all(select(.name == "Chainloop PR Validation") | .link | test("/workflow-runs/"))'
for _ in $(seq 1 30); do
  checks=$(gh pr checks "$branch" --json name,state,link 2>/dev/null || true)
  [ -n "$checks" ] && jq -e "$settled" <<<"$checks" >/dev/null && break
  sleep 10
done
[ -n "$checks" ] && jq -e "$settled" <<<"$checks" >/dev/null || die "PR checks did not finish within 5 minutes on $pr_url"
[ "$narrate" = 1 ] && jq -r '.[] | "\(if .state == "SUCCESS" then "✓" else "✗" end)  \(.name)"' <<<"$checks"
# The only failure allowed is the approval rule inside PR Validation: a human's job.
jq -r '.[] | select(.state != "SUCCESS") | "\(.name)\t\(.link)"' <<<"$checks" | while IFS=$'\t' read -r check link; do
  [ "$check" = "Chainloop PR Validation" ] || die "PR check '$check' did not pass: $link"
  other=$(chainloop workflow run describe --id "${link##*/}" -o json | jq -r '[.attestation.policy_evaluations[][]
    | select((.violations // []) | length > 0) | .name] | unique | map(select(. != "pr-min-approvals")) | join(", ")')
  [ -z "$other" ] || die "PR Validation failed on more than the approval: $other ($link)"
done
log "PR checks green; only the human approval is pending"

# ---- 5. assert the evidence -----------------------------------------------
stage "Find the attestation in Chainloop"
show "chainloop workflow run list --project $project -o json"
log "waiting for the attestation in project $project"
run_id=""
for _ in $(seq 1 30); do
  run_id=$(chainloop workflow run list --project "$project" -o json 2>/dev/null \
    | jq -r --arg s "$start" '[.[] | select(.createdAt >= $s and .workflow.name == "ai-coding-session")] | sort_by(.createdAt) | last | .id // empty')
  [ -n "$run_id" ] && break
  sleep 10
done
[ -n "$run_id" ] || die "no workflow run newer than $start in project $project"
log "run $run_id"

show "chainloop workflow run describe --id $run_id -o json"
desc=$(chainloop workflow run describe --id "$run_id" -o json)
# An auto-created workflow gets an empty contract, so nothing is evaluated.
jq -e '.attestation.policy_evaluations // {} | length > 0' <<<"$desc" >/dev/null \
  || die "no policies were evaluated on run $run_id: point workflow ai-coding-session in project $project at contract sbx-demo-ai-coding-session (chainloop workflow update --contract)"
[ "$narrate" = 1 ] && jq -r '"signature verified: \(.verified)",
  "attestation:        \(.attestation.digest)",
  (.attestation.policy_evaluation_status | "policies:           \(.passed)/\(.total) passed, \(.violated) violated"),
  "evidence:", (.attestation.materials[] | "  \(.type)  \(.name)"), ""' <<<"$desc"
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
[ "$secret_violations" = 0 ] || die "ai-config-no-secrets fired on the session"

att_digest=$(jq -r '.attestation.digest' <<<"$desc")

# Provenance, walked backwards: from the commit on the PR to the evidence about it.
stage "Trace the commit back to its evidence"
show "chainloop discover --digest sha1:$sha"
from_commit=$(chainloop discover --digest "sha1:$sha" 2>/dev/null) || die "chainloop discover failed for commit $sha"
[ "$narrate" = 1 ] && jq -r '.result.references[] | "  ← \(.kind)  \(.metadata.name // "")  (project \(.metadata.project // "?"))  \(.digest)"' <<<"$from_commit"
jq -e --arg d "$att_digest" '[.result.references[].digest] | index($d) != null' <<<"$from_commit" >/dev/null \
  || die "commit $sha does not lead back to attestation $att_digest"
show "chainloop discover --digest $att_digest"
from_att=$(chainloop discover --digest "$att_digest" 2>/dev/null) || die "chainloop discover failed for $att_digest"
[ "$narrate" = 1 ] && jq -r '.result | "checked against contract \(.metadata.contractName) (revision \(.metadata.contractVersion))",
  (.references[] | "  → \(.kind)  \(.digest)")' <<<"$from_att"
log "commit ${sha:0:7} leads back to its attestation"

# ---- 6. attribution, from the session material itself ---------------------
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

# ---- 7. teardown and summary ----------------------------------------------
[ "$keep" = 1 ] || sbx rm -f "$name" >/dev/null 2>&1 || true
cat <<EOF

SUMMARY
  issue         $issue_url
  pull request  $pr_url (awaiting human approval)
  branch        $branch
  commit        $sha (signature $sig)
  run           $run_id
  policy        $status ($violated violated)
  attestation   $att_digest
  session       $session_digest
  model         $model
  attribution   $ai_added AI lines across $files files
  est. cost     \$$cost
  view          https://app.chainloop.dev/u/${org:-$project}/workflow-runs/$att_digest
EOF
